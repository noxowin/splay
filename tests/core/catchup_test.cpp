#include "../../src/core/session.hpp"
#include <cassert>
#include <cmath>
#include <iostream>
#include <string>
#include <vector>
using namespace splay;

// A connected, playing player in an ordinary room. The apply callback acts
// like the adapter: a speed is only replaced when the player still has the
// speed the core expects.
struct Fixture {
    Session s;
    std::vector<Json> sent,events;
    std::vector<Correction> applied;
    Playback media;
    double now=100;
    Fixture(){
        s.command({{"action","room-policy"},{"pause_on_join",false},{"pause_on_leave",false}});
        s.send=[&](const Json& value){sent.push_back(value);};
        s.event=[&](const Json& value){events.push_back(value);};
        s.apply=[&](const Correction& c){
            applied.push_back(c);
            if(c.speed&&std::abs(media.speed-c.speed_from)<.001)media.speed=*c.speed;
            if(c.position)media.position=*c.position;
            if(c.paused)media.paused=*c.paused;
        };
        media.loaded=true;media.duration=300;media.position=100;media.paused=false;
        s.playback(media);
        s.configure("localhost",8999,"me","room","");s.connected(false,now);
        s.receive(Json{{"Hello",{{"username","me"},{"room",{{"name","room"}}},{"realversion","1.7.6"}}}}.dump(),now);
        room(100);
        applied.clear();events.clear();
    }
    // A room state as the official server sends it, from the slowest watcher.
    void room(double position,bool paused=false,const std::string& by="peer",bool seek=false){
        now+=1;
        Json playstate={{"position",position},{"paused",paused},{"setBy",by}};
        if(seek)playstate["doSeek"]=true;
        s.receive(Json{{"State",{{"playstate",playstate}}}}.dump(),now);
    }
    // The adapter's next sample of the player.
    void local(double position){media.position=position;s.playback(media);}
    bool active(){return s.status()["catchup"]["active"].get<bool>();}
    std::string warning(){return s.status()["warning"].get<std::string>();}
    size_t catchup_events(const std::string& action){
        size_t n=0;for(const auto& e:events)if(e.value("type","")=="catchup"&&e.value("action","")==action)++n;return n;
    }
    // Ahead of the room by 2 s: the player slows down instead of seeking back.
    void slow(){
        local(102);room(100);
        assert(!applied.empty()&&applied.back().speed&&*applied.back().speed==.95&&applied.back().speed_from==1);
        assert(!applied.back().position&&media.speed==.95&&active());
    }
};

int main(){
    {
        Fixture f;
        assert(f.s.status()["catchup"]["enabled"]==true&&!f.active());
        f.slow();
        assert(f.catchup_events("slow")==1&&f.events.back()["username"]=="peer");
        // splay's own speed is normal speed: no warning, and reports go on.
        f.local(102);
        assert(f.warning().empty()&&f.active());
        f.sent.clear();f.room(100.5);
        assert(f.sent.back()["State"].contains("playstate"));
        // Still ahead, but less: keep going, no new correction.
        const auto count=f.applied.size();
        f.local(101.2);f.room(100.4);
        assert(f.applied.size()==count&&f.active());
        // Caught up: back to 1x, the player is not moved.
        f.local(100.55);f.room(100.5);
        assert(f.applied.back().speed&&*f.applied.back().speed==1&&f.applied.back().speed_from==.95);
        assert(!f.applied.back().position&&f.media.speed==1&&!f.active()&&f.catchup_events("normal")==1);
    }
    {
        // Below the threshold nothing happens; behind is handled as before.
        Fixture f;
        f.local(101.4);f.room(100);
        f.local(99);f.room(100);
        assert(f.applied.empty());
        f.local(98);f.room(100);
        assert(f.applied.size()==1&&f.applied.back().position&&*f.applied.back().position==100&&!f.applied.back().speed);
    }
    {
        // A larger lead is rewound, and a running catch-up ends with it.
        Fixture f;
        f.local(104.5);f.room(100);
        assert(f.applied.back().position&&*f.applied.back().position==100&&!f.applied.back().speed&&!f.active());
        f.applied.clear();
        f.slow();
        f.local(105);f.room(100.5);
        assert(f.applied.back().position&&*f.applied.back().position==100.5);
        assert(f.applied.back().speed&&*f.applied.back().speed==1&&f.media.speed==1&&!f.active());
        assert(f.catchup_events("normal")==0);
    }
    {
        // The room clock being this player's own report is no reason to slow down.
        Fixture f;
        f.local(102);f.room(100,false,"me");
        assert(f.applied.empty()&&!f.active());
    }
    {
        // A paused room or a room seek ends the catch-up.
        Fixture f;
        f.slow();
        f.local(101);f.room(100,true);
        assert(f.applied.back().paused&&*f.applied.back().paused);
        assert(f.applied.back().speed&&*f.applied.back().speed==1&&!f.active());
        Fixture g;
        g.slow();
        g.local(101);g.room(40,false,"peer",true);
        assert(g.applied.back().position&&*g.applied.back().position==40&&g.applied.back().speed&&*g.applied.back().speed==1);
    }
    {
        // A speed the user chooses is theirs: nothing is restored over it,
        // synchronization waits for 1.0 as before, and the catch-up is over.
        Fixture f;
        f.slow();
        f.media.speed=1.25;f.local(102);
        assert(!f.active()&&!f.warning().empty());
        const auto count=f.applied.size();
        f.room(100);f.s.disconnected();
        assert(f.applied.size()==count&&f.media.speed==1.25);
        // The user setting 1.0 themselves also ends it without a correction.
        Fixture g;
        g.slow();
        g.media.speed=1;g.local(101.5);
        assert(!g.active()&&g.warning().empty());
    }
    {
        // A local gesture, leaving, new media, an offset change or switching
        // the feature off each restore 1x.
        Fixture f;
        f.slow();f.s.local_change(true,f.now);
        assert(f.applied.back().speed&&*f.applied.back().speed==1&&!f.active());
        Fixture g;
        g.slow();g.s.disconnected();
        assert(g.applied.back().speed&&*g.applied.back().speed==1&&g.media.speed==1);
        Fixture h;
        h.slow();h.s.media_changed();
        assert(h.applied.back().speed&&*h.applied.back().speed==1&&h.media.speed==1);
        Fixture i;
        i.slow();i.s.command({{"action","set-offset"},{"seconds",5}},i.now);
        assert(i.media.speed==1&&!i.active());
        Fixture j;
        j.slow();j.s.command({{"action","catchup"},{"enabled",false}},j.now);
        assert(j.media.speed==1&&!j.active()&&j.s.status()["catchup"]["enabled"]==false);
        // Switched off, a 2 s lead is sought back as before.
        j.applied.clear();j.local(102);j.room(100);
        assert(j.applied.back().position&&*j.applied.back().position==100&&!j.applied.back().speed);
        bool rejected=false;
        try{j.s.command({{"action","catchup"},{"enabled","no"}},j.now);}catch(const std::exception&){rejected=true;}
        assert(rejected);
    }
    {
        // The local time offset is part of the target.
        Fixture f;
        f.s.command({{"action","set-offset"},{"seconds",10}},f.now);
        f.applied.clear();
        f.local(112);f.room(100);
        assert(f.applied.back().speed&&*f.applied.back().speed==.95&&f.active());
        f.local(110.05);f.room(100);
        assert(f.media.speed==1&&!f.active());
    }
    {
        // A live stream is never slowed down.
        Fixture f;
        f.media.seekable=false;f.local(102);f.room(100);
        assert(f.applied.empty()&&!f.active());
    }
    std::cout<<"catch-up slowdown, restore, rewind, user speed, lifecycle and offset checks passed\n";
}
