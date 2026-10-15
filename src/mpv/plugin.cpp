#define MPV_CPLUGIN_DYNAMIC_SYM
#include "../../third_party/mpv/client.h"
#include "../core/session.hpp"
#include "../core/history.hpp"
#include "../core/credentials.hpp"
#include "../net/transport.hpp"
#include <chrono>
#include <cmath>
#include <cstring>
#include <stdexcept>
namespace {
    double clock_now(){
        return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
    }
    double get_number(mpv_handle* h,const char* p,double fallback=0){
        double v=fallback;
        if(mpv_get_property(h,p,MPV_FORMAT_DOUBLE,&v)<0||!std::isfinite(v))return fallback;
        return v;
    }
    bool get_flag(mpv_handle* h,const char* p,bool fallback=false){
        int v=fallback;
        if(mpv_get_property(h,p,MPV_FORMAT_FLAG,&v)<0)return fallback;
        return v!=0;
    }
    std::string text(const splay::Json& j,const char* key,size_t limit,bool optional=false){
        if(!j.contains(key)){
            if(optional)return {};
            throw std::runtime_error("Missing connection field");
        }
        if(!j[key].is_string())throw std::runtime_error("Invalid connection field");
        auto s=j[key].get<std::string>();
        if(s.size()>limit||(!optional&&s.empty())||s.find('\0')!=s.npos||s.find('\r')!=s.npos||s.find('\n')!=s.npos)throw std::runtime_error("Invalid connection text");
        return s;
    }
}
extern "C" MPV_EXPORT int mpv_open_cplugin(mpv_handle* h){
    try{
        splay::Transport transport;
        splay::Session session;
        splay::History history;
        splay::Credentials credentials;
        double suppress_until=0,next_sample=0;
        bool pending_seek=false;
        bool loading=false;
        std::optional<double> expected_seek;
        std::optional<bool> expected_pause;
        bool running=true,have_previous=false;
        splay::Playback previous;
        auto publish=[&](){
            auto payload=session.status().dump(-1,' ',false,splay::Json::error_handler_t::replace);
            const char* args[]={"script-message-to","splay","splay-state",payload.c_str(),nullptr};
            mpv_command(h,args);
        };
        auto publish_credential=[&](const splay::Json& result){
            auto payload=result.dump(-1,' ',false,splay::Json::error_handler_t::replace);
            const char* args[]={"script-message-to","splay","splay-credential",payload.c_str(),nullptr};
            mpv_command(h,args);
        };
        session.send=[&](const splay::Json& j){
            transport.send_line(j.dump());
        };
        session.changed=publish;
        session.event=[&](const splay::Json& value){
            auto payload=value.dump(-1,' ',false,splay::Json::error_handler_t::replace);
            const char* args[]={"script-message-to","splay","splay-event",payload.c_str(),nullptr};
            mpv_command(h,args);
        };
        session.apply=[&](const splay::Correction& c){
            if(c.paused){
                expected_pause=c.paused;
                int p=*c.paused;
                mpv_set_property(h,"pause",MPV_FORMAT_FLAG,&p);
            }
            if(c.position){
                expected_seek=c.position;
                double p=*c.position;
                mpv_set_property(h,"time-pos",MPV_FORMAT_DOUBLE,&p);
            }
        };
        auto sample=[&](){
            splay::Playback p;
            p.loaded=!loading&&!get_flag(h,"idle-active",true)&&!get_flag(h,"eof-reached");
            p.position=get_number(h,"time-pos");
            p.duration=get_number(h,"duration");
            p.paused=get_flag(h,"pause",true);
            p.buffering=get_flag(h,"paused-for-cache")||get_flag(h,"seeking");
            p.seekable=get_flag(h,"seekable");
            p.speed=get_number(h,"speed",1);
            session.playback(p);
            return p;
        };
        // Detect local changes before any incoming state can replace them.
        auto sample_changes=[&](double now){
            auto p=sample();
            if(pending_seek && !p.buffering){
                pending_seek=false;
                bool echo=expected_seek && std::abs(p.position-*expected_seek)<1.0;
                expected_seek.reset();
                if(!echo && now>suppress_until && have_previous && p.loaded)session.local_change(true,now);
            }

            if(have_previous&&now>suppress_until&&p.loaded&&previous.loaded&&!p.buffering&&!previous.buffering&&p.paused!=previous.paused){
                if(!expected_pause||p.paused!=*expected_pause)session.local_change(false,now);
                expected_pause.reset();
            }
            if(expected_pause&&p.paused==*expected_pause)expected_pause.reset();
            previous=p;
            have_previous=true;
        };
        publish();
        while(running){
            double now=clock_now();
            auto* event=mpv_wait_event(h,.03);
            if(event->event_id==MPV_EVENT_SHUTDOWN)break;
            if(event->event_id==MPV_EVENT_START_FILE || event->event_id==MPV_EVENT_END_FILE){
                loading=true;
                    splay::Playback empty;
                session.playback(empty);
                session.media_changed();
                have_previous=false;
                pending_seek=false;
                expected_seek.reset();
                expected_pause.reset();
                suppress_until=now+1;
            }
            if(event->event_id==MPV_EVENT_FILE_LOADED){
                    loading=false;
                suppress_until=now+1;
                have_previous=false;
                sample();
                session.media_changed();
            }
            if(event->event_id==MPV_EVENT_SEEK) pending_seek=true;
            if(event->event_id==MPV_EVENT_CLIENT_MESSAGE){
                auto* m=static_cast<mpv_event_client_message*>(event->data);
                if(m&&m->num_args==2&&std::strcmp(m->args[0],"splay-command")==0){
                    try{
                        if(std::strlen(m->args[1])>131072)throw std::runtime_error("Command too large");
                        auto c=splay::Json::parse(m->args[1]);
                        if(!c.is_object())throw std::runtime_error("Invalid command");
                        auto action=text(c,"action",32);
                        if(action=="history-load"||action=="history-save"){
                            splay::Json result;
                            try{result=history.handle(c);}
                            catch(const std::exception& exception){result={{"schema",1},{"error",exception.what()}};}
                            catch(...){result={{"schema",1},{"error","History operation failed"}};}
                            auto payload=result.dump(-1,' ',false,splay::Json::error_handler_t::replace);
                            const char* args[]={"script-message-to","splay","splay-history",payload.c_str(),nullptr};
                            mpv_command(h,args);
                        }
                        else if(action=="credential-init"||action=="credential-status"||action=="credential-save"||action=="credential-delete"){
                            auto result=credentials.handle(c);
                            if(c.contains("request_id")&&c["request_id"].is_number_integer())result["request_id"]=c["request_id"];
                            publish_credential(result);
                        }
                        else if(action=="status")publish();
                        else if(action=="disconnect"){
                            transport.disconnect();
                            session.disconnected();
                            have_previous=false;
                            pending_seek=false;
                            expected_seek.reset();
                            expected_pause.reset();
                        }
                        else if(action=="connect"){
                            auto host=splay::Credentials::normalize_host(text(c,"host",1024)),user=text(c,"username",128),room=text(c,"room",256),pw=text(c,"password",1024,true),tls=text(c,"tls",16,true);
                            struct SecretGuard {std::string& value;~SecretGuard(){splay::erase_secret(value);}} password_guard{pw};
                            int port=8999;
                            if(c.contains("port")){
                                if(!c["port"].is_number_integer())throw std::runtime_error("Invalid port");
                                auto value=c["port"].get<long long>();
                                if(value<1||value>65535)throw std::runtime_error("Invalid port");
                                port=static_cast<int>(value);
                            }
                            splay::TlsMode mode=splay::TlsMode::Prefer;
                            if(tls=="require")mode=splay::TlsMode::Require;
                            else if(tls=="off")mode=splay::TlsMode::Off;
                            else if(!tls.empty()&&tls!="prefer")throw std::runtime_error("Invalid TLS mode");
                            if(pw.empty()&&c.value("use_saved_password",false))pw=credentials.password(host,port);
                            else if(!pw.empty()&&c.value("remember_password",false)){
                                const auto result=credentials.handle({{"action","credential-save"},{"host",host},{"port",port},{"password",pw}});
                                publish_credential(result);
                                if(result.contains("error"))throw std::runtime_error(result["error"].get<std::string>());
                            }
                            transport.disconnect();
                            pending_seek=false;
                            expected_seek.reset();
                            expected_pause.reset();
                            sample();
                            session.configure(host,port,user,room,pw);
                            transport.connect({host,port,mode}
                            );
                            have_previous=false;
                            suppress_until=now+1;
                        }
                        else session.command(c);
                    }
                    catch(const std::exception& exception){
                        auto payload=session.status();
                        payload["error"]=dynamic_cast<const std::runtime_error*>(&exception)?exception.what():"Invalid command JSON";
                        auto data=payload.dump(-1,' ',false,splay::Json::error_handler_t::replace);
                        const char* a[]={"script-message-to","splay","splay-state",data.c_str(),nullptr};
                        mpv_command(h,a);
                    }
                }
            }
            if(now>=next_sample){
                sample_changes(now);
                next_sample=now+.1;
            }
            for(auto& e:transport.poll()){
                switch(e.kind){
                    case splay::TransportEvent::Kind::Connected:session.connected(e.encrypted,now);
                    break;
                    case splay::TransportEvent::Kind::Line:sample_changes(now);
                    session.receive(e.text,now);
                    break;
                    case splay::TransportEvent::Kind::Closed:if(session.status()["connection"]!="error")session.disconnected();
                    break;
                    case splay::TransportEvent::Kind::Error:session.disconnected(e.text);
                    break;
                }
                if(session.status()["connection"]=="error")transport.disconnect();
            }
            bool was=session.logged();
            session.tick(now);
            if(was&&!session.logged())transport.disconnect();
        }
        transport.disconnect();
        return 0;
    }
    catch(...){
        return -1;
    }
}
