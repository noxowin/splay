#include "../../src/core/session.hpp"
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>
using namespace splay;

struct Fixture {
    Session s;
    std::vector<Json> sent,events;
    Fixture(bool loaded=true){
        s.command({{"action","room-policy"},{"pause_on_join",false},{"pause_on_leave",false}});
        s.send=[&](const Json& value){sent.push_back(value);};
        s.event=[&](const Json& value){events.push_back(value);};
        Playback media;media.loaded=loaded;media.duration=300;s.playback(media);
        s.configure("localhost",8999,"me","room","");s.connected(false,100);
        receive({{"Hello",{{"username","me"},{"room",{{"name","room"}}},{"realversion","1.7.6"}}}},100);
        sent.clear();events.clear();
    }
    void receive(const Json& value,double now){s.receive(value.dump(),now);assert(s.logged());}
    void heartbeat(double now){receive({{"State",{{"ping",Json::object()}}}},now);}
    void sample(double sent_at,double received){heartbeat(sent_at);receive({{"State",{{"ping",{{"clientLatencyCalculation",sent_at}}}}}},received);}
    void enable(){s.command({{"action","latency"},{"enabled",true}});}
    bool enabled(){return s.latency_status()["enabled"];}
    Json own(){return s.latency_status()["self"];}
    // Null when peer is not a member; a member without a report is left out of
    // the latency message, which reads as an unreported value.
    Json peer(){
        bool member=false;
        const auto snapshot=s.status();
        for(const auto& value:snapshot["members"])if(value["username"]=="peer")member=true;
        if(!member)return Json();
        const auto reports=s.latency_status()["members"];
        return reports.contains("peer")?reports["peer"]:Json{{"rtt_ms",nullptr},{"reported",false},{"stale",false},{"self_reported",true}};
    }
    bool listed(){return s.latency_status()["members"].contains("peer");}
    void listing(const Json& metadata,double now,const std::string& room="room"){
        Json file={{"name","same.mkv"},{"duration",300},{"size",123}};
        if(!metadata.is_null())file["splayLatency"]=metadata;
        receive({{"List",{{room,{{"peer",{{"file",file},{"isReady",true}}}}}}}},now);
    }
};
static Json report(int seq=1,double value=125,const std::string& session="session_1234"){
    return {{"v",1},{"seq",seq},{"rtt_ms",value},{"session",session}};
}
int main(){
    Fixture f;
    assert(f.enabled()==false&&f.own()["rtt_ms"].is_null());
    // The main state carries no latency at all; it has its own message.
    assert(f.s.latency_status()["schema"]==1&&f.s.latency_status()["members"].empty()&&!f.s.status().contains("latency"));
    f.sample(101,101.2);f.s.tick(101.3);
    for(const auto& value:f.sent)if(value.contains("Set"))assert(!value["Set"].contains("file"));
    f.enable();
    assert(std::abs(f.own()["rtt_ms"].get<double>()-200)<.001);
    assert(f.own()["self_reported"]==false);
    auto shared=f.sent[f.sent.size()-2]["Set"]["file"];
    assert(shared["splayLatency"]["seq"]==1&&shared["splayLatency"]["session"].get<std::string>().size()==16);
    assert(shared["name"]=="**Hidden filename**"&&shared["duration"]==300&&shared["size"]==0);
    auto firstSession=shared["splayLatency"]["session"];
    f.sent.clear();f.s.tick(110);assert(f.sent.empty());
    f.heartbeat(111.3);f.sent.clear();f.s.tick(111.4);
    assert(f.sent.size()==1&&f.sent[0]["Set"]["file"]["splayLatency"]["seq"]==2);
    assert(f.sent[0]["Set"]["file"]["splayLatency"]["session"]==firstSession);
    f.listing(nullptr,111.5);assert(!f.listed()); // A member without a report is not listed.
    f.listing(report(),112);assert(f.peer()["rtt_ms"]==125&&f.peer()["self_reported"]==true);
    assert(f.listed()&&!f.s.latency_status()["members"].contains("me")); // Own value is only under "self".
    f.receive({{"Set",{{"user",{{"peer",{{"file",{{"name","same.mkv"},{"duration",300},{"size",123},{"splayLatency",report(2,145)}}}}}}}}}},113);
    assert(f.peer()["rtt_ms"]==145);
    for(const auto& event:f.events)assert(event.value("action","")!="file");
    const auto snapshot=f.s.status();for(const auto& member:snapshot["members"])assert(!member["file"].contains("splayLatency")&&!member.contains("latency"));
    f.receive({{"Set",{{"user",{{"peer",{{"isReady",false}}}}}}}},114);
    assert(f.peer()["rtt_ms"]==145); // Partial readiness updates preserve reports.
    f.listing(report(2,145),130);f.listing(report(1,999),142);
    assert(f.peer()["rtt_ms"]==145); // Older sequence cannot replace fresh data.
    f.heartbeat(143.1);f.s.tick(143.2);
    assert(f.peer()["stale"]==true&&f.peer()["rtt_ms"].is_null()&&f.listed()); // Stale stays listed, without a value.
    f.listing(report(2,145),144);
    assert(f.peer()["stale"]==true); // Duplicate authoritative List does not renew TTL.
    f.listing(report(3,0),145);assert(f.peer()["rtt_ms"]==0&&f.peer()["stale"]==false);
    f.listing(nullptr,146);assert(f.peer()["reported"]==false&&!f.listed());
    f.listing(report(3,0),147);assert(f.peer()["reported"]==false); // Withdrawal cannot replay old metadata.
    std::vector<Json> invalid;
    for(const auto& change:std::vector<Json>{Json{{"v",2}},Json{{"v",1.0}},Json{{"seq",1.5}},Json{{"seq",-1}},
        Json{{"seq",2147483648ULL}},Json{{"rtt_ms",-1}},Json{{"rtt_ms",10001}},Json{{"rtt_ms","12"}},
        Json{{"session","a"}},Json{{"session",std::string(33,'a')}},Json{{"session","bad session"}}}){
        auto value=report(4);value.update(change);invalid.push_back(value);
    }
    invalid.push_back(Json::array());invalid.push_back(Json{{"v",1}});
    for(const auto& value:invalid){f.listing(value,148);assert(f.peer()["rtt_ms"].is_null()&&f.s.logged());}
    f.listing(report(5,10000),149);assert(f.peer()["rtt_ms"]==10000);
    f.listing(report(6),150,"elsewhere");assert(f.peer()["rtt_ms"].is_null()&&!f.listed());
    f.listing(report(7),151);f.receive({{"Set",{{"user",{{"peer",{{"event",{{"left",true}}}}}}}}}},152);
    assert(f.peer().is_null()&&!f.listed());
    f.listing(report(8),153);f.s.command({{"action","latency"},{"enabled",false}});
    assert(f.own()["rtt_ms"].is_null()&&f.peer()["rtt_ms"].is_null()&&!f.listed()&&f.enabled()==false);
    f.s.command({{"action","latency"},{"enabled",true}});
    assert(f.peer()["rtt_ms"].is_null());
    f.sample(154,154.1);f.sent.clear();f.s.tick(154.2);
    assert(f.sent.size()==1&&f.sent[0]["Set"]["file"].contains("splayLatency"));
    f.sent.clear();f.s.command({{"action","latency"},{"enabled",false}});
    assert(f.sent.size()==2&&!f.sent[0]["Set"]["file"].contains("splayLatency"));
    assert(f.sent[0]["Set"]["file"]["duration"]==300);
    f.sent.clear();f.heartbeat(164);f.sent.clear();f.s.tick(164.1);assert(f.sent.empty());

    Fixture g;g.enable();assert(g.own()["rtt_ms"].is_null()&&g.own()["reported"]==false);
    // Unsolicited, string, future and replayed timestamp values do not produce samples.
    g.receive({{"State",{{"ping",{{"clientLatencyCalculation",100}}}}}},101);
    g.receive({{"State",{{"ping",{{"clientLatencyCalculation","101"}}}}}},101.1);
    assert(g.own()["rtt_ms"].is_null());
    g.sample(102,102.2);double measured=g.own()["rtt_ms"];
    g.receive({{"State",{{"ping",{{"clientLatencyCalculation",102}}}}}},103);
    assert(g.own()["rtt_ms"]==measured);
    // A new measurement changes the latency message and nothing in the main state.
    {const auto state=g.s.status();const auto shown=g.s.latency_status();
     g.sample(104,104.4);assert(g.s.status()==state&&g.s.latency_status()!=shown);}
    assert(std::abs(g.own()["rtt_ms"].get<double>()-230)<.001);
    // Official 1.7.6 adds its processing/dwell duration to the echoed timestamp.
    g.heartbeat(105);g.receive({{"State",{{"ping",{{"clientLatencyCalculation",105.9}}}}}},106.1);
    // Smoothed to 225.5 ms; status reports whole milliseconds.
    {const double shown=g.own()["rtt_ms"];assert(shown==std::round(shown)&&std::abs(shown-225.5)<=.5);}
    g.heartbeat(135);g.s.tick(136.2);assert(g.own()["stale"]==true&&g.own()["rtt_ms"].is_null());
    g.s.command({{"action","room"},{"room","newroom"}});
    assert(g.own()["reported"]==false&&g.own()["rtt_ms"].is_null());
    g.s.disconnected();assert(g.enabled()==true&&g.own()["rtt_ms"].is_null());
    g.s.reconnect();assert(g.own()["rtt_ms"].is_null());

    // The transport stamps arrival. Time spent waiting to be processed is not
    // network latency, and a stamp later than processing time is not trusted.
    Fixture arrival;arrival.enable();arrival.heartbeat(200);
    arrival.s.receive(Json{{"State",{{"ping",{{"clientLatencyCalculation",200}}}}}}.dump(),200.25,200.2);
    assert(arrival.own()["rtt_ms"]==200);
    Fixture ahead;ahead.enable();ahead.heartbeat(300);
    ahead.s.receive(Json{{"State",{{"ping",{{"clientLatencyCalculation",300}}}}}}.dump(),300.1,300.9);
    assert(ahead.own()["rtt_ms"]==100);
    Fixture empty(false);empty.enable();empty.sample(101,101.1);empty.sent.clear();empty.s.tick(102);
    assert(empty.own()["rtt_ms"].is_number()&&empty.sent.empty());
    empty.s.media_changed();assert(empty.sent[0]["Set"]["file"].empty());
    std::cout<<"latency default privacy, validated heartbeat, metadata, freshness, withdrawal and lifecycle checks passed\n";
}
