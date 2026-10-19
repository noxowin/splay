#pragma once
#include "../../third_party/json/json.hpp"
#include <functional>
#include <cmath>
#include <map>
#include <deque>
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
        ~Session(){forget_password();}
        std::function<void(const Json&)> send;
        std::function<void(const Correction&)> apply;
        std::function<void()> changed;
        std::function<void(const Json&)> event;
        void configure(std::string host,int port,std::string user,std::string room,std::string password,bool reuse_password=false);
        void forget_password();
        bool can_reuse_password(const std::string& host,int port) const { return host==host_&&port==port_&&!password_.empty(); }
        void reconnect();
        void connected(bool encrypted,double now);
        void disconnected(const std::string& error="",bool retryable=false);
        bool retryable() const { return retryable_; }
        void receive(const std::string& line,double now);
        void command(const Json& command);
        void playback(const Playback& value);
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
        bool encrypted_=false,logged_=false,ready_=false,controller_=false,first_=true,retryable_=false;
        bool chatSupported_=false,playlistSupported_=false,readySupported_=true,readyRequested_=false;
        size_t chatMaxLength_=150;
        uint64_t eventId_=0;
        bool eventBaseline_=false,eventPaused_=true;
        double eventPosition_=0,eventTime_=0;
        unsigned clientIgnore_=0,serverIgnore_=0;
        double rtt_=0,lastReceive_=0,now_=0;
        struct LatencyReport {
            std::string session;
            uint64_t seq=0;
            double rtt_ms=0,received=0;
            bool reported=false;
        };
        bool latencyEnabled_=false,latencyPublished_=false,rttSample_=false;
        double rttReceived_=0,lastLatencyShare_=0;
        uint64_t latencySeq_=0;
        std::string latencySession_;
        std::deque<double> sentPings_;
        std::map<std::string,LatencyReport> latencyReports_;
        Playback local_;
        bool autostartEnabled_=false,autostartPending_=false,autostartBlocked_=false,autostartResetSeen_=false;
        bool membersComplete_=false,autostartAuthenticated_=false,autostartReadinessSupported_=false;
        int autostartDelay_=5,autostartRemaining_=0;
        double autostartDeadline_=0;
        std::string autostartReason_="disabled";
        Json autostartSnapshot_;
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
        void member(const std::string&,const std::string&,const Json&,bool file_update=true,bool allow_latency=true);
        Json latency(const std::string&) const;
        void read_latency(const std::string&,const std::string&,const Json&);
        void reset_latency();
        Json autostart_members() const;
        void update_autostart(bool expire=false);
        void cancel_autostart(const std::string& reason,bool disable=false);
        bool controlled() const;
        void file(bool refresh_list=true);
    };
    std::string password_md5(const std::string&);
}
