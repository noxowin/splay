#include "../../src/core/session.hpp"
#include <cassert>
#include <iostream>
#include <limits>
using namespace splay;

struct Fixture {
    Session s;
    Playback media;
    std::vector<Json> sent,events;
    std::vector<Correction> applied;
    std::string room="room";
    Fixture(bool managed=false,bool readiness=true){
        s.command({{"action","room-policy"},{"pause_on_join",false},{"pause_on_leave",false}});
        if(managed)room="+ctl:ABCDEFGHIJKL";
        s.send=[&](const Json& j){sent.push_back(j);};
        s.event=[&](const Json& j){events.push_back(j);};
        s.apply=[&](const Correction& c){applied.push_back(c);};
        media.loaded=true;media.paused=true;media.position=73;media.duration=600;s.playback(media);
        s.configure("localhost",8999,"me",room,"");s.connected(false,100);
        receive({{"Hello",{{"username","me"},{"room",{{"name",room}}},{"realversion","1.7.6"},{"features",{{"readiness",readiness}}}}}},100);
        sent.clear();events.clear();
    }
    void receive(const Json& j,double now=100){s.receive(j.dump(),now);assert(s.logged());}
    Json member(Json ready=true,bool controller=false){return {{"file",{{"name","film.mkv"},{"duration",600},{"size",123}}},{"isReady",ready},{"controller",controller}};}
    void list(Json own=true,Json peer=true,int count=2,bool controller=false,double now=100){
        Json members=Json::object();members["me"]=member(own,controller);
        if(count>=2)members["peer"]=member(peer);
        receive({{"List",{{room,members}}}},now);
    }
    void ready(const std::string& user,Json value,double now=100){receive({{"Set",{{"ready",{{"username",user},{"isReady",value}}}}}},now);}
    void enable(int delay=5){s.command({{"action","autostart"},{"enabled",true},{"delay",delay}});}
    Json status(){return s.status()["autostart"];}
    void auth(bool success,double now=100){receive({{"Set",{{"controllerAuth",{{"user","me"},{"room",room},{"success",success}}}}}},now);}
    size_t changes(){size_t n=0;for(const auto& j:sent)if(j.contains("State")&&j["State"].contains("ignoringOnTheFly")&&j["State"]["ignoringOnTheFly"].contains("client"))++n;return n;}
    void wait(double until){s.tick(until);}
    void reset_phase(double now=106){ready("peer",false,now);ready("peer",true,now);}
};

int main(){
    { // Default off, exact deadline, no media/ready mutation, and one-shot.
        Fixture f;f.list();assert(f.status()["enabled"]==false&&f.status()["delay"]==5);
        f.wait(105);assert(f.applied.empty()&&f.changes()==0);
        f.enable();assert(f.status()["pending"]==true&&f.status()["remaining"]==5&&f.status()["participants"]==2);
        f.wait(109.01);assert(f.status()["remaining"]==1&&f.applied.empty());
        f.wait(110);assert(f.status()["reason"]=="started"&&f.applied.size()==1&&f.changes()==1);
        assert(!f.applied[0].position&&f.applied[0].paused==false);
        auto state=f.sent.back()["State"];assert(state["playstate"]["position"]==73&&state["playstate"]["paused"]==false&&!state["playstate"].contains("doSeek"));
        assert(f.s.status()["ready"]==true);
        for(const auto& j:f.sent)assert(!j.contains("Set"));
        f.wait(111);f.wait(112);assert(f.applied.size()==1&&f.changes()==1);
        // The server's ordinary playback echo is not a cancellation or a new
        // play request. Preserve the successful result throughout this phase.
        f.receive({{"State",{{"ignoringOnTheFly",{{"client",1}}},{"playstate",{{"position",75},{"paused",false},{"setBy","me"}}}}}},112);
        assert(f.status()["reason"]=="started"&&!f.status()["pending"].get<bool>()&&f.changes()==1);
        auto after_echo=f.applied.size();
        f.wait(112.1);assert(f.applied.size()==after_echo&&f.changes()==1);
        size_t started=0,cancelled=0;
        for(const auto& e:f.events)if(e["type"]=="autostart"){
            if(e["action"]=="started")++started;
            if(e["action"]=="cancelled")++cancelled;
        }
        assert(started==1&&cancelled==0);
        f.media.paused=true;f.s.playback(f.media);f.s.local_change(false,112);f.sent.clear();f.wait(112.4);
        assert(!f.status()["pending"].get<bool>()&&f.status()["reason"]=="waiting-reset"&&f.applied.size()==after_echo);
    }
    { // Set events never establish the complete membership baseline.
        Fixture f;f.enable();
        f.receive({{"Set",{{"user",{{"me",f.member()},{"peer",f.member()}}}}}});
        assert(f.status()["reason"]=="waiting-snapshot"&&!f.status()["pending"].get<bool>());
        f.list();assert(f.status()["pending"]==true);
    }
    { // An incomplete/malformed List cannot silently omit room members.
        Fixture f;f.enable();f.receive({{"List",{{f.room,{{"peer",f.member()}}}}}});
        assert(f.status()["reason"]=="waiting-snapshot");
        f.receive({{"List",{{f.room,{{"me",f.member()},{"peer",f.member()},{"missing",nullptr}}}}}});
        assert(f.status()["reason"]=="waiting-snapshot");
        f.list();assert(f.status()["pending"]==true);
    }
    {Fixture f;f.list(true,true,1);f.enable();assert(f.status()["reason"]=="waiting-members");f.wait(106);assert(f.applied.empty());}
    for(Json unknown:{Json(nullptr),Json(false)}){
        Fixture f;f.list(true,unknown);f.enable();assert(f.status()["reason"]=="waiting-ready");
        f.ready("peer",true,101);assert(f.status()["pending"]==true);f.wait(106);assert(f.applied.size()==1);
    }
    {Fixture f;f.list(nullptr);f.enable();assert(!f.status()["pending"].get<bool>());f.ready("me",true);assert(f.status()["pending"]==true);}
    {Fixture f;f.list();f.receive({{"Set",{{"user",{{"peer",{{"file",Json::object()}}}}}}}});f.enable();assert(f.status()["reason"]=="waiting-ready");}
    {Fixture f(false,false);f.list();f.enable();assert(f.status()["reason"]=="unsupported");f.wait(106);assert(f.applied.empty());}
    { // Each explicit readiness cancellation invalidates the old deadline.
        Fixture f;f.list();f.enable();f.ready("peer",nullptr,102);f.wait(105);assert(f.applied.empty());
        f.ready("peer",true,106);assert(f.status()["pending"]==true);f.wait(110.9);assert(f.applied.empty());f.wait(111);assert(f.applied.size()==1);
    }
    { // Local ready withdrawal cancels before a potentially late server echo.
        Fixture f;f.list();f.enable();f.s.command({{"action","ready"},{"ready",false}});
        assert(f.s.status()["ready"]==true);f.wait(105);assert(f.applied.empty()&&!f.status()["pending"].get<bool>());
        f.ready("me",false,106);f.ready("me",true,106);assert(f.status()["pending"]==true);
    }
    { // Cancel stays blocked despite all-ready Lists and ticks; explicit enable rearms.
        Fixture f;f.list();f.enable();f.s.command({{"action","autostart-cancel"}});
        f.list();f.wait(105);assert(f.applied.empty()&&f.status()["reason"]=="waiting-reset");
        f.enable(3);f.wait(108);assert(f.applied.size()==1);
        size_t cancelled=0,started=0;for(const auto& e:f.events)if(e["type"]=="autostart"){if(e["action"]=="cancelled")++cancelled;if(e["action"]=="started")++started;assert(e.contains("id"));}
        assert(cancelled==1&&started==1);
    }
    {Fixture f;f.list();f.enable();f.s.command({{"action","autostart"},{"enabled",false}});f.wait(106);assert(f.applied.empty()&&f.status()["reason"]=="disabled");}
    for(int kind=0;kind<5;++kind){ // All player validity gates cancel and never resume on recovery.
        Fixture f;f.list();f.enable();
        if(kind==0)f.media.loaded=false;
        if(kind==1)f.media.buffering=true;
        if(kind==2)f.media.seekable=false;
        if(kind==3)f.media.speed=1.5;
        if(kind==4)f.media.paused=false;
        f.s.playback(f.media);f.media.loaded=true;f.media.buffering=false;f.media.seekable=true;f.media.speed=1;f.media.paused=true;f.s.playback(f.media);
        f.wait(106);assert(f.applied.empty()&&f.status()["reason"]=="waiting-reset");
        f.reset_phase();assert(f.status()["pending"]==true);f.wait(111);assert(f.applied.size()==1);
    }
    for(bool seek:{false,true}){Fixture f;f.list();f.enable();f.s.local_change(seek,101);f.wait(106);assert(f.applied.empty()&&!f.status()["pending"].get<bool>());}
    {Fixture f;f.list();f.enable();f.s.media_changed();f.wait(106);assert(f.applied.empty()&&f.status()["reason"]=="waiting-reset");}
    { // File loss/recovery with all ready flags unchanged is still one phase.
        Fixture f;f.list();f.enable();f.receive({{"Set",{{"user",{{"peer",{{"file",Json::object()}}}}}}}},101);
        f.receive({{"Set",{{"user",{{"peer",f.member()}}}}}},102);
        f.wait(106);assert(f.applied.empty()&&f.status()["reason"]=="waiting-reset");
    }
    for(int kind=0;kind<4;++kind){ // Join, leave, same-ready file change, and authoritative List replacement.
        Fixture f;f.list();f.enable();
        if(kind==0){auto m=f.member();m["event"]={{"joined",true}};f.receive({{"Set",{{"user",{{"new",m}}}}}},102);}
        if(kind==1)f.receive({{"Set",{{"user",{{"peer",{{"event",{{"left",true}}}}}}}}}},102);
        if(kind==2)f.receive({{"Set",{{"user",{{"peer",{{"file",{{"name","new.mkv"}}}}}}}}}},102);
        if(kind==3)f.list(true,true,1,false,102);
        f.wait(106);assert(f.applied.empty()&&!f.status()["pending"].get<bool>());
    }
    { // Peers in another room cannot block or count as participants.
        Fixture f;f.list();f.enable();f.receive({{"Set",{{"user",{{"elsewhere",{{"room",{{"name","other"}}},{"event",{{"joined",true}}}}}}}}}},101);
        assert(f.status()["pending"]==true&&f.status()["participants"]==2);f.wait(105);assert(f.applied.size()==1);
    }
    { // Controlled-room List metadata cannot grant local authorization.
        Fixture f(true);f.list(true,true,2,true);f.enable();assert(f.status()["reason"]=="no-permission");
        f.auth(true);assert(!f.status()["pending"].get<bool>());f.enable();assert(f.status()["pending"]==true);
        f.auth(false,102);f.auth(true,103);f.wait(106);assert(f.applied.empty()&&f.status()["reason"]=="waiting-reset");
        f.enable();f.wait(111);assert(f.applied.size()==1);
    }
    {Fixture f(true);f.list(true,true,2,true);f.auth(true);f.enable();f.list(true,true,2,false,102);f.wait(106);assert(f.applied.empty()&&f.status()["reason"]=="no-permission");}
    for(int kind=0;kind<3;++kind){
        Fixture f;f.list();f.enable();
        if(kind==0)f.s.command({{"action","room"},{"room","new"}});
        if(kind==1)f.s.disconnected("gone",true);
        if(kind==2)f.s.reconnect();
        f.wait(106);assert(f.applied.empty()&&f.status()["enabled"]==false);
    }
    { // Remote playback cancels the timer; its correction is the only apply.
        Fixture f;f.list();f.enable();f.receive({{"State",{{"playstate",{{"position",73},{"paused",false},{"setBy","peer"}}}}}},102);
        auto applied=f.applied.size();assert(!f.status()["pending"].get<bool>());f.wait(106);assert(f.applied.size()==applied&&f.changes()==0);
    }
    { // Repeated identical Lists do not restart the deadline; old time cannot expire it early.
        Fixture f;f.list();f.enable();f.list(true,true,2,false,102);f.wait(101);assert(f.status()["remaining"]==3);f.wait(105);assert(f.applied.size()==1);
    }
    {Fixture f;for(Json delay:{Json(2),Json(31),Json(4.5),Json(true),Json("5"),Json(18446744073709551615ull)}){bool rejected=false;try{f.s.command({{"action","autostart"},{"enabled",true},{"delay",delay}});}catch(const std::exception&){rejected=true;}assert(rejected);}assert(f.status()["enabled"]==false);}
    std::cout<<"autostart tests passed\n";
}
