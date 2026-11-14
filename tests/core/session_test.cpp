#include "../../src/core/session.hpp"
#include "../../src/core/md5.hpp"
#include <cassert>
#include <iostream>
#include <limits>
using namespace splay;

static void offset_and_public_name_tests(){
 Session s;s.command({{"action","room-policy"},{"pause_on_join",false},{"pause_on_leave",false}});Playback media;media.loaded=true;media.duration=100;media.position=40;
 std::vector<Json> sent;std::vector<Correction> applied;bool applied_paused=media.paused;
 s.send=[&](const Json& value){sent.push_back(value);};
 s.apply=[&](const Correction& value){applied.push_back(value);if(value.paused)applied_paused=*value.paused;};
 s.playback(media);s.configure("localhost",8999,"me","room","");s.connected(false,100);
 s.receive(R"({"Hello":{"username":"me","room":{"name":"room"},"version":"1.7.6"}})",100);
 auto state=[&](double position,bool paused=true){
  s.receive(Json{{"State",{{"playstate",{{"position",position},{"paused",paused}}}}}}.dump(),101);
 };
 state(40);sent.clear();applied.clear();
 s.command({{"action","set-offset"},{"seconds",10}},101);
 assert(s.status()["time_offset"]==10&&applied.back().position==50&&sent.empty());
 state(45);assert(applied.back().position==55&&sent.back()["State"]["playstate"]["position"]==45);
 s.command({{"action","set-offset"},{"seconds",-10}},101);
 assert(applied.back().position==35);
 state(50);assert(applied.back().position==40&&sent.back()["State"]["playstate"]["position"]==50);
 // Adapter feedback for the correction must remain a heartbeat, never a seek.
 for(const auto& packet:sent)if(packet.contains("State")){
  assert(!packet["State"].contains("ignoringOnTheFly"));
  if(packet["State"].contains("playstate"))assert(!packet["State"]["playstate"].contains("doSeek"));
 }
 for(double offset:{-86400.0,86400.0}){
  sent.clear();s.command({{"action","set-offset"},{"seconds",offset}},101);
  assert(s.status()["time_offset"]==offset&&sent.empty());
  state(50);assert(sent.back()["State"]["playstate"]["position"]==50&&sent.back()["State"]["playstate"]["paused"]==true);
  assert(s.status()["time_offset_boundary"]==true);
  if(offset<0)assert(applied.back().position==0);
  else assert(applied.back().position&&*applied.back().position>=99&&*applied.back().position<100);
  assert(applied_paused); // An already-paused player needs no redundant pause correction.
  state(50,false);
  assert(sent.back()["State"]["playstate"]["position"]==50&&sent.back()["State"]["playstate"]["paused"]==false&&applied_paused);
  assert(!sent.back()["State"]["playstate"].contains("doSeek")&&!sent.back()["State"].contains("ignoringOnTheFly"));
 }
 // A heartbeat without a new room sample must advance the virtual room clock,
 // even while the real local player stays paused just before EOF.
 s.receive(R"({"State":{"ping":{}}})",103);
 assert(sent.back()["State"]["playstate"]["position"]==52&&sent.back()["State"]["playstate"]["paused"]==false&&applied_paused);
 s.command({{"action","set-offset"},{"seconds",0}},103);
 assert(s.status()["time_offset_boundary"]==false&&applied.back().position==52&&applied.back().paused==false);
 const auto previous=s.status()["time_offset"];const auto count=applied.size();
 for(const auto& invalid:std::vector<Json>{nullptr,true,"1",86400.1,-86400.1,
     std::numeric_limits<double>::infinity(),std::numeric_limits<double>::quiet_NaN()}){
  bool rejected=false;try{s.command({{"action","set-offset"},{"seconds",invalid}},101);}catch(const std::exception&){rejected=true;}
  assert(rejected&&s.status()["time_offset"]==previous&&applied.size()==count);
 }
 // Connection and room transitions retain a media offset; replacing media resets it.
 s.disconnected();s.command({{"action","set-offset"},{"seconds",-10}},101);
 s.configure("localhost",8999,"me","other","");assert(s.status()["time_offset"]==-10);
 s.media_changed();assert(s.status()["time_offset"]==0);
 // Offline clamping must retain the room reference so undoing an offset restores position.
 Session offline;offline.command({{"action","room-policy"},{"pause_on_join",false},{"pause_on_leave",false}});offline.playback(media);std::vector<Correction> offline_applied;
 offline.apply=[&](const Correction& c){offline_applied.push_back(c);};
 offline.command({{"action","set-offset"},{"seconds",-100}},100);
 assert(offline_applied.back().position==0);
 offline.command({{"action","set-offset"},{"seconds",0}},100);
 assert(offline_applied.back().position==40);

 Session names;names.command({{"action","room-policy"},{"pause_on_join",false},{"pause_on_leave",false}});std::vector<Json> metadata;
 names.send=[&](const Json& packet){metadata.push_back(packet);};
 media.public_name=u8"公開映画 🎬.mkv";names.playback(media);
 names.configure("localhost",8999,"me","room","");names.connected(false,100);
 names.receive(R"({"Hello":{"username":"me","room":{"name":"room"},"version":"1.7.6"}})",100);
 auto latest_file=[&](){for(auto i=metadata.rbegin();i!=metadata.rend();++i)if(i->contains("Set")&&(*i)["Set"].contains("file"))return (*i)["Set"]["file"];return Json();};
 assert(latest_file()["name"]==media.public_name&&latest_file()["size"]==0);
 metadata.clear();media.public_name="Late metadata title";names.playback(media);
 assert(metadata.size()==1&&latest_file()["name"]==media.public_name);
 for(const auto& secret:std::vector<std::string>{"https://user:secret@host.invalid/movie?token=secret","C:\\private\\movie.mkv",
     "token=secret","bad\nname","https%253A%252F%252Fhost.invalid%252Fsecret","www.private.invalid"}){
  media.public_name=secret;names.playback(media);names.media_changed();
  assert(latest_file()["name"]=="**Hidden filename**"&&latest_file().dump().find("secret")==std::string::npos);
 }
 media.loaded=false;names.playback(media);names.media_changed();assert(latest_file().empty());
}
int main(){
 offset_and_public_name_tests();
 Session s;s.command({{"action","room-policy"},{"pause_on_join",false},{"pause_on_leave",false}});std::vector<Json> sent;std::vector<Correction> corrections;
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
 p.speed=1;p.buffering=true;s.playback(p);assert(s.status()["warning"]=="");
 before=corrections.size();sent.clear();
 s.receive(R"({"State":{"playstate":{"position":400,"paused":false}}})",105);
 assert(corrections.size()==before&&!sent.back()["State"].contains("playstate"));
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
 s.receive("[]",214);assert(!s.logged());s.receive(std::string(131073,'x'),214);assert(!s.logged());
 assert(password_md5("password")=="5f4dcc3b5aa765d61d8327deb882cf99");
 // RFC 1321 A.5 test suite, then the padding boundaries: 55 bytes fit one
 // block, 56-64 need a second, and 119/120 repeat that after a full block.
 assert(password_md5("").empty());
 assert(md5_hex("")=="d41d8cd98f00b204e9800998ecf8427e");
 assert(md5_hex("a")=="0cc175b9c0f1b6a831c399e269772661");
 assert(md5_hex("abc")=="900150983cd24fb0d6963f7d28e17f72");
 assert(md5_hex("message digest")=="f96b697d7cb7938d525a2f31aaf161d0");
 assert(md5_hex("abcdefghijklmnopqrstuvwxyz")=="c3fcd3d76192e4007dfb496cca67e13b");
 assert(md5_hex("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")=="d174ab98d277d9f5a5611c2c9f419d9f");
 assert(md5_hex("12345678901234567890123456789012345678901234567890123456789012345678901234567890")=="57edf4a22be3c955ac49da2e2107b67a");
 assert(md5_hex(std::string(55,'a'))=="ef1772b6dff9a122358552954ad0df65");
 assert(md5_hex(std::string(56,'a'))=="3b0c8ac703f828b04c6c197006d17218");
 assert(md5_hex(std::string(63,'a'))=="b06521f39153d618550606be297466d5");
 assert(md5_hex(std::string(64,'a'))=="014842d480b571495a4a0363793f7367");
 assert(md5_hex(std::string(119,'a'))=="8a7bd0732ed6a28ce75f6dabc90e1613");
 assert(md5_hex(std::string(120,'a'))=="5f61c0ccad4cac44c75ff505e1f1e537");
 assert(md5_hex(std::string(1024,'\xff'))=="9a8918b11878da506f761bc1c9c4ce17");
 // Chat is the upstream wire protocol: outgoing string, incoming username/message.
 Session chat;chat.command({{"action","room-policy"},{"pause_on_join",false},{"pause_on_leave",false}});std::vector<Json> messages,events;
 chat.send=[&](const Json& j){messages.push_back(j);};
 chat.event=[&](const Json& j){if(j["type"]=="chat"||j["type"]=="playback")events.push_back(j);};
 chat.configure("localhost",8999,"me","room","");chat.connected(false,300);
 assert(messages.back()["Hello"]["features"]["chat"]==true);
 assert(messages.back()["Hello"]["features"]["maxChatMessageLength"]==150);
 chat.receive(R"({"Hello":{"username":"me","room":{"name":"room"},"features":{"chat":true,"maxChatMessageLength":4}}})",300);
 assert(chat.status()["chat_supported"]==true&&chat.status()["chat_max_length"]==4);
 chat.command({{"action","chat"},{"text",u8"中文😀éextra"}});
 assert(messages.back()["Chat"]==u8"中文😀é");
 chat.command({{"action","chat"},{"text",std::string("a\n\0b",4)}});
 assert(messages.back()["Chat"]==std::string("a\n\0b",4));
 chat.receive(R"({"Chat":{"username":"peer","message":"{\\\\"}})",301);
 assert(events.size()==1&&events.back()["type"]=="chat"&&events.back()["username"]=="peer");
 auto id=events.back()["id"].get<uint64_t>();
 // Baseline and progressing heartbeat never become playback notifications.
 chat.receive(R"({"State":{"playstate":{"position":10,"paused":false,"setBy":"peer"}}})",301);
 chat.receive(R"({"State":{"playstate":{"position":11,"paused":false,"setBy":"peer"}}})",302);
 assert(events.size()==1);
 chat.receive(R"({"State":{"playstate":{"position":11.5,"paused":true,"setBy":"peer"}}})",302.5);
 assert(events.size()==2&&events.back()["type"]=="playback"&&events.back()["username"]=="peer"&&events.back()["paused"]==true&&!events.back()["seek"].get<bool>());
 chat.receive(R"({"State":{"playstate":{"position":11.5,"paused":true,"setBy":"peer"}}})",303);
 assert(events.size()==2);
 chat.receive(R"({"State":{"playstate":{"position":30,"paused":true,"doSeek":true,"setBy":"me"}}})",304);
 assert(events.size()==3&&events.back()["username"]=="me"&&events.back()["seek"]==true&&events.back()["id"].get<uint64_t>()>id);
 chat.receive(R"({"State":{"playstate":{"position":30,"paused":true,"doSeek":true,"setBy":"me"}}})",305);
 assert(events.size()==3);
 chat.command({{"action","room"},{"room","another"}});
 chat.receive(R"({"State":{"playstate":{"position":0,"paused":false,"doSeek":true,"setBy":"other"}}})",306);
 assert(events.size()==3);
 chat.disconnected();assert(chat.status()["chat_supported"]==false);
 bool rejected=false;try{chat.command({{"action","chat"},{"text","offline"}});}catch(const std::runtime_error&){rejected=true;}
 assert(rejected);
 chat.configure("localhost",8999,"me","room","");chat.connected(false,310);
 chat.receive(R"({"Hello":{"username":"me","room":{"name":"room"},"features":{"chat":false,"maxChatMessageLength":150}}})",310);
 rejected=false;try{chat.command({{"action","chat"},{"text","disabled"}});}catch(const std::runtime_error&){rejected=true;}
 assert(rejected&&chat.logged());
 chat.receive(R"({"State":{"playstate":{"position":90,"paused":true,"doSeek":true,"setBy":"peer"}}})",311);
 assert(events.size()==3);
 chat.disconnected();chat.configure("localhost",8999,"me","room","");chat.connected(false,320);
 chat.receive(R"({"Hello":{"username":"me","room":{"name":"room"}}})",320);
 assert(chat.status()["chat_supported"]==false);
 Session managed;managed.command({{"action","room-policy"},{"pause_on_join",false},{"pause_on_leave",false}});std::vector<Json> managed_events;
 managed.event=[&](const Json& e){if(e["type"]=="playback")managed_events.push_back(e);};
 managed.configure("localhost",8999,"me","+ctl:ABCDEFGHIJKL","");managed.connected(false,400);
 managed.receive(R"({"Hello":{"username":"me","room":{"name":"+ctl:ABCDEFGHIJKL"}}})",400);
 managed.receive(R"({"List":{"+ctl:ABCDEFGHIJKL":{"operator":{"controller":true},"ordinary":{"controller":false}}}})",400);
 managed.receive(R"({"State":{"playstate":{"position":20,"paused":true,"setBy":"operator"}}})",401);
 managed.receive(R"({"State":{"playstate":{"position":20,"paused":false,"setBy":"ordinary"}}})",402);
 managed.receive(R"({"State":{"playstate":{"position":20,"paused":true,"doSeek":true,"setBy":"operator"}}})",402);
 assert(managed_events.empty());
 managed.receive(R"({"State":{"playstate":{"position":20,"paused":false,"setBy":"operator"}}})",403);
 assert(managed_events.size()==1&&managed_events.back()["username"]=="operator");
 // Explicit user unpause sets readiness once, independently of room control.
 Session automatic;automatic.command({{"action","room-policy"},{"pause_on_join",false},{"pause_on_leave",false}});std::vector<Json> auto_messages;
 automatic.send=[&](const Json& j){auto_messages.push_back(j);};
 automatic.configure("localhost",8999,"me","+ctl:ABCDEFGHIJKL","");automatic.connected(false,500);
 automatic.receive(R"({"Hello":{"username":"me","room":{"name":"+ctl:ABCDEFGHIJKL"},"version":"1.7.6","features":{"readiness":true}}})",500);
 auto readiness_count=[&](){size_t count=0;for(const auto& j:auto_messages)if(j.contains("Set")&&j["Set"].contains("ready"))++count;return count;};
 Playback auto_play;auto_play.loaded=true;auto_play.paused=true;automatic.playback(auto_play);auto_messages.clear();
 automatic.local_change(false,501);assert(auto_messages.empty()); // Pause never makes a user unready.
 auto_play.paused=false;automatic.playback(auto_play);automatic.local_change(true,502);assert(auto_messages.empty());
 auto_play.buffering=true;automatic.playback(auto_play);automatic.local_change(false,502);assert(auto_messages.empty());
 auto_play.buffering=false;auto_play.loaded=false;automatic.playback(auto_play);automatic.local_change(false,502);assert(auto_messages.empty());
 auto_play.loaded=true;auto_play.paused=true;automatic.playback(auto_play);
 automatic.receive(R"({"State":{"playstate":{"position":2,"paused":false,"setBy":"operator"}}})",503);
 assert(readiness_count()==0&&automatic.status()["ready"]==false); // A remote unpause only replies with State.
 auto_messages.clear();automatic.local_change(false,504);automatic.local_change(false,504);
 assert(readiness_count()==1&&auto_messages.size()==1&&auto_messages[0]["Set"]["ready"]["manuallyInitiated"]==true);
 assert(automatic.status()["ready"]==false); // Wait for the authoritative ready echo.
 automatic.receive(R"({"Set":{"ready":{"username":"me","isReady":true,"manuallyInitiated":true}}})",504);
 assert(automatic.status()["ready"]==true);auto_messages.clear();
 automatic.local_change(false,505);assert(auto_messages.empty());
 auto_play.paused=true;automatic.playback(auto_play);automatic.local_change(false,505);
 assert(auto_messages.empty()&&automatic.status()["ready"]==true);
 automatic.disconnected();auto_play.paused=false;automatic.playback(auto_play);automatic.local_change(false,506);assert(auto_messages.empty());
 automatic.configure("localhost",8999,"me","room","");automatic.connected(false,507);
 automatic.receive(R"({"Hello":{"username":"me","room":{"name":"room"},"version":"1.7.6","features":{"readiness":false}}})",507);
 auto_messages.clear();automatic.local_change(false,507);assert(readiness_count()==0);

 // Lists establish a silent membership baseline; authoritative changes emit
 // one structured, localizable notice and preserve safe public filenames.
 Session notices;notices.command({{"action","room-policy"},{"pause_on_join",false},{"pause_on_leave",false}});std::vector<Json> notices_events;
 notices.event=[&](const Json& j){notices_events.push_back(j);};
 notices.configure("localhost",8999,"me","room","");notices.connected(false,600);
 notices.receive(R"({"Hello":{"username":"me","room":{"name":"room"},"version":"1.7.6"}})",600);
 assert(notices_events.size()==2&&notices_events[0]["connection"]=="connecting"&&notices_events[1]["connection"]=="connected");
 notices_events.clear();
 notices.receive(R"({"List":{"room":{"peer":{"file":{"name":"C:\\Users\\private\\Film.mkv","duration":123,"size":12345678901},"isReady":false},"me":{"file":{},"isReady":false}}}})",600);
 assert(notices_events.empty());
 auto peer_file=notices.status()["members"][1]["file"];
 assert(peer_file["name"]=="Film.mkv"&&peer_file["duration"]==123&&peer_file["size"]==12345678901LL);
 notices.receive(R"({"Set":{"user":{"peer":{"room":{"name":"room"},"event":{"joined":true}}}}})",601);
 assert(notices_events.empty()); // A join already present in List is not repeated.
 notices.receive(R"({"Set":{"user":{"new":{"room":{"name":"room"},"event":{"joined":true}}}}})",601);
 notices.receive(R"({"Set":{"user":{"new":{"room":{"name":"room"},"event":{"joined":true}}}}})",601);
 assert(notices_events.size()==1&&notices_events.back()["action"]=="joined");
 notices.receive(R"({"Set":{"user":{"peer":{"file":{"name":"https://user:secret@example.invalid/private/公開.mkv?token=secret#fragment","duration":124,"size":12}}}}})",602);
 assert(notices_events.size()==2&&notices_events.back()["action"]=="file"&&notices_events.back()["file"]["name"]=="**Hidden filename**");
 assert(notices.status().dump().find("secret")==std::string::npos);
 notices.receive(R"({"Set":{"ready":{"username":"peer","isReady":true,"manuallyInitiated":true}}})",602);
 notices.receive(R"({"Set":{"ready":{"username":"peer","isReady":true,"manuallyInitiated":true}}})",602);
 assert(notices_events.size()==3&&notices_events.back()["type"]=="ready"&&notices_events.back()["ready"]==true);
 notices.receive(R"({"Set":{"user":{"peer":{"room":{"name":"elsewhere"}}}}})",603);
 assert(notices_events.size()==4&&notices_events.back()["action"]=="room"&&notices_events.back()["previous_room"]=="room");
 notices.receive(R"({"Set":{"user":{"peer":{"event":{"left":true}}}}})",603);
 notices.receive(R"({"Set":{"user":{"peer":{"event":{"left":true}}}}})",603);
 assert(notices_events.size()==5&&notices_events.back()["action"]=="left");

 // Shared playlists use upstream Set payloads, are server-authoritative,
 // survive early handshake updates, and cannot load player media in core.
 Session lists;lists.command({{"action","room-policy"},{"pause_on_join",false},{"pause_on_leave",false}});std::vector<Json> list_messages,list_events;size_t playlist_corrections=0;
 lists.send=[&](const Json& j){list_messages.push_back(j);};
 lists.event=[&](const Json& j){if(j["type"]=="playlist")list_events.push_back(j);};
 lists.apply=[&](const Correction&){++playlist_corrections;};
 lists.configure("localhost",8999,"me","room","");lists.connected(false,700);
 assert(list_messages.back()["Hello"]["features"]["sharedPlaylists"]==true&&list_messages.back()["Hello"]["features"]["featureList"]==true);
 lists.receive(R"({"Set":{"playlistChange":{"files":["one.mkv","two.mkv"],"user":null}}})",700);
 lists.receive(R"({"Set":{"playlistIndex":{"index":1,"user":null}}})",700);
 assert(lists.status()["playlist"]["files"].empty());
 lists.receive(R"({"Hello":{"username":"me","room":{"name":"room"},"version":"1.2.255","realversion":"1.7.6","features":{"chat":true}}})",700);
 assert(lists.status()["playlist_supported"]==true&&lists.status()["playlist"]["index"]==1&&lists.status()["playlist"]["user"]=="");
 assert(list_events.size()==2&&playlist_corrections==0);
 lists.command({{"action","playlist-set"},{"files",Json::array({u8"第一集.mkv","second.mkv"})}});
 assert(list_messages.back()["Set"]["playlistChange"]["files"][0]==u8"第一集.mkv"&&lists.status()["playlist"]["files"][0]=="one.mkv");
 lists.receive(R"({"Set":{"playlistChange":{"files":["第一集.mkv","second.mkv"],"user":"peer"}}})",701);
 assert(lists.status()["playlist"]["files"][0]==u8"第一集.mkv"&&lists.status()["playlist"]["user"]=="peer");
 lists.command({{"action","playlist-index"},{"index",0}});
 assert(list_messages.back()["Set"]["playlistIndex"]["index"]==0&&lists.status()["playlist"]["index"]==1);
 lists.receive(R"({"Set":{"playlistIndex":{"index":0,"user":"me"}}})",702);
 auto valid_playlist=lists.status()["playlist"];auto event_count=list_events.size();
 lists.receive(R"({"Set":{"playlistIndex":{"index":0,"user":"me"}}})",702);assert(list_events.size()==event_count);
 for(const auto& malformed:std::vector<Json>{nullptr,true,-1,2,0.5,"0",Json::object()}){
     const auto update=Json{{"Set",{{"playlistIndex",{{"index",malformed},{"user","peer"}}}}}};
     lists.receive(update.dump(),703);
     if(malformed.is_null()){valid_playlist["index"]=nullptr;valid_playlist["user"]="peer";continue;}
     assert(lists.logged()&&lists.status()["playlist"]==valid_playlist&&!lists.status()["error"].get<std::string>().empty());
 }
 for(const auto& malformed:std::vector<Json>{nullptr,"files",Json::array({2}),Json::array({""}),Json::array({"bad\nfile"}),Json::array({std::string(10001,'x')})}){
     lists.receive(Json{{"Set",{{"playlistChange",{{"files",malformed},{"user","peer"}}}}}}.dump(),704);
     assert(lists.logged()&&lists.status()["playlist"]==valid_playlist);
 }
 for(const auto& invalid:std::vector<Json>{Json{{"action","playlist-index"},{"index",-1}},Json{{"action","playlist-index"},{"index",2}},Json{{"action","playlist-index"},{"index",nullptr}},Json{{"action","playlist-set"},{"files",Json::array({12})}}}){
     rejected=false;try{lists.command(invalid);}catch(const std::exception&){rejected=true;}assert(rejected&&lists.logged());
 }
 Json maximum=Json::array();for(int i=0;i<250;++i){std::string name;for(int n=0;n<40;++n)name+=u8"😀";maximum.push_back(name);}
 auto maximum_update=Json{{"Set",{{"playlistChange",{{"files",maximum},{"user","peer"}}}}}}.dump(-1,' ',true);
 assert(maximum_update.size()>120000&&maximum_update.size()<131072);
 lists.receive(maximum_update,705);assert(lists.logged()&&lists.status()["playlist"]["files"]==maximum);
 rejected=false;try{lists.command({{"action","playlist-set"},{"files",maximum}});}catch(const std::exception&){rejected=true;}assert(rejected&&lists.logged());
 Json ascii_maximum=Json::array();for(int i=0;i<250;++i)ascii_maximum.push_back(std::string(40,'x'));
 lists.command({{"action","playlist-set"},{"files",ascii_maximum}});assert(list_messages.back()["Set"]["playlistChange"]["files"]==ascii_maximum);
 // Account for actual escaped server usernames rather than assuming the
 // official server's normal short-name truncation or a fixed byte reserve.
 const auto near_wire_limit=Json::array({std::string(6000,'"')+std::string(4000,'x')});
 lists.command({{"action","playlist-set"},{"files",near_wire_limit}});
 assert(list_messages.back()["Set"]["playlistChange"]["files"]==near_wire_limit);
 Session long_username;long_username.command({{"action","room-policy"},{"pause_on_join",false},{"pause_on_leave",false}});long_username.configure("localhost",8999,"me","room","");long_username.connected(false,705);
 std::string assigned_name;for(int i=0;i<128;++i)assigned_name+=u8"ü";
 long_username.receive(Json{{"Hello",{{"username",assigned_name},{"room",{{"name","room"}}},{"version","1.7.6"}}}}.dump(),705);
 rejected=false;try{long_username.command({{"action","playlist-set"},{"files",near_wire_limit}});}catch(const std::exception&){rejected=true;}
 assert(rejected&&long_username.logged());
 maximum.push_back("overflow");rejected=false;try{lists.command({{"action","playlist-set"},{"files",maximum}});}catch(const std::exception&){rejected=true;}assert(rejected);
 lists.receive(R"({"Set":{"playlistChange":{"files":[],"user":"peer"}}})",706);
 assert(lists.status()["playlist"]["files"].empty()&&lists.status()["playlist"]["index"].is_null()&&playlist_corrections==0);
 lists.command({{"action","room"},{"room","+ctl:ABCDEFGHIJKL"}});
 assert(lists.status()["playlist"]["user"]==""&&lists.status()["playlist"]["files"].empty());
 rejected=false;try{lists.command({{"action","playlist-set"},{"files",Json::array({"forbidden"})}});}catch(const std::exception&){rejected=true;}assert(rejected);
 lists.receive(R"({"Set":{"controllerAuth":{"user":"me","room":"+ctl:ABCDEFGHIJKL","success":true}}})",707);
 lists.command({{"action","playlist-set"},{"files",Json::array({"allowed"})}});assert(list_messages.back()["Set"]["playlistChange"]["files"][0]=="allowed");
 lists.disconnected();assert(lists.status()["playlist_supported"]==false&&lists.status()["playlist"]["files"].empty());
 rejected=false;try{lists.command({{"action","playlist-set"},{"files",Json::array()}});}catch(const std::exception&){rejected=true;}assert(rejected);
 lists.configure("localhost",8999,"me","room","");lists.connected(false,708);
 lists.receive(R"({"Hello":{"username":"me","room":{"name":"room"},"version":"1.7.6","features":{"sharedPlaylists":false}}})",708);
 assert(lists.status()["playlist_supported"]==false);
 rejected=false;try{lists.command({{"action","playlist-set"},{"files",Json::array()}});}catch(const std::exception&){rejected=true;}assert(rejected&&lists.logged());
 lists.receive(R"({"Set":{"playlistChange":{"files":["disabled"],"user":"peer"}}})",708);assert(lists.logged()&&lists.status()["playlist"]["files"].empty());
 std::cout<<"session tests passed\n";
}
