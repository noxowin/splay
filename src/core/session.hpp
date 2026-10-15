#pragma once
#include "../../third_party/json/json.hpp"
#include <functional>
#include <cmath>
#include <map>
#include <optional>
#include <string>
namespace splay {
    using Json = nlohmann::json;
    struct Playback {
        bool loaded=false, paused=true, buffering=false, seekable=true;
        double position=0, duration=0, speed=1;
    };
    struct Correction {
        std::optional<double> position;
        std::optional<bool> paused;
    };
    class Session {
        public:
        std::function<void(const Json&)> send;
        std::function<void(const Correction&)> apply;
        std::function<void()> changed;
        std::function<void(const Json&)> event;
        void configure(std::string host,int port,std::string user,std::string room,std::string password);
        void connected(bool encrypted,double now);
        void disconnected(const std::string& error="");
        void receive(const std::string& line,double now);
        void command(const Json& command);
        void playback(const Playback& value) {
            const bool status_changed=local_.loaded!=value.loaded||local_.buffering!=value.buffering||local_.seekable!=value.seekable||
                (std::abs(local_.speed-1)<.001)!=(std::abs(value.speed-1)<.001);
            local_=value;
            if(status_changed)notify();
        }
        void local_change(bool seek,double now);
        void media_changed();
        void tick(double now);
        Json status() const;
        bool logged() const {
            return logged_;
        }
        private:
        std::string host_,user_,room_,password_,connection_="disconnected",error_;
        int port_=8999;
        bool encrypted_=false,logged_=false,ready_=false,controller_=false,first_=true;
        bool chatSupported_=false,playlistSupported_=false,readySupported_=true,readyRequested_=false;
        size_t chatMaxLength_=150;
        uint64_t eventId_=0;
        bool eventBaseline_=false,eventPaused_=true;
        double eventPosition_=0,eventTime_=0;
        unsigned clientIgnore_=0,serverIgnore_=0;
        double rtt_=0,lastReceive_=0,now_=0;
        Playback local_;
        Json pending_state_;
        Json pending_playlist_=Json::object();
        Json playlist_={{"files",Json::array()},{"index",nullptr},{"user",""}};
        std::map<std::string,Json> members_;
        void emit(const Json&);
        void notify();
        void publish_event(Json);
        void playback_event(const Json&,double);
        void reset_sync();
        void state(const Json&,double);
        void reply(const Json& ping,bool change=false,bool seek=false);
        void set(const Json&);
        void playlist(const Json&,bool index);
        void clear_playlist();
        void room_changed(const std::string&);
        void member(const std::string&,const std::string&,const Json&);
        bool controlled() const;
        void file();
    };
    std::string password_md5(const std::string&);
}
