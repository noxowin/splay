#include "session.hpp"
#include <cmath>
#include <regex>
#include <stdexcept>
#ifdef _WIN32
#include <windows.h>
#include <bcrypt.h>
#endif
namespace splay {
    namespace {
        std::string str(const Json& j,const char* key,size_t max=256) {
            auto i=j.find(key);
            if(i==j.end()||!i->is_string())throw std::runtime_error("Invalid text field");
            auto s=i->get<std::string>();
            if(s.empty()||s.size()>max||s.find('\0')!=s.npos)throw std::runtime_error("Invalid text length");
            return s;
        }
        bool flag(const Json& j,const char* k,bool d=false){
            auto i=j.find(k);
            return i!=j.end()&&i->is_boolean()?i->get<bool>():d;
        }
        double number(const Json& j,const char* k,double d=0){
            auto i=j.find(k);
            if(i==j.end()||!i->is_number())return d;
            double v=i->get<double>();
            return std::isfinite(v)&&std::abs(v)<1e10?v:d;
        }
        unsigned seq(const Json& j,const char* k){
            double v=number(j,k);
            return v>0&&v<=2147483647?static_cast<unsigned>(v):0;
        }
        Json safe_file(const Json& j){
            if(!j.is_object()||j.empty())return Json::object();
            return {
                {"name","**Hidden filename**"}
                ,{"duration",number(j,"duration")}
                ,{"size",0}
            };
        }
        std::string chat_text(const Json& j,const char* key,size_t limit){
            auto i=j.find(key);
            if(i==j.end()||!i->is_string())throw std::runtime_error("Invalid chat text");
            const auto value=i->get<std::string>();
            // JSON parsing validates UTF-8 on the wire; also validate direct API calls.
            Json(value).dump();
            size_t characters=0,end=0;
            for(size_t pos=0;pos<value.size();++pos){
                if((static_cast<unsigned char>(value[pos])&0xc0)!=0x80){
                    if(characters==limit)break;
                    ++characters;
                }
                end=pos+1;
            }
            return value.substr(0,end);
        }
    }
    std::string password_md5(const std::string& input){
        if(input.empty())return {};
#ifdef _WIN32
        BCRYPT_ALG_HANDLE alg=nullptr;
        BCRYPT_HASH_HANDLE hash=nullptr;
        DWORD bytes=0,size=0;
        if(BCryptOpenAlgorithmProvider(&alg,BCRYPT_MD5_ALGORITHM,nullptr,0)<0)throw std::runtime_error("Password hashing unavailable");
        BCryptGetProperty(alg,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&size),sizeof(size),&bytes,0);
        std::vector<unsigned char> object(size);
        unsigned char digest[16];
        NTSTATUS result=BCryptCreateHash(alg,&hash,object.data(),size,nullptr,0,0);
        if(result>=0)result=BCryptHashData(hash,reinterpret_cast<PUCHAR>(const_cast<char*>(input.data())),static_cast<ULONG>(input.size()),0);
        if(result>=0)result=BCryptFinishHash(hash,digest,16,0);
        if(hash)BCryptDestroyHash(hash);
        BCryptCloseAlgorithmProvider(alg,0);
        if(result<0)throw std::runtime_error("Password hashing failed");
        std::string out;
        for(auto c:digest){
            out+="0123456789abcdef"[c>>4];
            out+="0123456789abcdef"[c&15];
        }
        return out;
#else
        throw std::runtime_error("Password hashing requires Windows");
#endif
    }
    void Session::emit(const Json& j){
        if(send)send(j);
    }
    void Session::notify(){
        if(changed)changed();
    }
    void Session::publish_event(Json value){
        value["schema"]=1;
        value["id"]=++eventId_;
        if(event)event(value);
    }
    void Session::reset_sync(){
        clientIgnore_=serverIgnore_=0;
        first_=true;
        rtt_=0;
        pending_state_=nullptr;
        eventBaseline_=false;
    }
    bool Session::controlled() const {
        static const std::regex re("^\\+.*:[A-Za-z0-9_]{12}$");
        return std::regex_match(room_,re);
    }
    void Session::configure(std::string h,int p,std::string u,std::string r,std::string pw){
        if(h.empty()||h.size()>253||u.empty()||u.size()>128||r.empty()||r.size()>256||pw.size()>1024||p<1||p>65535) throw std::runtime_error("Invalid connection settings");
        host_=h;
        port_=p;
        user_=u;
        room_=r;
        password_=password_md5(pw);
        connection_="connecting";
        lastReceive_=0;
        error_.clear();
        logged_=false;
        chatSupported_=false;
        chatMaxLength_=150;
        members_.clear();
        controller_=ready_=false;
        reset_sync();
        notify();
    }
    void Session::connected(bool secure,double now){
        encrypted_=secure;
        lastReceive_=now;
        now_=now;
        Json hello={
            {"username",user_}
            ,{
                "room",{
                    {"name",room_}
                }
            }
            ,{"version","1.2.255"}
            ,{"realversion","1.7.6"}
            ,{
                "features",{
                    {"sharedPlaylists",false}
                    ,{"chat",true}
                    ,{"maxChatMessageLength",150}
                    ,{"readiness",true}
                    ,{"managedRooms",true}
                    ,{"setOthersReadiness",false}
                    ,{"uiMode","splay"}
                }
            }
        };
        if(!password_.empty())hello["password"]=password_;
        emit({
            {"Hello",hello}
        }
        );
    }
    void Session::disconnected(const std::string& error){
        logged_=false;
        chatSupported_=false;
        chatMaxLength_=150;
        connection_=error.empty()?"disconnected":"error";
        error_=error;
        encrypted_=false;
        members_.clear();
        controller_=ready_=false;
        reset_sync();
        notify();
    }
    Json Session::status() const {
        std::string warning;
        if(logged_){
            if(!local_.loaded)warning="Waiting for media; synchronization is suspended";
            else if(std::abs(local_.speed-1)>.001)warning="Synchronization requires playback speed 1.0; synchronization is suspended";
            else if(local_.buffering)warning="Buffering or seeking; synchronization is suspended";
            else if(!local_.seekable)warning="Media is not seekable; position synchronization is unavailable";
        }
        Json members=Json::array();
        for(auto& m:members_)members.push_back(m.second);
        return {
            {"schema",1}
            ,{"connection",connection_}
            ,{"encrypted",encrypted_}
            ,{"host",host_}
            ,{"port",port_}
            ,{"username",user_}
            ,{"room",room_}
            ,{"ready",ready_}
            ,{"is_controller",controller_}
            ,{"controlled",controlled()}
            ,{"chat_supported",chatSupported_}
            ,{"chat_max_length",chatMaxLength_}
            ,{"error",error_}
            ,{"warning",warning}
            ,{"members",members}
        };
    }
    void Session::member(const std::string& user,const std::string& room,const Json& j){
        if(user.size()>256||room.size()>256||user.find_first_not_of(' ')==std::string::npos)return;
        Json ready=nullptr;
        if(j.contains("isReady")&&j["isReady"].is_boolean())ready=j["isReady"];
        members_[user]={
            {"username",user}
            ,{"room",room}
            ,{"ready",ready}
            ,{"is_controller",flag(j,"controller")}
            ,{"file",safe_file(j.value("file",Json::object()))}
        };
        if(user==user_){
            controller_=flag(j,"controller");
            if(ready.is_boolean())ready_=ready.get<bool>();
        }
    }
    void Session::media_changed(){
        first_=true;
        if(logged_)file();
    }
    void Session::file(){
        emit({
            {
                "Set",{
                    {
                        "file", local_.loaded?Json{
                            {"name","**Hidden filename**"}
                            ,{"duration",local_.duration}
                            ,{"size",0}
                        }
                        :Json::object()}
                }
            }
        }
        );
        emit({
            {"List",nullptr}
        }
        );
    }
    void Session::set(const Json& j){
        if(j.contains("room")&&j["room"].is_object()){
            room_=str(j["room"],"name");
            controller_=false;
            reset_sync();
            emit({
                {"List",nullptr}
            }
            );
        }
        if(j.contains("user")&&j["user"].is_object())for(auto& item:j["user"].items()){
            auto v=item.value();
            if(!v.is_object())continue;
            if(v.contains("event")&&v["event"].is_object()&&v["event"].contains("left")){
                members_.erase(item.key());
                continue;
            }
            std::string r=members_.count(item.key())?members_[item.key()].value("room",room_):room_;
            if(v.contains("room")&&v["room"].is_object())r=str(v["room"],"name");
            Json old=members_.count(item.key())?members_[item.key()]:Json::object();
            if(!v.contains("isReady")&&old.contains("ready"))v["isReady"]=old["ready"];
            if(!v.contains("controller")&&old.contains("is_controller"))v["controller"]=old["is_controller"];
            if(!v.contains("file")&&old.contains("file"))v["file"]=old["file"];
            member(item.key(),r,v);
        }
        if(j.contains("ready")&&j["ready"].is_object()){
            auto& v=j["ready"];
            auto u=str(v,"username");
            if(v.contains("isReady")&&(v["isReady"].is_boolean()||v["isReady"].is_null())){
                if(members_.count(u))members_[u]["ready"]=v["isReady"];
                if(u==user_&&v["isReady"].is_boolean())ready_=v["isReady"].get<bool>();
            }
        }
        if(j.contains("controllerAuth")&&j["controllerAuth"].is_object()){
            auto& v=j["controllerAuth"];
            auto u=str(v,"user");
            auto r=str(v,"room");
            bool success=flag(v,"success");
            if(success&&members_.count(u))members_[u]["is_controller"]=true;
            if(u==user_&&r==room_){
                if(success){controller_=true;error_.clear();}
                else error_="Operator authentication failed";
            }
        }
        if(j.contains("newControlledRoom")&&j["newControlledRoom"].is_object()){
            auto& v=j["newControlledRoom"];
            auto room=str(v,"roomName");
            auto pw=str(v,"password",128);
            room_=room;
            controller_=false;
            reset_sync();
            emit({
                {
                    "Set",{
                        {
                            "room",{
                                {"name",room}
                            }
                        }
                    }
                }
            }
            );
            emit({
                {
                    "Set",{
                        {
                            "controllerAuth",{
                                {"room",room}
                                ,{"password",pw}
                            }
                        }
                    }
                }
            }
            );
        }
    }
    void Session::receive(const std::string& line,double now){
        if(line.size()>16384){
            disconnected("Oversized protocol message");
            return;
        }
        try{
            auto j=Json::parse(line);
            if(!j.is_object())throw std::runtime_error("object");
            lastReceive_=now;
            now_=now;
            if(j.contains("Error")){
                disconnected("Server rejected the request");
                return;
            }
            if(!logged_&&j.contains("State")&&j["State"].is_object())pending_state_=j["State"];
            if(j.contains("Hello")){
                auto& h=j["Hello"];
                user_=str(h,"username");
                room_=str(h.at("room"),"name");
                logged_=true;
                connection_="connected";
                error_.clear();
                chatSupported_=false;
                chatMaxLength_=150;
                auto features=h.find("features");
                if(features!=h.end()&&features->is_object()){
                    chatSupported_=flag(*features,"chat");
                    auto limit=features->find("maxChatMessageLength");
                    if(limit!=features->end()&&limit->is_number_integer()){
                        auto value=limit->get<long long>();
                        if(value>=0)chatMaxLength_=static_cast<size_t>(value);
                    }
                }
                auto pending=pending_state_;
                reset_sync();
                file();
                if(pending.is_object())state(pending,now);
                emit({
                    {
                        "Set",{
                            {
                                "ready",{
                                    {"isReady",false}
                                    ,{"manuallyInitiated",false}
                                }
                            }
                        }
                    }
                }
                );
            }
            if(logged_&&j.contains("Set")&&j["Set"].is_object())set(j["Set"]);
            if(logged_&&chatSupported_&&j.contains("Chat")&&j["Chat"].is_object()){
                auto& chat=j["Chat"];
                publish_event({{"type","chat"},{"username",str(chat,"username")},{"text",chat_text(chat,"message",chatMaxLength_)}});
            }
            if(logged_&&j.contains("List")&&j["List"].is_object()){
                members_.clear();
                controller_=false;
                for(auto& r:j["List"].items())if(r.value().is_object())for(auto& u:r.value().items())if(u.value().is_object())member(u.key(),r.key(),u.value());
            }
            if(logged_&&j.contains("State")&&j["State"].is_object())state(j["State"],now);
            notify();
        }
        catch(const std::exception&){
            disconnected("Invalid server protocol message");
        }
    }
    void Session::reply(const Json& ping,bool change,bool seek){
        Json s={
            {
                "ping",{
                    {"clientLatencyCalculation",now_}
                    ,{"clientRtt",rtt_}
                }
            }
        };
        if(ping.is_object()&&ping.contains("latencyCalculation")&&ping["latencyCalculation"].is_number())s["ping"]["latencyCalculation"]=ping["latencyCalculation"];
        if(local_.loaded&&!local_.buffering&&std::abs(local_.speed-1)<.001&&(change||!clientIgnore_||serverIgnore_)){
            s["playstate"]={
                {"position",local_.position}
                ,{"paused",local_.paused}
            };
            if(seek)s["playstate"]["doSeek"]=true;
        }
        if(change)++clientIgnore_;
        if(serverIgnore_)s["ignoringOnTheFly"]["server"]=serverIgnore_;
        if(clientIgnore_)s["ignoringOnTheFly"]["client"]=clientIgnore_;
        serverIgnore_=0;
        emit({
            {"State",s}
        }
        );
    }
    void Session::state(const Json& s,double now){
        if(s.contains("ignoringOnTheFly")&&s["ignoringOnTheFly"].is_object()){
            auto& i=s["ignoringOnTheFly"];
            if(i.contains("server")){
                serverIgnore_=seq(i,"server");
                clientIgnore_=0;
            }
            else if(seq(i,"client")==clientIgnore_)clientIgnore_=0;
        }
        auto ping=s.value("ping",Json::object());
        if(ping.is_object()&&ping.contains("clientLatencyCalculation")){
            double sample=now-number(ping,"clientLatencyCalculation",now);
            if(sample>=0&&sample<10)rtt_=rtt_?rtt_*.85+sample*.15:sample;
        }
        if(!clientIgnore_&&s.contains("playstate")&&s["playstate"].is_object()){
            auto& p=s["playstate"];
            if(p.contains("position")&&p["position"].is_number()&&p.contains("paused")&&p["paused"].is_boolean()){
                double pos=number(p,"position",-1);
                bool paused=flag(p,"paused");
                if(pos>=0)playback_event(p,now);
                if(pos>=0&&local_.loaded&&!local_.buffering&&std::abs(local_.speed-1)<.001){
                    if(!paused)pos+=std::min(rtt_/2,1.0);
                    Correction c;
                    if(local_.paused!=paused)c.paused=paused;
                    if(local_.seekable&&(first_||flag(p,"doSeek")||std::abs(local_.position-pos)>1.5)){
                        c.position=pos;
                        local_.position=pos;
                    }
                    if(c.paused)local_.paused=*c.paused;
                    if((c.position||c.paused)&&apply)apply(c);
                    first_=false;
                }
            }
        }
        reply(ping);
    }
    void Session::playback_event(const Json& p,double now){
        std::string user;
        auto setter=p.find("setBy");
        if(setter!=p.end()&&setter->is_string())user=setter->get<std::string>();
        // Upstream sends a rejected ordinary member's pause state immediately
        // before its authoritative correction. That is not a room action.
        if(controlled()&&!user.empty()){
            if(user==user_&&!controller_)return;
            auto member=members_.find(user);
            if(member!=members_.end()&&!flag(member->second,"is_controller"))return;
        }
        const bool paused=flag(p,"paused"),seek=flag(p,"doSeek");
        const double position=number(p,"position");
        const double expected=eventPosition_+(eventPaused_?0:std::max(0.0,now-eventTime_));
        const bool moved=seek&&std::abs(position-expected)>.1;
        if(eventBaseline_&&(paused!=eventPaused_||moved)){
            publish_event({{"type","playback"},{"username",user},{"paused",paused},{"position",position},{"seek",moved}});
        }
        eventBaseline_=true;
        eventPaused_=paused;
        eventPosition_=position;
        eventTime_=now;
    }
    void Session::local_change(bool seek,double now){
        now_=now;
        if(logged_&&local_.loaded&&!local_.buffering&&std::abs(local_.speed-1)<.001&&(!controlled()||controller_))reply(Json::object(),true,seek);
    }
    void Session::tick(double now){
        if((logged_||connection_=="connecting")&&lastReceive_>0&&now-lastReceive_>12.5)disconnected("Server timed out");
    }
    void Session::command(const Json& c){
        auto a=str(c,"action");
        if(a=="chat"){
            if(!logged_)throw std::runtime_error("Connect to a room before sending chat");
            if(!chatSupported_)throw std::runtime_error("Chat is disabled or unsupported by this server");
            auto text=chat_text(c,"text",chatMaxLength_);
            if(text.empty())throw std::runtime_error("Chat message is empty");
            emit({{"Chat",text}});
            return;
        }
        if(!logged_)return;
        if(a=="room"){
            auto r=str(c,"room");
            room_=r;
            controller_=ready_=false;
            reset_sync();
            emit({
                {
                    "Set",{
                        {
                            "room",{
                                {"name",r}
                            }
                        }
                    }
                }
            }
            );
            emit({
                {"List",nullptr}
            }
            );
        }
        else if(a=="ready"){
            if(!c.contains("ready")||!c["ready"].is_boolean())throw std::runtime_error("Invalid readiness");
            emit({
                {
                    "Set",{
                        {
                            "ready",{
                                {"isReady",c["ready"]}
                                ,{"manuallyInitiated",true}
                            }
                        }
                    }
                }
            }
            );
        }
        else if(a=="authenticate"||a=="create-room"){
            auto pw=str(c,"password",128);
            auto r=a=="create-room"?str(c,"room"):room_;
            if(a=="create-room"){
                size_t characters=0;
                for(unsigned char ch:r)if((ch&0xc0)!=0x80)++characters;
                if(characters>21)throw std::runtime_error("Controlled room base name must contain at most 21 characters");
            }
            if(a=="create-room"&&!std::regex_match(pw,std::regex("^[A-Z]{2}-[0-9]{3}-[0-9]{3}$")))throw std::runtime_error("Use operator password AA-123-456");
            emit({
                {
                    "Set",{
                        {
                            "controllerAuth",{
                                {"room",r}
                                ,{"password",pw}
                            }
                        }
                    }
                }
            }
            );
        }
        notify();
    }
}
