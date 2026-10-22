#include "../../src/core/session.hpp"
#include <cassert>
#include <cmath>
#include <iostream>
using namespace splay;

struct Fixture {
    Session s;
    Playback media;
    std::vector<Json> sent;
    std::vector<Correction> applied;
    std::string room;
    explicit Fixture(bool managed=false):room(managed?"+ctl:ABCDEFGHIJKL":"room"){
        s.send=[&](const Json& j){sent.push_back(j);};
        s.apply=[&](const Correction& c){applied.push_back(c);};
        media.loaded=true;media.paused=false;media.position=37;media.duration=600;
        s.playback(media);connect();clear();
    }
    void connect(){
        s.configure("localhost",8999,"me",room,"");s.connected(false,100);
        receive({{"Hello",{{"username","me"},{"room",{{"name",room}}},{"realversion","1.7.6"}}}});
    }
    void receive(const Json& j,double now=100){s.receive(j.dump(),now);assert(s.logged());}
    Json member(bool controller=false){return {{"file",{{"name","film.mkv"}}},{"isReady",true},{"controller",controller}};}
    void list(bool peer=true,bool controller=false){
        Json members={{"me",member(controller)}};
        if(peer)members["peer"]=member();
        receive({{"List",{{room,members}}}});
    }
    void state(double position=180,bool paused=false,double now=100,unsigned ack=0){
        Json state={{"playstate",{{"position",position},{"paused",paused},{"setBy","peer"}}}};
        if(ack)state["ignoringOnTheFly"]={{"client",ack}};
        receive({{"State",state}},now);
    }
    void policy(bool leave,bool join){s.command({{"action","room-policy"},{"pause_on_leave",leave},{"pause_on_join",join}});}
    void change(const std::string& user,const Json& value,double now=100){receive({{"Set",{{"user",{{user,value}}}}}},now);}
    void join(const std::string& user="new",const std::string& destination="room",double now=100){
        change(user,{{"event",{{"joined",true}}},{"room",{{"name",destination}}}},now);
    }
    void leave(const std::string& user="peer",double now=100){change(user,{{"event",{{"left",true}}}},now);}
    void auth(bool success=true){receive({{"Set",{{"controllerAuth",{{"user","me"},{"room",room},{"success",success}}}}}});}
    void clear(){sent.clear();applied.clear();}
    std::vector<Json> changes(){
        std::vector<Json> result;
        for(const auto& j:sent)if(j.contains("State")&&j["State"].contains("playstate")&&
           j["State"].contains("ignoringOnTheFly")&&j["State"]["ignoringOnTheFly"].contains("client"))result.push_back(j["State"]);
        return result;
    }
    void established(){policy(false,false);list();state();policy(true,true);clear();}
};

int main(){
    { // Preferences are strict booleans and survive both reconnect and room changes.
        Fixture f;assert(f.s.status()["room_policy"]==Json({{"pause_on_leave",true},{"pause_on_join",true}}));
        for(Json invalid:{Json(1),Json("false"),Json(nullptr)}){
            bool rejected=false;try{f.s.command({{"action","room-policy"},{"pause_on_leave",invalid},{"pause_on_join",true}});}catch(...){rejected=true;}
            assert(rejected&&f.s.status()["room_policy"]["pause_on_leave"]==true);
        }
        f.policy(false,true);f.s.reconnect();assert(!f.s.status()["room_policy"]["pause_on_leave"].get<bool>());
        f.connect();f.s.command({{"action","room"},{"room","other"}});
        assert(f.s.status()["room_policy"]==Json({{"pause_on_leave",false},{"pause_on_join",true}}));
    }
    for(bool stateFirst:{false,true}){ // Both wire orderings must align before the sole room pause.
        Fixture f;f.media.position=0;f.s.playback(f.media);
        if(stateFirst){f.state();assert(f.applied.empty()&&f.changes().empty());}
        f.list();if(!stateFirst)assert(f.applied.empty()&&f.changes().empty());
        if(!stateFirst)f.state();
        assert(f.applied.size()==1&&f.applied[0].position==180&&f.applied[0].paused==true);
        auto changes=f.changes();assert(changes.size()==1&&changes[0]["playstate"]["position"]==180&&changes[0]["playstate"]["paused"]==true);
        assert(!changes[0]["playstate"].contains("doSeek"));
        f.list();f.state(180,true,100,1);f.state(180,true);
        assert(f.changes().size()==1&&f.applied.size()==1);
    }
    { // No position reports, corrections or local gestures can send the joining clock before the complete List.
        Fixture f;f.state();f.s.local_change(false,100);
        f.receive({{"List",{{f.room,{{"me",f.member()},{"peer",nullptr}}}}}});
        f.state(181);assert(f.changes().empty()&&f.applied.empty());
        for(const auto& j:f.sent)if(j.contains("State"))assert(!j["State"].contains("playstate"));
        f.list();assert(f.changes().size()==1&&f.applied[0].position==181);
    }
    { // Invalid State and ping-only traffic do not satisfy the join clock requirement.
        Fixture f;f.list();f.receive({{"State",{{"ping",Json::object()},{"playstate",{{"position","180"},{"paused",false}}}}}});
        assert(f.applied.empty()&&f.changes().empty());f.state(182);assert(f.changes().size()==1&&f.applied[0].position==182);
    }
    for(bool stateFirst:{false,true}){ // Empty ordinary rooms keep the loaded media's starting time.
        Fixture f;if(stateFirst)f.state(0,true);f.list(false);
        if(!stateFirst)f.state(0,true);
        assert(f.applied.empty()&&f.changes().empty());
        bool reported=false;for(const auto& j:f.sent)if(j.contains("State")&&j["State"].contains("playstate")){
            assert(j["State"]["playstate"]["position"]==37);reported=true;
        }
        assert(reported);
    }
    { // Another room in the complete List is not an existing local participant.
        Fixture f;f.receive({{"List",{{f.room,{{"me",f.member()}}},{"other",{{"peer",f.member()}}}}}});
        f.state(0,true);assert(f.applied.empty()&&f.changes().empty());
    }
    { // Joining an already paused room aligns, without a second room action or transient unpause.
        Fixture f;f.list();f.state(192,true);
        assert(f.changes().empty()&&f.applied.size()==1&&f.applied[0].position==192&&f.applied[0].paused==true);
    }
    { // Offset applies locally while the pause stays in authoritative room coordinates.
        Fixture f;f.s.command({{"action","set-offset"},{"seconds",20}});f.clear();f.list();f.state(200);
        assert(f.applied.size()==1&&f.applied[0].position==220&&f.changes()[0]["playstate"]["position"]==200);
    }
    { // Even an offset clamped at EOF cannot pull the room clock back to this file's end.
        Fixture f;f.media.duration=210;f.s.playback(f.media);
        f.s.command({{"action","set-offset"},{"seconds",20}});f.clear();f.list();f.state(200);
        assert(f.applied[0].position==209&&f.changes()[0]["playstate"]["position"]==200);
    }
    { // Buffer protection delays alignment and broadcasting until the media recovers.
        Fixture f;f.media.buffering=true;f.s.playback(f.media);f.list();f.state(200);
        assert(f.applied.empty()&&f.changes().empty()&&f.s.status()["warning"]=="");
        f.media.buffering=false;f.s.playback(f.media);
        assert(f.applied.size()==1&&f.applied[0].position==200&&f.changes().size()==1);
    }
    for(bool gesture:{false,true}){ // A later gesture or disabling the policy cancels a deferred buffer pause.
        Fixture f;f.media.buffering=true;f.s.playback(f.media);f.list();f.state(200);
        if(gesture)f.s.local_change(false,100);else f.policy(true,false);
        f.media.buffering=false;f.s.playback(f.media);f.state(201);
        assert(f.changes().empty());
        for(const auto& correction:f.applied)assert(correction.paused!=true);
    }
    { // A loaded file is not required to safely pause the room at its authoritative clock.
        Fixture f;f.media.loaded=false;f.s.playback(f.media);f.list();f.state(200);
        assert(f.changes().size()==1&&f.changes()[0]["playstate"]["position"]==200);
        for(const auto& c:f.applied)assert(!c.position);
    }
    for(bool leave:{false,true}){ // Real same-room joins/leaves pause at the running room clock.
        Fixture f;f.established();if(leave)f.leave("peer",102);else f.join("new",f.room,102);
        auto changes=f.changes();assert(changes.size()==1&&changes[0]["playstate"]["position"]==182);
        assert(f.applied.size()==1&&f.applied[0].paused==true&&!f.applied[0].position);
        if(leave)f.leave("peer",102);else f.join("new",f.room,102);
        assert(f.changes().size()==1&&f.applied.size()==1);
    }
    { // Room switches count as leave and join, with no controller fabrication.
        Fixture f;f.established();f.change("peer",{{"room",{{"name","other"}}}});
        assert(f.changes().size()==1);f.state(180,true,100,1);f.state(181,false);f.clear();
        f.change("peer",{{"room",{{"name",f.room}}}});assert(f.changes().size()==1);
    }
    { // Complete List refreshes and unrelated or repeated membership packets do not pause.
        Fixture f;f.established();f.list();f.join("remote","other");f.leave("remote");f.leave("unknown");
        f.join("peer",f.room);f.change("peer",{{"file",{{"name","updated.mkv"}}}});
        f.change("peer",{{"event",{{"left",false}}}});assert(f.changes().empty()&&f.applied.empty());
        // An unrecognized departure must not disable later real departures.
        f.leave("peer");assert(f.changes().size()==1&&f.applied.back().paused==true);
    }
    for(bool leave:{false,true}){
        Fixture f;f.established();f.policy(!leave,leave);if(leave)f.leave();else f.join();
        assert(f.changes().empty()&&f.applied.empty());
    }
    { // An existing authenticated owner pauses a new join, while ordinary members cannot.
        Fixture f(true);f.established();f.list(true,true);f.clear();f.join("new",f.room);
        assert(f.changes().empty()&&f.applied.empty()); // List alone never grants automatic control.
        f.auth();f.join("another",f.room);assert(f.changes().size()==1&&f.applied.back().paused==true);
        f.state(180,true,100,1);f.state(182,false);f.auth(false);f.clear();f.leave();assert(f.changes().empty());
    }
    { // A joining ordinary member in a controlled room follows playback and sends no automatic pause.
        Fixture f(true);f.list(true,true);f.state(198,false);
        assert(f.changes().empty()&&f.applied.size()==1&&f.applied[0].position==198);
        assert(!f.applied[0].paused); // It was already playing and never receives a local hold.
    }
    { // Reconnect clears membership/permission authority, and keeps user preferences.
        Fixture f(true);f.established();f.list(true,true);f.auth();f.s.reconnect();f.connect();f.clear();
        f.list(true,true);f.state(180);assert(f.changes().empty());
        f.leave();assert(f.changes().empty());
    }
    { // Controlled-room creation must request the snapshot that unlocks its join policy.
        Fixture f;f.established();
        const std::string created="+created:ABCDEFGHIJKL";
        f.receive({{"Set",{{"newControlledRoom",{{"roomName",created},{"password","AB-123-456"}}}}}});
        size_t requests=0;
        for(const auto& j:f.sent)if(j.contains("List"))++requests;
        assert(requests==1&&f.s.status()["room"]==created);
        f.room=created;f.clear();f.state(90,true);
        assert(f.applied.empty()); // State alone never bypasses the complete List requirement.
        f.receive({{"List",{{created,{{"peer",f.member()}}}}}});f.state(90,true);
        assert(f.applied.empty()); // A snapshot missing our own member cannot unlock joining.
        f.auth();f.list(false,true);f.clear();f.state(25,true);
        assert(f.applied.size()==1&&f.applied.back().position==25&&f.changes().empty());
        // A same-room echo refreshes membership without restarting the join policy.
        f.clear();f.receive({{"Set",{{"room",{{"name",created}}}}}});
        assert(f.sent.size()==1&&f.sent[0].contains("List"));
        f.state(30,true);assert(f.applied.back().position==30&&f.changes().empty());
    }
    { // A room-membership pause cancels an already-running automatic start.
        Fixture f;f.established();f.media.paused=true;f.media.position=180;f.s.playback(f.media);
        f.s.command({{"action","autostart"},{"enabled",true},{"delay",3}});
        assert(f.s.status()["autostart"]["pending"]==true);f.join();
        assert(f.s.status()["autostart"]["pending"]==false);const auto count=f.changes().size();
        f.s.tick(104);assert(f.changes().size()==count);
    }
    for(double offset:{-86400.0,86400.0}){ // Missing segments hold this player without reaching EOF or changing the room clock.
        Fixture f;f.established();f.s.command({{"action","set-offset"},{"seconds",offset}},100);
        assert(f.s.status()["time_offset_boundary"]==true&&f.applied.back().paused==true);
        const double held=*f.applied.back().position;
        assert(held==(offset<0?0:599)&&held<600&&f.changes().empty());
        f.clear();f.state(181,false,101);
        for(const auto& j:f.sent)if(j.contains("State")){
            assert(j["State"]["playstate"]==Json({{"position",181},{"paused",false}}));
            assert(!j["State"].contains("ignoringOnTheFly"));
        }
        for(const auto& correction:f.applied)assert(correction.paused!=false);
        // Simulate the player feedback after the protected seek.
        f.media.position=held;f.media.paused=true;f.s.playback(f.media);f.clear();
        f.s.command({{"action","set-offset"},{"seconds",0}},102);
        assert(f.s.status()["time_offset_boundary"]==false&&f.applied.size()==1);
        assert(f.applied[0].position==182&&f.applied[0].paused==false&&f.sent.empty());
    }
    { // Ping-only replies must advance the virtual watcher rather than freeze its last reported clock.
        Fixture f;f.established();f.s.command({{"action","set-offset"},{"seconds",86400}},100);
        f.media.position=599;f.media.paused=true;f.s.playback(f.media);f.clear();
        for(double now:{101.0,102.0,103.0}){
            f.receive({{"State",{{"ping",{{"latencyCalculation",now}}}}}},now);
            const auto& reply=f.sent.back()["State"];
            assert(reply["playstate"]==Json({{"position",180+now-100},{"paused",false}}));
            assert(!reply.contains("ignoringOnTheFly"));
        }
        f.state(184,true,104);f.clear();
        f.receive({{"State",{{"ping",Json::object()}}}},105);
        assert(f.sent.back()["State"]["playstate"]==Json({{"position",184},{"paused",true}}));
        assert(f.s.status()["time_offset_boundary"]==true&&f.changes().empty());
    }
    { // A held ordinary member never turns its local pause into a controlled-room action.
        Fixture f(true);f.established();
        f.s.command({{"action","set-offset"},{"seconds",86400}},100);
        f.media.position=599;f.media.paused=true;f.s.playback(f.media);f.clear();
        f.join("new",f.room,101);f.state(181,false,101);
        assert(f.changes().empty()&&f.s.status()["time_offset_boundary"]==true);
        assert(f.sent.back()["State"]["playstate"]==Json({{"position",181},{"paused",false}}));
    }
    { // Crossing an offset endpoint during playback is protected between server State messages.
        Fixture f;f.established();f.s.command({{"action","set-offset"},{"seconds",419}},100);
        assert(f.applied.back().position==599&&!f.s.status()["time_offset_boundary"].get<bool>());
        f.clear();f.s.tick(101);
        assert(f.s.status()["time_offset_boundary"]==true&&f.applied.back().paused==true);
        assert(f.applied.back().position==599&&f.changes().empty());
    }
    { // A room advancing into a negative-offset segment automatically resumes local playback.
        Fixture f;f.established();f.s.command({{"action","set-offset"},{"seconds",-181}},100);
        assert(f.s.status()["time_offset_boundary"]==true&&f.applied.back().position==0);
        f.clear();f.s.tick(102);
        assert(f.s.status()["time_offset_boundary"]==false&&f.applied.back().position==1&&f.applied.back().paused==false);
        assert(f.changes().empty());
    }
    { // The room can pause during the local hold; restoration follows its latest authoritative pause.
        Fixture f;f.established();f.s.command({{"action","set-offset"},{"seconds",86400}},100);
        f.state(181,true,101);f.clear();f.s.command({{"action","set-offset"},{"seconds",0}},102);
        assert(f.applied.back().position==181&&f.applied.back().paused!=false&&f.changes().empty());
    }
    { // A local play toggle during a boundary hold cannot publish its clamped coordinates.
        Fixture f;f.established();f.s.command({{"action","set-offset"},{"seconds",86400}},100);
        f.media.position=599;f.media.paused=false;f.s.playback(f.media);f.clear();f.s.local_change(false,101);
        assert(f.changes().empty()&&f.applied.back().paused==true&&f.s.status()["time_offset_boundary"]==true);
    }
    std::cout<<"room policy tests passed\n";
}
