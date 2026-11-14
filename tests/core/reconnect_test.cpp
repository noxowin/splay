#include "../../src/core/reconnect.hpp"
#include "../../src/core/session.hpp"
#include <cassert>
#include <iostream>
#include <vector>

using namespace splay;
int main(){
    {
        // The adapter stops polling the player while idle() holds.
        Session quiet;assert(quiet.idle()&&quiet.connection()=="disconnected"&&quiet.error().empty());
        quiet.send=[](const Json&){};
        quiet.command({{"action","set-offset"},{"seconds",5}},1);assert(!quiet.idle());
        quiet.command({{"action","set-offset"},{"seconds",0}},2);assert(quiet.idle());
        quiet.configure("localhost",8999,"me","room","");assert(!quiet.idle()&&quiet.connection()=="connecting"&&quiet.room()=="room");
        quiet.connected(false,3);
        quiet.receive(R"({"Hello":{"username":"me","room":{"name":"room"},"realversion":"1.7.6"}})",3);
        assert(quiet.logged()&&!quiet.idle()&&quiet.connection()=="connected");
        quiet.disconnected("Connection closed",true);
        assert(quiet.idle()&&quiet.connection()=="error"&&quiet.error()=="Connection closed");
        quiet.disconnected();assert(quiet.idle()&&quiet.connection()=="disconnected");
        Reconnect waiting;assert(waiting.remaining(0)==0);
        waiting.start(true);waiting.failed(true,"lost",10);
        assert(waiting.pending()&&waiting.remaining(10)==2&&waiting.remaining(11.5)==1&&waiting.remaining(13)==0);
        assert(waiting.status(10)["remaining"]==2);
    }
    Reconnect r;
    assert(!r.status(0)["enabled"].get<bool>()&&!r.failed(true,"offline",0)&&!r.due(100));
    r.start(false);assert(!r.failed(true,"offline",0));
    r.start(true);double now=100;const int delays[]={2,5,10,30,30};
    for(int attempt=1;attempt<=5;++attempt){
        assert(r.failed(true,"offline",now));
        assert(r.status(now)["attempt"]==attempt&&r.status(now)["delay"]==delays[attempt-1]);
        assert(!r.due(now+delays[attempt-1]-.01));
        now+=delays[attempt-1];assert(r.due(now)&&!r.due(now));
    }
    assert(!r.failed(true,"offline",now)&&!r.pending());
    assert(r.status(now)["reason"].get<std::string>().find("limit")!=std::string::npos);
    r.start(true);assert(r.failed(true,"offline",now));r.connected();
    assert(r.status(now)["attempt"]==0&&r.failed(true,"offline",now)&&r.status(now)["delay"]==2);
    auto generation=r.generation();r.cancel();assert(r.generation()!=generation&&!r.due(now+1000));
    r.start(true);assert(r.failed(true,"offline",now));r.disable();assert(!r.due(now+1000));
    r.enable();assert(!r.due(now+1000)); // Enabling cannot resurrect a cancelled timer.
    r.cancel();r.enable();assert(!r.failed(true,"offline",now)); // No connect consent.
    r.start(true);assert(r.failed(true,"offline",now));generation=r.generation();r.room_changed();
    assert(generation!=r.generation()&&!r.due(now+1000));
    for(const auto& reason:{"Bad password","Server rejected the request","TLS handshake or certificate validation failed"}){
        r.start(true);assert(!r.failed(false,reason,now)&&!r.due(now+1000));
    }

    Session s;std::vector<Json> sent;size_t corrections=0;
    s.send=[&](const Json& j){sent.push_back(j);};
    s.apply=[&](const Correction&){++corrections;};
    Playback p;p.loaded=true;p.paused=true;p.position=17;p.duration=120;p.speed=1.25;s.playback(p);
    s.configure("127.0.0.1",8999,"me","base","test-only-password");s.connected(false,100);
    const auto hash=sent.back()["Hello"]["password"];
    s.receive(R"({"Hello":{"username":"me","room":{"name":"base"},"version":"1.7.6"}})",100);
    s.receive(R"({"Set":{"newControlledRoom":{"roomName":"+base:ABCDEFGHIJKL","password":"AA-123-456"}}})",101);
    s.receive(R"({"Set":{"controllerAuth":{"user":"me","room":"+base:ABCDEFGHIJKL","success":true},"ready":{"username":"me","isReady":true}}})",101);
    assert(s.status()["ready"]==true&&s.status()["is_controller"]==true);
    sent.clear();s.disconnected("Socket read failed",true);assert(s.retryable());s.reconnect();s.connected(false,102);
    assert(sent.size()==1&&sent.back()["Hello"]["password"]==hash);
    assert(sent.back()["Hello"]["room"]["name"]=="+base:ABCDEFGHIJKL");
    assert(s.status()["ready"]==false&&s.status()["is_controller"]==false&&corrections==0);
    s.receive(R"({"Hello":{"username":"me","room":{"name":"+base:ABCDEFGHIJKL"},"version":"1.7.6"}})",102);
    assert(s.status()["warning"].get<std::string>().find("speed")!=std::string::npos&&corrections==0);
    for(const auto& message:sent)if(message.contains("Set")){
        assert(!message["Set"].contains("controllerAuth"));
        if(message["Set"].contains("ready"))assert(message["Set"]["ready"]["isReady"]==false);
    }
    s.tick(116);assert(!s.logged()&&s.retryable());
    s.configure("127.0.0.1",8999,"other","new-room","",true);s.connected(false,117);
    assert(sent.back()["Hello"]["password"]==hash&&sent.back()["Hello"]["room"]["name"]=="new-room");
    bool rejected=false;try{s.configure("other.invalid",8999,"me","room","",true);}catch(...){rejected=true;}assert(rejected);
    s.forget_password();rejected=false;try{s.configure("127.0.0.1",8999,"me","room","",true);}catch(...){rejected=true;}assert(rejected);
    s.configure("127.0.0.1",8999,"me","room","");s.connected(false,120);
    s.receive(R"({"Error":"Authentication failed"})",120);assert(!s.retryable()&&!s.logged());
    assert(s.status().dump().find("test-only-password")==std::string::npos&&s.status().dump().find(hash.get<std::string>())==std::string::npos);
    std::cout<<"reconnect policy and session tests passed\n";
}
