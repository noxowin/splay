#include "session.hpp"
#include "media_name.hpp"
#include "md5.hpp"
#include <cmath>
#include <regex>
#include <stdexcept>
#include <random>
#include <algorithm>
#ifdef _WIN32
#include <windows.h>
#include <bcrypt.h>
#endif
namespace splay {
    namespace {
        void wipe(std::string& value){
#ifdef _WIN32
            if(!value.empty())SecureZeroMemory(value.data(),value.size());
#else
            volatile char* data=value.empty()?nullptr:&value[0];
            for(size_t n=0;n<value.size();++n)data[n]=0;
#endif
            value.clear();
        }
        std::string latency_session(){
            unsigned char bytes[8];
#ifdef _WIN32
            if(BCryptGenRandom(nullptr,bytes,sizeof(bytes),BCRYPT_USE_SYSTEM_PREFERRED_RNG)<0)return {};
#else
            std::random_device random;
            for(auto& byte:bytes)byte=static_cast<unsigned char>(random());
#endif
            std::string result;
            for(auto byte:bytes){result+="0123456789abcdef"[byte>>4];result+="0123456789abcdef"[byte&15];}
            return result;
        }
        struct SecretGuard {
            std::string& value;
            ~SecretGuard(){wipe(value);}
        };
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
            std::string name;
            auto filename=j.find("name");
            if(filename!=j.end()&&filename->is_string()){
                // A peer may send its full path. Keep only a safe local
                // basename; a URL never becomes a filename fallback.
                name=peer_media_name(filename->get<std::string>());
            }
            double size=0;
            auto bytes=j.find("size");
            if(bytes!=j.end()&&bytes->is_number()){
                auto value=bytes->get<double>();
                if(std::isfinite(value)&&value>=0&&value<=9e15)size=value;
            }
            return {
                {"name",name.empty()?"**Hidden filename**":name}
                ,{"duration",std::max(0.0,number(j,"duration"))}
                ,{"size",size}
            };
        }
        bool version_at_least(const Json& hello,int minor){
            auto version=hello.find("realversion");
            if(version==hello.end()||!version->is_string())version=hello.find("version");
            if(version==hello.end()||!version->is_string())return false;
            std::smatch match;
            const auto text=version->get<std::string>();
            if(!std::regex_search(text,match,std::regex("^([0-9]{1,3})\\.([0-9]{1,3})(?:\\.|$)")))return false;
            const int major=std::stoi(match[1]),actualMinor=std::stoi(match[2]);
            return major>1||(major==1&&actualMinor>=minor);
        }
        Json playlist_files(const Json& value){
            if(!value.is_array()||value.size()>250)throw std::runtime_error("Shared playlist must contain at most 250 entries");
            size_t characters=0;
            for(const auto& entry:value){
                if(!entry.is_string())throw std::runtime_error("Invalid shared playlist entry");
                const auto text=entry.get<std::string>();
                if(text.empty())throw std::runtime_error("Shared playlist entries cannot be empty");
                Json(text).dump(); // Validate UTF-8 for direct command calls too.
                for(unsigned char ch:text){
                    if(ch<32||ch==127)throw std::runtime_error("Shared playlist entries contain control characters");
                    if((ch&0xc0)!=0x80&&++characters>10000)throw std::runtime_error("Shared playlist exceeds 10000 characters");
                }
            }
            return value;
        }
        Json playlist_index(const Json& value,size_t count,bool nullable){
            if(nullable&&value.is_null())return nullptr;
            if(!value.is_number_integer()||value.is_boolean())throw std::runtime_error("Invalid shared playlist index");
            if(value.is_number_unsigned()&&value.get<uint64_t>()>=count)throw std::runtime_error("Shared playlist index is out of range");
            const auto index=value.get<int64_t>();
            if(index<0||static_cast<uint64_t>(index)>=count)throw std::runtime_error("Shared playlist index is out of range");
            return index;
        }
        size_t upstream_json_size(const Json& value){
            const auto encoded=value.dump(-1,' ',true);
            size_t bytes=encoded.size();
            bool quoted=false,escaped=false;
            for(unsigned char ch:encoded){
                if(escaped){escaped=false;continue;}
                if(quoted){
                    if(ch=='\\')escaped=true;
                    else if(ch=='"')quoted=false;
                    else if(ch==127)bytes+=5; // Python ensure_ascii escapes DEL.
                }
                else if(ch=='"')quoted=true;
                else if(ch==','||ch==':')++bytes; // Python's default spaces.
            }
            return bytes;
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
        // No server password means no password field, not the empty digest.
        return input.empty()?std::string():md5_hex(input);
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
        haveRoomPosition_=false;
        haveRoomState_=false;
        roomJoinPending_=pauseOnJoin_;
        roomPausePending_=roomPauseAlign_=emptyRoomState_=false;
        roomPauseForJoin_=roomPauseForLeave_=false;
        roomPolicyBaseline_=false;
        reset_latency();
    }
    void Session::reset_latency(){
        rttSample_=false;
        rttReceived_=0;
        sentPings_.clear();
        latencyReports_.clear();
        latencyPublished_=false;
        lastLatencyShare_=0;
        latencySeq_=0;
        // Generated lazily only when sharing has explicitly been enabled.
        latencySession_.clear();
    }
    Json Session::autostart_members() const {
        Json result=Json::object();
        for(const auto& entry:members_)if(entry.second.value("room",std::string())==room_)
            result[entry.first]={{"file",entry.second["file"]},{"controller",entry.second["is_controller"]}};
        return result;
    }
    void Session::cancel_autostart(const std::string& reason,bool disable){
        const bool pending=autostartPending_;
        autostartPending_=false;
        autostartRemaining_=0;
        autostartDeadline_=0;
        if(autostartEnabled_){autostartBlocked_=true;autostartResetSeen_=false;autostartReason_=reason;}
        if(disable){autostartEnabled_=false;autostartReason_="disabled";}
        if(pending)publish_event({{"type","autostart"},{"action","cancelled"},{"reason",reason}});
    }
    void Session::request_room_pause(bool align,bool join){
        cancel_autostart("waiting-reset");
        roomPausePending_=true;
        roomPauseAlign_=roomPauseAlign_||align;
        if(align||join)roomPauseForJoin_=true;else roomPauseForLeave_=true;
        update_room_policy();
    }
    bool Session::update_room_policy(){
        if(!logged_||roomJoinPending_||!roomPausePending_||!haveRoomPosition_||!haveRoomState_)return false;
        // Controller metadata in a List is not authentication. Only the
        // server's successful controllerAuth for this connection permits an
        // automatic room control, just like the automatic-start policy.
        const bool canPause=!controlled()||(controller_&&autostartAuthenticated_);
        if(!canPause&&!roomPauseAlign_){roomPausePending_=roomPauseForJoin_=roomPauseForLeave_=false;return false;}
        if(roomPauseAlign_&&local_.loaded&&
           (local_.buffering||!local_.seekable||!std::isfinite(local_.speed)||std::abs(local_.speed-1)>=.001))return false;
        const double position=std::max(0.0,room_position());
        const bool align=roomPauseAlign_&&local_.loaded;
        const bool paused=canPause?true:roomPaused_;
        Correction correction;
        if(!align&&local_.paused!=(offsetBoundaryHold_||paused)){
            correction.paused=offsetBoundaryHold_||paused;local_.paused=*correction.paused;
        }
        const bool broadcast=canPause&&!roomPaused_;
        roomPausePending_=roomPauseAlign_=false;
        roomPauseForJoin_=roomPauseForLeave_=false;
        if(align)follow_room_position(position,paused,true);
        else if((correction.position||correction.paused)&&apply)apply(correction);
        // Never derive this report from the joining player's old position,
        // or from a media position clamped by its offset/duration boundary.
        if(broadcast){
            roomPosition_=position;roomPositionTime_=now_;roomPaused_=true;
            reply(Json::object(),true,false,position);
        }
        return broadcast;
    }
    void Session::update_autostart(bool expire){
        const auto before=Json::array({autostartPending_,autostartRemaining_,autostartReason_});
        const auto snapshot=autostart_members();
        bool allReady=membersComplete_&&snapshot.contains(user_)&&snapshot.size()>=2;
        bool readinessAll=allReady;
        for(const auto& entry:snapshot.items()){
            const auto& member=members_.at(entry.key());
            if(member["ready"]!=Json(true)){readinessAll=false;allReady=false;}
            if(!member["file"].is_object()||member["file"].empty())allReady=false;
        }
        // A new readiness phase is the only implicit way to rearm. Membership,
        // file, permission and media recovery alone must never resume a timer.
        if(autostartEnabled_&&autostartPending_&&snapshot!=autostartSnapshot_)cancel_autostart("waiting-reset");
        std::string reason;
        if(!autostartEnabled_)reason="disabled";
        else if(!logged_)reason="disconnected";
        else if(!autostartReadinessSupported_)reason="unsupported";
        else if(controlled()&&(!controller_||!autostartAuthenticated_))reason="no-permission";
        else if(!membersComplete_||!snapshot.contains(user_)||roomJoinPending_||roomPausePending_)reason="waiting-snapshot";
        else if(snapshot.size()<2)reason="waiting-members";
        else if(!allReady)reason="waiting-ready";
        else if(!local_.loaded||!local_.paused||local_.buffering||!local_.seekable||offsetBoundaryHold_||!std::isfinite(local_.speed)||std::abs(local_.speed-1)>=.001)reason="waiting-media";
        if(autostartPending_&&!reason.empty())cancel_autostart(reason);
        if(autostartEnabled_&&autostartBlocked_&&membersComplete_){
            // Only explicit readiness (false/unknown), with a complete room,
            // establishes a new phase. File disappearance alone is no reset.
            if(snapshot.contains(user_)&&snapshot.size()>=2&&!readinessAll)autostartResetSeen_=true;
            if(readinessAll&&autostartResetSeen_){autostartBlocked_=false;autostartResetSeen_=false;}
        }
        if(autostartEnabled_&&allReady&&autostartBlocked_&&reason!="no-permission"&&reason!="unsupported")
            reason=autostartReason_=="started"?"started":"waiting-reset";
        if(reason.empty()&&!autostartBlocked_){
            if(!autostartPending_){
                autostartPending_=true;
                autostartSnapshot_=snapshot;
                autostartDeadline_=now_+autostartDelay_;
            }
            autostartRemaining_=static_cast<int>(std::ceil(std::max(0.0,autostartDeadline_-now_)));
            reason="countdown";
            if(expire&&now_>=autostartDeadline_){
                // Use the normal pause correction / State change channel only.
                // Never seek, reload media or run the local-ready gesture path.
                autostartPending_=false;
                autostartBlocked_=true;
                autostartResetSeen_=false;
                autostartRemaining_=0;
                autostartDeadline_=0;
                local_.paused=false;
                Correction correction;correction.paused=false;
                if(apply)apply(correction);
                reply(Json::object(),true,false);
                reason="started";
                publish_event({{"type","autostart"},{"action","started"}});
            }
        }
        if(reason.empty())reason="waiting-reset";
        autostartReason_=reason;
        if(before!=Json::array({autostartPending_,autostartRemaining_,autostartReason_}))notify();
    }
    void Session::playback(const Playback& value){
        const bool status_changed=local_.loaded!=value.loaded||local_.buffering!=value.buffering||local_.seekable!=value.seekable||
            (std::abs(local_.speed-1)<.001)!=(std::abs(value.speed-1)<.001);
        const auto name=value.loaded?public_media_name(value.public_name):std::string();
        const bool title_changed=local_.loaded&&value.loaded&&local_.public_name!=name;
        local_=value;
        local_.public_name=name;
        // A late title is a metadata update, not a new playback session. Do
        // not reset seek correction, readiness or the local countdown here.
        if(title_changed&&logged_)file(false);
        update_room_policy();
        update_autostart();
        if(status_changed)notify();
    }
    void Session::clear_playlist(){
        playlist_={{"files",Json::array()},{"index",nullptr},{"user",""}};
        pending_playlist_=Json::object();
    }
    void Session::room_changed(const std::string& room){
        cancel_autostart("room-changed",true);
        membersComplete_=autostartAuthenticated_=false;
        const auto previous=room_;
        const bool withdraw=latencyPublished_;
        room_=room;
        controller_=ready_=readyRequested_=false;
        clear_playlist();
        reset_sync();
        if(withdraw&&logged_)file(false);
        if(previous!=room_)publish_event({{"type","room"},{"room",room_},{"previous_room",previous}});
    }
    bool Session::controlled() const {
        static const std::regex re("^\\+.*:[A-Za-z0-9_]{12}$");
        return std::regex_match(room_,re);
    }
    void Session::forget_password(){
        wipe(password_);
    }
    void Session::configure(std::string h,int p,std::string u,std::string r,std::string pw,bool reuse_password){
        SecretGuard guard{pw};
        if(h.empty()||h.size()>253||u.empty()||u.size()>128||r.empty()||r.size()>256||pw.size()>1024||p<1||p>65535) throw std::runtime_error("Invalid connection settings");
        if(reuse_password&&!can_reuse_password(h,p))throw std::runtime_error("Password entry expired; enter it again");
        if(!reuse_password){
            forget_password();
            password_=password_md5(pw);
        }
        host_=h;
        port_=p;
        user_=u;
        room_=r;
        reconnect();
    }
    void Session::reconnect(){
        cancel_autostart("reconnected",true);
        membersComplete_=autostartAuthenticated_=autostartReadinessSupported_=false;
        connection_="connecting";
        retryable_=false;
        encrypted_=false;
        lastReceive_=0;
        error_.clear();
        logged_=false;
        chatSupported_=false;
        playlistSupported_=false;
        readySupported_=true;
        readyRequested_=false;
        clear_playlist();
        chatMaxLength_=150;
        members_.clear();
        controller_=ready_=false;
        reset_sync();
        publish_event({{"type","connection"},{"connection",connection_}});
        notify();
    }
    void Session::connected(bool secure,double now){
        encrypted_=secure;
        lastReceive_=now;
        now_=std::max(now_,now);
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
                    {"sharedPlaylists",true}
                    ,{"featureList",true}
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
    void Session::disconnected(const std::string& error,bool retryable){
        cancel_autostart("disconnected",true);
        membersComplete_=autostartAuthenticated_=autostartReadinessSupported_=false;
        const auto previous=connection_;
        const auto previousError=error_;
        logged_=false;
        retryable_=retryable;
        chatSupported_=false;
        playlistSupported_=false;
        readyRequested_=false;
        clear_playlist();
        chatMaxLength_=150;
        connection_=error.empty()?"disconnected":"error";
        error_=error;
        encrypted_=false;
        members_.clear();
        controller_=ready_=false;
        reset_sync();
        if(connection_!=previous||error_!=previousError)publish_event({{"type","connection"},{"connection",connection_}});
        notify();
    }
    Json Session::status() const {
        std::string warning;
        if(logged_){
            if(!local_.loaded)warning="Waiting for media; synchronization is suspended";
            else if(std::abs(local_.speed-1)>.001)warning="Synchronization requires playback speed 1.0; synchronization is suspended";
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
            ,{"playlist_supported",playlistSupported_}
            ,{"playlist",playlist_}
            ,{"error",error_}
            ,{"warning",warning}
            ,{"time_offset",timeOffset_}
            ,{"time_offset_boundary",offsetBoundaryHold_}
            ,{"room_policy",{{"pause_on_leave",pauseOnLeave_},{"pause_on_join",pauseOnJoin_}}}
            ,{"members",members}
            ,{"autostart",{{"enabled",autostartEnabled_},{"delay",autostartDelay_},{"pending",autostartPending_},
                {"remaining",autostartRemaining_},{"reason",autostartReason_},{"participants",autostart_members().size()}}}
        };
    }
    Json Session::latency_status() const {
        Json members=Json::object();
        for(const auto& m:members_){
            if(m.first==user_)continue;
            auto value=latency(m.first);
            if(value["reported"].get<bool>())members[m.first]=std::move(value);
        }
        return {{"schema",1},{"enabled",latencyEnabled_},{"self",latency(user_)},{"members",std::move(members)}};
    }
    Json Session::latency(const std::string& user) const {
        Json result={{"rtt_ms",nullptr},{"reported",false},{"stale",false},{"self_reported",user!=user_}};
        if(!latencyEnabled_||!logged_)return result;
        if(user==user_){
            result["reported"]=rttSample_;
            result["stale"]=rttSample_&&now_-rttReceived_>=30;
            // Whole milliseconds, as displayed: sub-millisecond smoothing noise
            // would otherwise make every heartbeat a visible state change.
            if(rttSample_&&!result["stale"].get<bool>())result["rtt_ms"]=std::round(rtt_*1000);
        }
        else{
            auto member=members_.find(user);
            auto report=latencyReports_.find(user);
            if(member==members_.end()||member->second.value("room",std::string())!=room_||report==latencyReports_.end())return result;
            const auto& value=report->second;
            result["reported"]=value.reported;
            result["stale"]=value.reported&&now_-value.received>=30;
            if(value.reported&&!result["stale"].get<bool>())result["rtt_ms"]=std::round(value.rtt_ms);
        }
        return result;
    }
    void Session::read_latency(const std::string& user,const std::string& room,const Json& file){
        if(!latencyEnabled_||user==user_)return;
        if(room!=room_){latencyReports_.erase(user);return;}
        auto invalidate=[&](){auto i=latencyReports_.find(user);if(i!=latencyReports_.end())i->second.reported=false;};
        if(!file.is_object()||!file.contains("splayLatency")){invalidate();return;}
        const auto& value=file["splayLatency"];
        if(!value.is_object()||!value.contains("v")||!value["v"].is_number_integer()||value["v"]!=1||
           !value.contains("seq")||!value["seq"].is_number_integer()||
           !value.contains("rtt_ms")||!value["rtt_ms"].is_number()||
           !value.contains("session")||!value["session"].is_string()){invalidate();return;}
        const double measured=value["rtt_ms"].get<double>();
        const double sequence=value["seq"].get<double>();
        const auto session=value["session"].get<std::string>();
        if(!std::isfinite(measured)||measured<0||measured>10000||sequence<1||sequence>2147483647||
           session.size()<8||session.size()>32||session.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")!=session.npos){invalidate();return;}
        auto& report=latencyReports_[user];
        const auto id=static_cast<uint64_t>(sequence);
        // Repeated List snapshots and old packets never extend freshness.
        if(report.session==session&&id<=report.seq)return;
        report={session,id,measured,now_,true};
    }
    void Session::member(const std::string& user,const std::string& room,const Json& j,bool file_update,bool allow_latency){
        if(user.size()>256||room.size()>256||user.find_first_not_of(' ')==std::string::npos)return;
        Json ready=nullptr;
        if(j.contains("isReady")&&j["isReady"].is_boolean())ready=j["isReady"];
        if(file_update&&allow_latency)read_latency(user,room,j.value("file",Json::object()));
        if(room!=room_)latencyReports_.erase(user);
        members_[user]={
            {"username",user}
            ,{"room",room}
            ,{"ready",ready}
            ,{"is_controller",flag(j,"controller")}
            ,{"file",safe_file(j.value("file",Json::object()))}
        };
        if(user==user_){
            controller_=flag(j,"controller");
            if(!controller_&&autostartAuthenticated_){
                autostartAuthenticated_=false;
                cancel_autostart("no-permission");
            }
            if(ready.is_boolean())ready_=ready.get<bool>();
        }
    }
    void Session::media_changed(){
        timeOffset_=0;
        offsetBoundaryHold_=false;
        haveRoomPosition_=false;
        haveRoomState_=false;
        cancel_autostart("waiting-reset");
        update_autostart();
        first_=true;
        if(logged_)file();
        notify();
    }
    void Session::file(bool refresh_list){
        Json value=local_.loaded?Json{{"name",local_.public_name.empty()?"**Hidden filename**":local_.public_name},{"duration",local_.duration},{"size",0}}:Json::object();
        latencyPublished_=false;
        if(local_.loaded&&latencyEnabled_&&rttSample_&&now_-rttReceived_<30){
            if(latencySession_.empty())latencySession_=latency_session();
            if(!latencySession_.empty()){
                value["splayLatency"]={{"v",1},{"rtt_ms",rtt_*1000},{"seq",++latencySeq_},{"session",latencySession_}};
                latencyPublished_=true;
                lastLatencyShare_=now_;
            }
        }
        emit({
            {
                "Set",{
                    {
                        "file",value}
                }
            }
        }
        );
        if(refresh_list)emit({
            {"List",nullptr}
        }
        );
    }
    void Session::playlist(const Json& value,bool index){
        // A malformed optional playlist update must not tear down playback or
        // replace the last valid authoritative snapshot.
        try{
            if(!playlistSupported_)throw std::runtime_error("Shared playlists are disabled or unsupported by this server");
            if(!value.is_object())throw std::runtime_error("Invalid shared playlist update");
            std::string user;
            auto setter=value.find("user");
            if(setter!=value.end()&&!setter->is_null())user=str(value,"user");
            Json next=playlist_;
            if(index)next["index"]=playlist_index(value.at("index"),next["files"].size(),true);
            else{
                next["files"]=playlist_files(value.at("files"));
                // Upstream may send a replacement list without an index. Keep
                // an existing valid index until its separate index update.
                if(!next["index"].is_null()&&next["index"].get<size_t>()>=next["files"].size())next["index"]=nullptr;
            }
            next["user"]=user;
            const bool changed=index?next["index"]!=playlist_["index"]:next["files"]!=playlist_["files"];
            playlist_=std::move(next);
            error_.clear();
            if(changed){
                Json notice={{"type","playlist"},{"action",index?"index":"files"},{"user",user},{"index",playlist_["index"]}};
                if(!index)notice["files"]=playlist_["files"];
                publish_event(std::move(notice));
            }
        }
        catch(const std::exception& exception){error_=exception.what();}
    }
    void Session::set(const Json& j){
        if(j.contains("room")&&j["room"].is_object()){
            const auto room=str(j["room"],"name");
            if(room!=room_)room_changed(room);
            emit({
                {"List",nullptr}
            }
            );
        }
        if(j.contains("user")&&j["user"].is_object())for(auto& item:j["user"].items()){
            auto v=item.value();
            if(!v.is_object())continue;
            const bool known=members_.count(item.key())!=0;
            const bool baseline=roomPolicyBaseline_&&!roomJoinPending_;
            if(!known&&!(v.contains("event")&&v["event"].is_object()&&flag(v["event"],"joined")))membersComplete_=false;
            Json old=known?members_[item.key()]:Json::object();
            if(v.contains("event")&&v["event"].is_object()&&flag(v["event"],"left")){
                members_.erase(item.key());
                latencyReports_.erase(item.key());
                if(baseline&&known&&item.key()!=user_&&old.value("room",std::string())==room_&&pauseOnLeave_)
                    request_room_pause();
                if(known)publish_event({{"type","user"},{"action","left"},{"username",item.key()},{"room",old.value("room",room_)}});
                continue;
            }
            std::string r=known?old.value("room",room_):room_;
            if(v.contains("room")&&v["room"].is_object())r=str(v["room"],"name");
            if(!v.contains("isReady")&&old.contains("ready"))v["isReady"]=old["ready"];
            if(!v.contains("controller")&&old.contains("is_controller"))v["controller"]=old["is_controller"];
            const bool file_update=v.contains("file");
            if(!v.contains("file")&&old.contains("file"))v["file"]=old["file"];
            member(item.key(),r,v,file_update,known||(v.contains("event")&&v["event"].is_object()&&flag(v["event"],"joined")));
            auto current=members_.find(item.key());
            if(current==members_.end())continue;
            if(baseline&&item.key()!=user_){
                const bool wasHere=known&&old.value("room",std::string())==room_;
                const bool isHere=r==room_;
                const bool joined=v.contains("event")&&v["event"].is_object()&&flag(v["event"],"joined");
                if(wasHere&&!isHere&&pauseOnLeave_)request_room_pause();
                else if(!wasHere&&isHere&&(known||(joined&&v.contains("room")&&v["room"].is_object()))&&pauseOnJoin_)
                    request_room_pause(false,true);
            }
            if(autostartPending_){
                const bool previouslyHere=known&&old.value("room",std::string())==room_;
                const bool currentlyHere=r==room_;
                if(previouslyHere!=currentlyHere||(currentlyHere&&known&&
                   (old["file"]!=current->second["file"]||old["is_controller"]!=current->second["is_controller"])))
                    cancel_autostart("waiting-reset");
            }
            if(!known&&v.contains("event")&&v["event"].is_object()&&flag(v["event"],"joined")){
                publish_event({{"type","user"},{"action","joined"},{"username",item.key()},{"room",r}});
            }
            else if(known&&old["room"]!=r){
                publish_event({{"type","user"},{"action","room"},{"username",item.key()},{"room",r},{"previous_room",old["room"]}});
            }
            if(known&&old["file"]!=current->second["file"]){
                publish_event({{"type","user"},{"action","file"},{"username",item.key()},{"room",r},{"file",current->second["file"]}});
            }
        }
        if(j.contains("ready")&&j["ready"].is_object()){
            auto& v=j["ready"];
            auto u=str(v,"username");
            if(v.contains("isReady")&&(v["isReady"].is_boolean()||v["isReady"].is_null())){
                Json previous=members_.count(u)?members_[u]["ready"]:(u==user_?Json(ready_):Json(nullptr));
                if(members_.count(u))members_[u]["ready"]=v["isReady"];
                if(u==user_){
                    readyRequested_=false;
                    if(v["isReady"].is_boolean())ready_=v["isReady"].get<bool>();
                }
                if(previous!=v["isReady"]){
                    Json notice={{"type","ready"},{"username",u},{"ready",v["isReady"]},{"manually_initiated",flag(v,"manuallyInitiated")}};
                    if(v.contains("setBy")&&v["setBy"].is_string())notice["set_by"]=str(v,"setBy");
                    publish_event(std::move(notice));
                }
            }
        }
        if(j.contains("controllerAuth")&&j["controllerAuth"].is_object()){
            auto& v=j["controllerAuth"];
            auto u=str(v,"user");
            auto r=str(v,"room");
            bool success=flag(v,"success");
            if(success&&members_.count(u))members_[u]["is_controller"]=true;
            if(u==user_&&r==room_){
                if(autostartAuthenticated_!=success)cancel_autostart(success?"waiting-reset":"no-permission");
                autostartAuthenticated_=success;
                if(success){controller_=true;error_.clear();}
                else error_="Operator authentication failed";
            }
        }
        if(j.contains("newControlledRoom")&&j["newControlledRoom"].is_object()){
            auto& v=j["newControlledRoom"];
            auto room=str(v,"roomName");
            auto pw=str(v,"password",128);
            SecretGuard guard{pw};
            room_changed(room);
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
            // The server broadcasts room switches through Set.user and need
            // not echo Set.room. Obtain the complete new-room membership
            // snapshot explicitly before the join policy can follow State.
            emit({{"List",nullptr}});
        }
        if(j.contains("playlistChange"))playlist(j["playlistChange"],false);
        if(j.contains("playlistIndex"))playlist(j["playlistIndex"],true);
    }
    void Session::receive(const std::string& line,double now,double arrived){
        if(line.size()>131072){
            disconnected("Oversized protocol message");
            return;
        }
        try{
            auto j=Json::parse(line);
            if(!j.is_object())throw std::runtime_error("object");
            lastReceive_=now;
            now_=std::max(now_,now);
            const double at=std::isfinite(arrived)?std::min(arrived,now):now;
            if(j.contains("Error")){
                disconnected("Server rejected the request");
                return;
            }
            if(!logged_&&j.contains("State")&&j["State"].is_object())pending_state_=j["State"];
            if(!logged_&&j.contains("Set")&&j["Set"].is_object()){
                // Official 1.7.6 sends room playlist state before Hello.
                for(const auto* key:{"playlistChange","playlistIndex"})if(j["Set"].contains(key))pending_playlist_[key]=j["Set"][key];
            }
            if(j.contains("Hello")){
                auto& h=j["Hello"];
                user_=str(h,"username");
                room_=str(h.at("room"),"name");
                logged_=true;
                connection_="connected";
                error_.clear();
                chatSupported_=false;
                playlistSupported_=version_at_least(h,4);
                readySupported_=true;
                autostartReadinessSupported_=version_at_least(h,3);
                chatMaxLength_=150;
                auto features=h.find("features");
                if(features!=h.end()&&features->is_object()){
                    chatSupported_=flag(*features,"chat");
                    playlistSupported_=flag(*features,"sharedPlaylists",playlistSupported_);
                    readySupported_=flag(*features,"readiness",true);
                    autostartReadinessSupported_=flag(*features,"readiness",autostartReadinessSupported_);
                    auto limit=features->find("maxChatMessageLength");
                    if(limit!=features->end()&&limit->is_number_integer()){
                        auto value=limit->get<long long>();
                        if(value>=0)chatMaxLength_=static_cast<size_t>(value);
                    }
                }
                auto pending=pending_state_;
                const auto pendingPlaylist=pending_playlist_;
                pending_playlist_=Json::object();
                reset_sync();
                publish_event({{"type","connection"},{"connection",connection_}});
                if(playlistSupported_&&!pendingPlaylist.empty())set(pendingPlaylist);
                file();
                if(pending.is_object())state(pending,at);
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
                membersComplete_=true;
                for(auto& r:j["List"].items()){
                    if(!r.value().is_object()||r.key().size()>256){membersComplete_=false;continue;}
                    for(auto& u:r.value().items()){
                        if(!u.value().is_object()||u.key().size()>256||u.key().find_first_not_of(' ')==std::string::npos){membersComplete_=false;continue;}
                        if(members_.count(u.key()))membersComplete_=false;
                        member(u.key(),r.key(),u.value());
                    }
                }
                if(!members_.count(user_)||members_[user_].value("room",std::string())!=room_)membersComplete_=false;
                if(membersComplete_)roomPolicyBaseline_=true;
                for(auto i=latencyReports_.begin();i!=latencyReports_.end();)if(!members_.count(i->first))i=latencyReports_.erase(i);else ++i;
                if(membersComplete_&&roomJoinPending_){
                    roomJoinPending_=false;
                    if(autostart_members().size()>1)request_room_pause(true);
                    else{
                        // A new ordinary empty room adopts its first player's
                        // clock. Its initial server zero is not a seek command.
                        emptyRoomState_=!haveRoomState_&&!controlled();
                        if(!controlled()){haveRoomPosition_=haveRoomState_=false;first_=false;reply(Json::object());}
                    }
                }
            }
            if(logged_&&j.contains("State")&&j["State"].is_object())state(j["State"],at);
            update_autostart();
            notify();
        }
        catch(const std::exception&){
            disconnected("Invalid server protocol message");
        }
    }
    double Session::room_position() const {
        return roomPosition_+(roomPaused_?0:std::max(0.0,now_-roomPositionTime_));
    }
    double Session::local_position(double room_position) const {
        double position=std::max(0.0,room_position+timeOffset_);
        if(std::isfinite(local_.duration)&&local_.duration>0){
            const double end=offset_outside(room_position)?local_.duration-std::min(1.0,local_.duration/2):local_.duration;
            position=std::min(position,end);
        }
        return position;
    }
    bool Session::offset_outside(double position) const {
        if(!timeOffset_)return false;
        const double target=position+timeOffset_;
        // Stop just before EOF, including the small interval between player
        // sampling and the next correction. Seeking to duration would unload
        // the demuxer and destroy the media-scoped offset/reference clock.
        return target<0||(std::isfinite(local_.duration)&&local_.duration>0&&
            target>=local_.duration-std::min(.25,local_.duration/2));
    }
    void Session::follow_room_position(double position,bool paused,bool force_seek){
        const bool boundary=offset_outside(position);
        const bool boundary_changed=boundary!=offsetBoundaryHold_;
        const double target=local_position(position);
        Correction correction;
        const bool local_paused=boundary||paused;
        if(local_.paused!=local_paused){correction.paused=local_paused;local_.paused=local_paused;}
        if(local_.seekable&&(force_seek||first_||boundary_changed||std::abs(local_.position-target)>1.5)){
            correction.position=target;local_.position=target;
        }
        offsetBoundaryHold_=boundary;
        if((correction.position||correction.paused)&&apply)apply(correction);
        first_=false;
        if(boundary_changed)notify();
    }
    void Session::reply(const Json& ping,bool change,bool seek,std::optional<double> pause_position){
        sentPings_.push_back(now_);
        while(sentPings_.size()>32)sentPings_.pop_front();
        Json s={
            {
                "ping",{
                    {"clientLatencyCalculation",now_}
                    ,{"clientRtt",rtt_}
                }
            }
        };
        if(ping.is_object()&&ping.contains("latencyCalculation")&&ping["latencyCalculation"].is_number())s["ping"]["latencyCalculation"]=ping["latencyCalculation"];
        // A missing segment cannot be represented by a local playback time.
        // Upstream still resets its watcher timestamp on a ping-only reply,
        // so omitting position would repeatedly freeze our last reported
        // clock and make this watcher hold the whole room back. Mirror the
        // authoritative room clock/pause while locally held instead.
        const double target=haveRoomPosition_?room_position()+timeOffset_:local_.position;
        const bool outside=offsetBoundaryHold_||(haveRoomPosition_&&offset_outside(room_position()))||target<0;
        if(!roomJoinPending_&&!roomPausePending_&&local_.loaded&&!local_.buffering&&std::abs(local_.speed-1)<.001&&(change||!clientIgnore_||serverIgnore_)){
            if(!change&&timeOffset_&&outside){
                if(haveRoomState_)s["playstate"]={{"position",std::max(0.0,room_position())},{"paused",roomPaused_}};
            }
            else{
                s["playstate"]={
                    {"position",std::max(0.0,local_.position-timeOffset_)}
                    ,{"paused",local_.paused}
                };
                if(seek)s["playstate"]["doSeek"]=true;
            }
        }
        if(pause_position)s["playstate"]={{"position",*pause_position},{"paused",true}};
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
        if(s.contains("playstate")&&s["playstate"].is_object()){
            const auto& play=s["playstate"];
            if(play.contains("paused")&&play["paused"].is_boolean()&&std::isfinite(number(play,"position",NAN))&&
               ((autostartPending_&&!flag(play,"paused"))||flag(play,"doSeek")||local_.paused!=flag(play,"paused")))cancel_autostart("waiting-reset");
        }
        if(s.contains("ignoringOnTheFly")&&s["ignoringOnTheFly"].is_object()){
            auto& i=s["ignoringOnTheFly"];
            if(i.contains("server")){
                serverIgnore_=seq(i,"server");
                clientIgnore_=0;
            }
            else if(seq(i,"client")==clientIgnore_)clientIgnore_=0;
        }
        auto ping=s.value("ping",Json::object());
        if(ping.is_object()&&ping.contains("clientLatencyCalculation")&&ping["clientLatencyCalculation"].is_number()){
            const double echoed=ping["clientLatencyCalculation"].get<double>();
            // Upstream adds the time it held our ping to the echoed timestamp.
            // Match a real outstanding send interval, rather than requiring
            // byte equality or accepting any arbitrary server-supplied number.
            const auto pending=std::find_if(sentPings_.rbegin(),sentPings_.rend(),[&](double sent){return echoed>=sent&&now-sent<=12.5;});
            const double sample=now-echoed;
            if(std::isfinite(echoed)&&pending!=sentPings_.rend()&&sample>=0&&sample<=10){
                rtt_=rttSample_?rtt_*.85+sample*.15:sample;
                rttSample_=true;
                rttReceived_=now;
                sentPings_.erase(sentPings_.begin(),pending.base());
            }
        }
        if(!clientIgnore_&&s.contains("playstate")&&s["playstate"].is_object()){
            auto& p=s["playstate"];
            if(p.contains("position")&&p["position"].is_number()&&p.contains("paused")&&p["paused"].is_boolean()){
                double pos=number(p,"position",NAN);
                bool paused=flag(p,"paused");
                if(std::isfinite(pos)&&emptyRoomState_){
                    emptyRoomState_=false;
                    reply(ping);
                    return;
                }
                if(std::isfinite(pos)){
                    playback_event(p,now);
                    if(!paused)pos+=std::min(rtt_/2,1.0);
                    roomPosition_=pos;
                    roomPositionTime_=now;
                    roomPaused_=paused;
                    haveRoomPosition_=true;
                    haveRoomState_=true;
                }
                if(std::isfinite(pos)&&!roomJoinPending_&&!roomPausePending_&&local_.loaded&&!local_.buffering&&std::abs(local_.speed-1)<.001){
                    follow_room_position(pos,paused,flag(p,"doSeek"));
                }
            }
        }
        update_room_policy();
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
        now_=std::max(now_,now);
        // An explicit later gesture supersedes a deferred membership pause.
        // Recovery from buffering itself does not call this gesture path.
        roomPausePending_=roomPauseAlign_=roomPauseForJoin_=roomPauseForLeave_=false;
        if(offsetBoundaryHold_&&!seek){
            cancel_autostart("waiting-reset");
            if(local_.loaded&&haveRoomPosition_)follow_room_position(room_position(),roomPaused_);
            update_autostart();return;
        }
        // Until the server acknowledges a local gesture, its previous clock
        // snapshot may no longer describe the current playback position.
        haveRoomPosition_=false;
        haveRoomState_=false;
        cancel_autostart("waiting-reset");
        update_autostart();
        // Only the adapter's explicit local pause-change path reaches this.
        // A remote correction, load, heartbeat or seek cannot set readiness.
        if(logged_&&readySupported_&&local_.loaded&&!local_.buffering&&!seek&&!local_.paused&&!ready_&&!readyRequested_){
            readyRequested_=true;
            emit({{"Set",{{"ready",{{"isReady",true},{"manuallyInitiated",true}}}}}});
        }
        if(logged_&&!roomJoinPending_&&!roomPausePending_&&local_.loaded&&!local_.buffering&&std::abs(local_.speed-1)<.001&&(!controlled()||controller_))reply(Json::object(),true,seek);
    }
    void Session::tick(double now){
        const auto previous=latency(user_);
        bool expired=false;
        for(const auto& value:latencyReports_)if(value.second.reported&&now_-value.second.received<30&&now-value.second.received>=30)expired=true;
        now_=std::max(now_,now);
        if((logged_||connection_=="connecting")&&lastReceive_>0&&now-lastReceive_>12.5)disconnected("Server timed out",true);
        if(logged_&&latencyEnabled_&&local_.loaded&&rttSample_&&
           ((!latencyPublished_&&now_-rttReceived_<30)||(latencyPublished_&&now_-lastLatencyShare_>=10)))file(false);
        if(timeOffset_&&haveRoomPosition_&&!roomJoinPending_&&!roomPausePending_&&local_.loaded&&
           !local_.buffering&&std::abs(local_.speed-1)<.001&&(offsetBoundaryHold_||offset_outside(room_position())))
            follow_room_position(room_position(),roomPaused_);
        update_autostart(true);
        if(expired||previous!=latency(user_))notify();
    }
    void Session::command(const Json& c,double now){
        if(std::isfinite(now))now_=std::max(now_,now);
        auto a=str(c,"action");
        if(a=="room-policy"){
            if(!c.contains("pause_on_leave")||!c["pause_on_leave"].is_boolean()||
               !c.contains("pause_on_join")||!c["pause_on_join"].is_boolean())
                throw std::runtime_error("Invalid room pause preferences");
            pauseOnLeave_=c["pause_on_leave"].get<bool>();
            pauseOnJoin_=c["pause_on_join"].get<bool>();
            if(!pauseOnJoin_){roomJoinPending_=roomPauseForJoin_=roomPauseAlign_=false;}
            if(!pauseOnLeave_)roomPauseForLeave_=false;
            roomPausePending_=roomPauseForJoin_||roomPauseForLeave_;
            notify();return;
        }
        if(a=="set-offset"){
            if(!c.contains("seconds")||!c["seconds"].is_number())throw std::runtime_error("Time offset must be a number from -86400 to 86400 seconds");
            const double offset=c["seconds"].get<double>();
            if(!std::isfinite(offset)||std::abs(offset)>86400)throw std::runtime_error("Time offset must be a number from -86400 to 86400 seconds");
            if(offset!=timeOffset_){
                // While idle() the adapter does not watch the player, so a
                // reference kept from an earlier offset or connection may be
                // older than a seek made since. Start from where the player is.
                if(idle())haveRoomPosition_=offsetBoundaryHold_=false;
                const double position=(haveRoomPosition_||offsetBoundaryHold_)?room_position():local_.position-timeOffset_;
                if(!haveRoomPosition_){
                    // Preserve this reference even if the new offset clamps
                    // playback, so reverting an offset also works offline.
                    roomPosition_=position;
                    roomPositionTime_=now_;
                    if(!offsetBoundaryHold_)roomPaused_=local_.paused;
                    haveRoomPosition_=true;
                }
                timeOffset_=offset;
                cancel_autostart("waiting-reset");
                update_autostart();
                if(local_.loaded&&local_.seekable){
                    follow_room_position(position,roomPaused_,true);
                }
            }
            notify();return;
        }
        if(a=="autostart"){
            if(!c.contains("enabled")||!c["enabled"].is_boolean())throw std::runtime_error("Invalid automatic-start preference");
            int delay=5;
            if(c.contains("delay")){
                if(!c["delay"].is_number_integer()||c["delay"]<3||c["delay"]>30)throw std::runtime_error("Automatic-start delay must be an integer from 3 to 30");
                delay=c["delay"].get<int>();
            }
            cancel_autostart("disabled",true);
            autostartEnabled_=c["enabled"].get<bool>();
            autostartDelay_=delay;
            autostartBlocked_=autostartResetSeen_=false;
            update_autostart();
            notify();return;
        }
        if(a=="autostart-cancel"){
            cancel_autostart("waiting-reset");
            update_autostart();
            notify();return;
        }
        if(a=="latency"){
            if(!c.contains("enabled")||!c["enabled"].is_boolean())throw std::runtime_error("Invalid latency preference");
            const bool enabled=c["enabled"].get<bool>();
            if(enabled!=latencyEnabled_){
                const bool withdraw=latencyPublished_;
                latencyEnabled_=enabled;
                latencyReports_.clear();
                if(logged_&&(enabled||withdraw))file();
            }
            notify();
            return;
        }
        if(a=="chat"){
            if(!logged_)throw std::runtime_error("Connect to a room before sending chat");
            if(!chatSupported_)throw std::runtime_error("Chat is disabled or unsupported by this server");
            auto text=chat_text(c,"text",chatMaxLength_);
            if(text.empty())throw std::runtime_error("Chat message is empty");
            emit({{"Chat",text}});
            return;
        }
        if(a=="playlist-set"||a=="playlist-index"){
            if(!logged_)throw std::runtime_error("Connect to a room before changing the shared playlist");
            if(!playlistSupported_)throw std::runtime_error("Shared playlists are disabled or unsupported by this server");
            if(controlled()&&!controller_)throw std::runtime_error("Only room operators can change the shared playlist");
            Json message;
            if(a=="playlist-set")message={{"Set",{{"playlistChange",{{"files",playlist_files(c.at("files"))}}}}}};
            else message={{"Set",{{"playlistIndex",{{"index",playlist_index(c.at("index"),playlist_["files"].size(),false)}}}}}};
            // Upstream's client and server both inherit Twisted's 16KiB line
            // limit. Check the complete server echo including its actual
            // username, Unicode escaping and Python's default separators.
            auto echo=message;
            echo["Set"][a=="playlist-set"?"playlistChange":"playlistIndex"]["user"]=user_;
            if(upstream_json_size(echo)>16384)throw std::runtime_error("Shared playlist is too large for compatible Syncplay clients");
            emit(message);
            return;
        }
        if(!logged_)return;
        if(a=="room"){
            auto r=str(c,"room");
            room_changed(r);
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
            if(!c["ready"].get<bool>()){
                // Withdrawal takes effect for this local policy immediately;
                // keep public readiness authoritative until the server echo.
                cancel_autostart("waiting-reset");
                update_autostart();
            }
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
            SecretGuard guard{pw};
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
