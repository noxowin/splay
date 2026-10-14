#include "../../src/core/session.hpp"
#include <cassert>
#include <iostream>
using namespace splay;
int main(){
 Session s;std::vector<Json> sent;std::vector<Correction> corrections;
 s.send=[&](const Json& j){sent.push_back(j);};s.apply=[&](const Correction& c){corrections.push_back(c);};
 Playback p;p.loaded=true;p.position=15;s.playback(p);
 s.configure("localhost",8999,"me","room","");s.connected(false,100);
 assert(sent.back()["Hello"]["version"]=="1.2.255");
 s.receive(R"({"State":{"ignoringOnTheFly":{"server":1},"playstate":{"position":5,"paused":true}}})",100);
 assert(sent.size()==1);
 s.receive(R"({"Hello":{"username":"me","room":{"name":"room"},"version":"1.7.6"}})",100);
 bool ack=false;for(auto& m:sent)if(m.contains("State")&&m["State"].contains("ignoringOnTheFly"))ack=m["State"]["ignoringOnTheFly"]["server"]==1;
 assert(ack&&s.logged()&&corrections.size()==1&&*corrections.back().position==5);
 sent.clear();s.local_change(true,101);assert(sent.back()["State"]["ignoringOnTheFly"]["client"]==1);
 p.paused=false;p.position=17;s.playback(p);s.local_change(false,101);
 assert(sent.back()["State"]["playstate"]["paused"]==false&&sent.back()["State"]["playstate"]["position"]==17);
 assert(sent.back()["State"]["ignoringOnTheFly"]["client"]==2);
 s.receive(R"({"State":{"ignoringOnTheFly":{"client":2}}})",101);
 s.local_change(true,101);
 auto before=corrections.size();s.receive(R"({"State":{"playstate":{"position":200,"paused":false}}})",102);assert(corrections.size()==before);assert(!sent.back()["State"].contains("playstate"));
 s.receive(R"({"State":{"ignoringOnTheFly":{"client":2},"playstate":{"position":200,"paused":false}}})",102);
 assert(corrections.size()==before&&!sent.back()["State"].contains("playstate"));
 s.receive(R"({"State":{"ignoringOnTheFly":{"client":1},"playstate":{"position":20,"paused":false}}})",103);assert(corrections.size()==before+1);
 s.local_change(true,103);before=corrections.size();
 s.receive(R"({"State":{"ignoringOnTheFly":{"server":9,"client":123},"playstate":{"position":22,"paused":true}}})",103);
 assert(corrections.size()==before+1&&*corrections.back().position==22);
 assert(sent.back()["State"]["ignoringOnTheFly"]["server"]==9&&!sent.back()["State"]["ignoringOnTheFly"].contains("client"));
 s.receive(R"({"List":{"room":{"me":{"file":{"name":"https://secret/token"},"isReady":null,"controller":false},"  ":{"file":{}}}}})",104);
 auto status=s.status();assert(status["members"].size()==1);assert(status["members"][0]["ready"].is_null());assert(status.dump().find("secret")==std::string::npos);
 s.command({{"action","room"},{"room","+controlled:123456789012"}});sent.clear();s.local_change(false,105);assert(sent.empty());
 s.receive(R"({"Set":{"controllerAuth":{"user":"me","room":"+controlled:123456789012","success":true}}})",105);s.local_change(false,105);assert(!sent.empty());
 int notifications=0;s.changed=[&](){++notifications;};
 p.speed=1.5;s.playback(p);assert(notifications==1);assert(s.status()["warning"].get<std::string>().find("speed")!=std::string::npos);
 before=corrections.size();sent.clear();
 s.receive(R"({"State":{"ignoringOnTheFly":{"server":7},"ping":{"latencyCalculation":105},"playstate":{"position":300,"paused":true}}})",105);
 assert(corrections.size()==before&&!sent.back()["State"].contains("playstate"));
 assert(sent.back()["State"]["ignoringOnTheFly"]["server"]==7&&sent.back()["State"]["ping"]["latencyCalculation"]==105);
 p.speed=1;p.buffering=true;s.playback(p);assert(s.status()["warning"].get<std::string>().find("Buffering")!=std::string::npos);
 p.buffering=false;p.seekable=false;s.playback(p);assert(s.status()["warning"].get<std::string>().find("seekable")!=std::string::npos);
 p.seekable=true;s.playback(p);assert(s.status()["warning"]=="");
 s.receive(R"({"Set":{"user":{"me":{"isReady":true,"controller":false}}}})",105);
 assert(s.status()["ready"]==true&&s.status()["is_controller"]==false);
 s.receive(R"({"Set":{"controllerAuth":{"user":"me","room":"+controlled:123456789012","success":false}}})",105);
 assert(s.status()["error"]!="");
 s.receive(R"({"Set":{"controllerAuth":{"user":"me","room":"+controlled:123456789012","success":true}}})",105);
 assert(s.status()["error"]=="");
 s.command({{"action","create-room"},{"room","base"},{"password","AB-123-456"}});assert(sent.back()["Set"]["controllerAuth"]["password"]=="AB-123-456");
 s.receive(R"({"Set":{"newControlledRoom":{"roomName":"+base:ABCDEFGHIJKL","password":"AB-123-456"}}})",106);assert(s.status()["room"]=="+base:ABCDEFGHIJKL");assert(s.status().dump().find("AB-123-456")==std::string::npos);
 p.loaded=false;s.playback(p);sent.clear();s.media_changed();
 assert(sent.size()==2&&sent[0]["Set"]["file"].is_object()&&sent[0]["Set"]["file"].empty());
 s.tick(120);assert(!s.logged());s.configure("localhost",8999,"me","room","");s.tick(200);assert(s.status()["connection"]=="connecting");
 s.connected(false,200);s.tick(213);assert(s.status()["connection"]=="error");
 s.receive("[]",214);assert(!s.logged());s.receive(std::string(17000,'x'),214);assert(!s.logged());
 assert(password_md5("password")=="5f4dcc3b5aa765d61d8327deb882cf99");
 std::cout<<"session tests passed\n";
}
