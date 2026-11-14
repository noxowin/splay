#define MPV_CPLUGIN_DYNAMIC_SYM
#include "../../third_party/mpv/client.h"
#include "../core/session.hpp"
#include "../core/media_name.hpp"
#include "../core/history.hpp"
#include "../core/credentials.hpp"
#include "../core/reconnect.hpp"
#include "../net/transport.hpp"
#include "secret_input.hpp"
#include <windows.h>
#include <bcrypt.h>
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
    std::string get_text(mpv_handle* h,const char* property){
        char* value=mpv_get_property_string(h,property);
        if(!value)return {};
        std::string result(value);
        mpv_free(value);
        return result;
    }
    std::string secret_token(){
        unsigned char bytes[16];
        if(BCryptGenRandom(nullptr,bytes,sizeof(bytes),BCRYPT_USE_SYSTEM_PREFERRED_RNG)!=0)throw std::runtime_error("Cannot create password token");
        std::string value;
        for(auto ch:bytes){value+="0123456789abcdef"[ch>>4];value+="0123456789abcdef"[ch&15];}
        return value;
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
        // mpv_wakeup is thread-safe and is the only mpv call made from the
        // transport thread: it ends the wait below when a line arrives.
        transport.on_event([h]{mpv_wakeup(h);});
        splay::Session session;
        splay::History history;
        splay::Credentials credentials;
        splay::Reconnect reconnect;
        splay::SecretInput secret_input;
        splay::ConnectOptions connection_options;
        struct PendingSecret { uint64_t id,generation; splay::Json command; std::string room; };
        std::optional<PendingSecret> pending_secret;
        struct PasswordToken {
            std::string token,host,value; int port=8999; double expires=0;
            void clear(){splay::erase_secret(value);token.clear();host.clear();expires=0;}
            ~PasswordToken(){clear();}
        } password_token;
        double suppress_until=0,next_sample=0;
        bool pending_seek=false;
        // The plugin can attach to an existing player. Bootstrap only from a
        // demuxer that is already loaded; later files require FILE_LOADED.
        bool loading=get_flag(h,"idle-active",true)||get_text(h,"file-format").empty();
        std::string loaded_path=loading?std::string():get_text(h,"path");
        std::string public_name,pending_name;
        double pending_name_since=0;
        std::optional<double> expected_seek;
        std::optional<bool> expected_pause;
        bool running=true,have_previous=false;
        int last_remaining=-1;
        splay::Playback previous;
        // The core reports a change for every server heartbeat. Forward a
        // state only when its content differs from the last delivered one, so
        // steady playback does not make the interface re-parse and redraw.
        std::string published_state;
        auto publish_state=[&](bool force){
            auto state=session.status();
            state["reconnect"]=reconnect.status(clock_now());
            auto payload=state.dump(-1,' ',false,splay::Json::error_handler_t::replace);
            if(!force&&payload==published_state)return;
            const char* args[]={"script-message-to","splay","splay-state",payload.c_str(),nullptr};
            // Remember only a delivered state: the interface may not be loaded yet.
            if(mpv_command(h,args)>=0)published_state=std::move(payload);
            else published_state.clear();
        };
        auto publish=[&](){publish_state(false);};
        auto publish_credential=[&](const splay::Json& result){
            auto payload=result.dump(-1,' ',false,splay::Json::error_handler_t::replace);
            const char* args[]={"script-message-to","splay","splay-credential",payload.c_str(),nullptr};
            mpv_command(h,args);
        };
        auto publish_secret=[&](const splay::Json& result){
            auto payload=result.dump(-1,' ',false,splay::Json::error_handler_t::replace);
            const char* args[]={"script-message-to","splay","splay-secret",payload.c_str(),nullptr};
            mpv_command(h,args);
        };
        auto cancel_secret=[&](){
            secret_input.cancel();
            if(pending_secret){
                publish_secret({{"request_id",pending_secret->id},{"purpose",pending_secret->command["purpose"]},{"cancelled",true}});
                pending_secret.reset();
            }
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
            // Pause before a boundary seek; resume only after restoring a
            // valid position, so an old endpoint cannot race into EOF.
            if(c.paused&&*c.paused){
                expected_pause=c.paused;
                int p=*c.paused;
                mpv_set_property(h,"pause",MPV_FORMAT_FLAG,&p);
            }
            if(c.position){
                expected_seek=c.position;
                double p=*c.position;
                mpv_set_property(h,"time-pos",MPV_FORMAT_DOUBLE,&p);
            }
            if(c.paused&&!*c.paused){
                expected_pause=c.paused;
                int p=0;
                mpv_set_property(h,"pause",MPV_FORMAT_FLAG,&p);
            }
        };
        auto sample=[&](){
            splay::Playback p;
            const auto path=get_text(h,"path");
            p.loaded=!loading&&!loaded_path.empty()&&path==loaded_path&&
                !get_flag(h,"idle-active",true)&&!get_flag(h,"eof-reached");
            p.position=get_number(h,"time-pos");
            p.duration=get_number(h,"duration");
            p.paused=get_flag(h,"pause",true);
            p.buffering=get_flag(h,"paused-for-cache")||get_flag(h,"seeking");
            p.seekable=get_flag(h,"seekable");
            p.speed=get_number(h,"speed",1);
            if(p.loaded){
                std::string name;
                const bool network=splay::network_media_path(path)||get_flag(h,"demuxer-via-network");
                if(!network)name=splay::local_media_name(path);
                else{
                    const auto filename=get_text(h,"filename"),stem=get_text(h,"filename/no-ext");
                    // Metadata and media-title belong to the loaded demuxer.
                    // Never derive a network title from path or URL segments.
                    name=splay::network_media_name(get_text(h,"metadata/by-key/title"),filename,stem,true);
                    if(name.empty())name=splay::network_media_name(get_text(h,"metadata/by-key/TITLE"),filename,stem,true);
                    if(name.empty())name=splay::network_media_name(get_text(h,"media-title"),filename,stem);
                }
                const double sampled_at=clock_now();
                if(name!=pending_name){pending_name=name;pending_name_since=sampled_at;}
                // Metadata can arrive after FILE_LOADED or fluctuate during
                // probing. Publish only stable changes, once per new value.
                if(!network||sampled_at-pending_name_since>=.5)public_name=pending_name;
                p.public_name=public_name;
                if(get_text(h,"path")!=path){p.loaded=false;p.public_name.clear();}
            }
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
            // With no connection, retry, password prompt or local offset, only
            // an mpv event can change anything: wait for one instead of waking
            // 33 times a second in every player that merely has splay installed.
            // The one-second bound only expires a held password token.
            auto quiet=[&]{return session.idle()&&!reconnect.pending()&&!pending_secret;};
            auto* event=mpv_wait_event(h,quiet()?1.0:.03);
            // Read the clock after the wait: everything below happens now.
            const double now=clock_now();
            if(event->event_id==MPV_EVENT_SHUTDOWN)break;
            try{
            if(event->event_id==MPV_EVENT_START_FILE || event->event_id==MPV_EVENT_END_FILE){
                loading=true;
                loaded_path.clear();public_name.clear();pending_name.clear();pending_name_since=now;
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
                loaded_path=get_text(h,"path");
                public_name.clear();pending_name.clear();pending_name_since=now;
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
                        struct CommandSecretGuard {
                            splay::Json& value;
                            ~CommandSecretGuard(){
                                if(value.contains("password")&&value["password"].is_string())splay::erase_secret(value["password"].get_ref<std::string&>());
                            }
                        } command_guard{c};
                        auto action=text(c,"action",32);
                        if(action.rfind("history-",0)==0){
                            splay::Json result;
                            try{result=history.handle(c);}
                            catch(const std::exception& exception){result={{"schema",1},{"error",exception.what()}};}
                            catch(...){result={{"schema",1},{"error","History operation failed"}};}
                            if(c.contains("request_id"))result["request_id"]=c["request_id"];
                            auto payload=result.dump(-1,' ',false,splay::Json::error_handler_t::replace);
                            const char* args[]={"script-message-to","splay","splay-history",payload.c_str(),nullptr};
                            mpv_command(h,args);
                        }
                        else if(action=="credential-init"||action=="credential-status"||action=="credential-save"||action=="credential-delete"){
                            auto result=credentials.handle(c);
                            if(c.contains("request_id")&&c["request_id"].is_number_integer())result["request_id"]=c["request_id"];
                            publish_credential(result);
                        }
                        else if(action=="status")publish_state(true);
                        else if(action=="secret-cancel"){
                            if(!c.contains("request_id")||(pending_secret&&c["request_id"]==pending_secret->id))cancel_secret();
                            password_token.clear();
                        }
                        else if(action=="password-clear"){
                            cancel_secret();password_token.clear();session.forget_password();
                        }
                        else if(action=="secret-input"){
                            try{
                            cancel_secret();
                            auto purpose=text(c,"purpose",32);
                            if(purpose!="server"&&purpose!="operator"&&purpose!="create_room")throw std::runtime_error("Invalid password purpose");
                            if(!c.contains("request_id")||!c["request_id"].is_number_unsigned())throw std::runtime_error("Invalid password request id");
                            if(purpose=="server"){
                                c["host"]=splay::Credentials::normalize_host(text(c,"host",1024));
                                if(!c.contains("port")||!c["port"].is_number_integer()||c["port"].get<long long>()<1||c["port"].get<long long>()>65535)throw std::runtime_error("Invalid port");
                                if(c.contains("remember_password")&&!c["remember_password"].is_boolean())throw std::runtime_error("Invalid remember password setting");
                            }
                            else if(!session.logged())throw std::runtime_error("Connect before entering an operator password");
                            if(purpose=="create_room")text(c,"room",256);
                            cancel_secret();
                            password_token.clear();
                            const auto id=c["request_id"].get<uint64_t>();
                            secret_input.request(id,text(c,"title",256,true),text(c,"prompt",1024,true));
                            pending_secret=PendingSecret{id,reconnect.generation(),c,session.room()};
                            }catch(const std::exception& exception){
                                cancel_secret();
                                publish_secret({{"request_id",c.value("request_id",splay::Json())},
                                    {"purpose",c.contains("purpose")&&c["purpose"].is_string()?c["purpose"]:splay::Json("")},
                                    {"cancelled",false},{"error",exception.what()}});
                            }
                        }
                        else if(action=="reconnect-disable"){
                            reconnect.disable();
                            publish();
                        }
                        else if(action=="reconnect-enable"){
                            reconnect.enable();
                            publish();
                        }
                        else if(action=="disconnect"){
                            reconnect.cancel();
                            cancel_secret();
                            password_token.clear();
                            transport.disconnect();
                            session.disconnected();
                            have_previous=false;
                            pending_seek=false;
                            expected_seek.reset();
                            expected_pause.reset();
                        }
                        else if(action=="connect"){
                            auto host=splay::Credentials::normalize_host(text(c,"host",1024)),user=text(c,"username",128),room=text(c,"room",256),tls=text(c,"tls",16,true);
                            auto pw=text(c,"password",1024,true);
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
                            const auto token=text(c,"password_token",128,true);
                            bool reuse_password=false;
                            if(!token.empty()){
                                if(!pw.empty())throw std::runtime_error("Use only one password source");
                                if(password_token.token!=token||password_token.host!=host||password_token.port!=port||password_token.expires<now)throw std::runtime_error("Password entry expired; enter it again");
                                pw.swap(password_token.value);
                                password_token.clear();
                            }
                            else if(pw.empty()&&c.value("use_saved_password",false))pw=credentials.password(host,port);
                            else if(!pw.empty()&&c.value("remember_password",false)){
                                auto save=splay::Json{{"action","credential-save"},{"host",host},{"port",port},{"password",pw}};
                                const auto result=credentials.handle(save);
                                splay::erase_secret(save["password"].get_ref<std::string&>());
                                publish_credential(result);
                                if(result.contains("error"))throw std::runtime_error(result["error"].get<std::string>());
                            }
                            else if(pw.empty())reuse_password=c.value("reuse_password",false);
                            if(c.contains("auto_reconnect")&&!c["auto_reconnect"].is_boolean())throw std::runtime_error("Invalid reconnect setting");
                            if(reuse_password&&!session.can_reuse_password(host,port))throw std::runtime_error("Password entry expired; enter it again");
                            reconnect.start(c.value("auto_reconnect",false));
                            cancel_secret();
                            password_token.clear();
                            transport.disconnect();
                            pending_seek=false;
                            expected_seek.reset();
                            expected_pause.reset();
                            sample();
                            session.configure(host,port,user,room,pw,reuse_password);
                            connection_options={host,port,mode};
                            transport.connect(connection_options);
                            have_previous=false;
                            suppress_until=now+1;
                        }
                        else {
                            if(action=="room"){
                                if(!session.logged()){
                                    reconnect.cancel();cancel_secret();transport.disconnect();session.disconnected();
                                    throw std::runtime_error("Connect before changing rooms");
                                }
                                reconnect.room_changed();
                                cancel_secret();
                                password_token.clear();
                            }
                            if(action=="set-offset")sample();
                            session.command(c,now);
                        }
                    }
                    catch(const std::exception& exception){
                        auto payload=session.status();
                        payload["reconnect"]=reconnect.status(now);
                        payload["error"]=dynamic_cast<const std::runtime_error*>(&exception)?exception.what():"Invalid command JSON";
                        auto data=payload.dump(-1,' ',false,splay::Json::error_handler_t::replace);
                        const char* a[]={"script-message-to","splay","splay-state",data.c_str(),nullptr};
                        mpv_command(h,a);
                        // The interface now shows this error; let the next
                        // regular state replace it even if nothing else changed.
                        published_state.clear();
                    }
                }
            }
            // Evaluated again: the event above may have been a connect or
            // offset command. While quiet nothing consumes the samples; drop
            // the comparison baseline so a later connection starts afresh.
            if(quiet()){
                have_previous=false;pending_seek=false;
                expected_seek.reset();expected_pause.reset();
            }
            else if(now>=next_sample){
                sample_changes(now);
                next_sample=now+.1;
            }
            if(auto result=secret_input.poll()){
                struct SecretGuard {std::string& value;~SecretGuard(){splay::erase_secret(value);}} guard{result->value};
                if(pending_secret&&result->id==pending_secret->id){
                    auto request=std::move(*pending_secret); pending_secret.reset();
                    const auto purpose=request.command["purpose"].get<std::string>();
                    splay::Json response={{"request_id",result->id},{"purpose",purpose},{"cancelled",result->cancelled}};
                    if(request.generation!=reconnect.generation()||
                        (purpose!="server"&&(!session.logged()||request.room!=session.room())))response["cancelled"]=true;
                    else if(!result->error.empty())response["error"]=result->error;
                    else if(!result->cancelled){
                        try{
                            if(result->value.size()>1024||result->value.find_first_of("\r\n")!=std::string::npos||result->value.find('\0')!=std::string::npos)throw std::runtime_error("Invalid password text");
                            if(!result->value.empty()&&!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,result->value.data(),int(result->value.size()),nullptr,0))throw std::runtime_error("Invalid password text");
                            if(purpose=="server"){
                                auto host=request.command["host"].get<std::string>();
                                auto port=request.command["port"].get<int>();
                                if(request.command.value("remember_password",false)){
                                    auto save=splay::Json{{"action","credential-save"},{"host",host},{"port",port},{"password",result->value}};
                                    auto saved=credentials.handle(save);
                                    splay::erase_secret(save["password"].get_ref<std::string&>());
                                    publish_credential(saved);
                                    if(saved.contains("error"))throw std::runtime_error(saved["error"].get<std::string>());
                                    response["saved"]=true;
                                }
                                password_token.clear();
                                password_token.token=secret_token(); password_token.host=host; password_token.port=port;
                                password_token.value.swap(result->value); password_token.expires=now+300;
                                response["token"]=password_token.token;
                            }
                            else{
                                auto command=splay::Json{{"action",purpose=="operator"?"authenticate":"create-room"},{"password",result->value}};
                                if(purpose=="create_room")command["room"]=request.command["room"];
                                try{session.command(command);}catch(...){splay::erase_secret(command["password"].get_ref<std::string&>());throw;}
                                splay::erase_secret(command["password"].get_ref<std::string&>());
                            }
                        }catch(const std::exception& exception){response["error"]=exception.what();}
                    }
                    publish_secret(response);
                }
            }
            if(password_token.expires&&now>=password_token.expires)password_token.clear();
            // Transport generations and terminating the current batch together
            // prevent Closed/old lines from overwriting a newly scheduled retry.
            for(auto& e:transport.poll()){
                if(e.generation!=transport.generation())continue;
                bool terminal=false;
                switch(e.kind){
                    case splay::TransportEvent::Kind::Connected:session.connected(e.encrypted,now);
                    break;
                    case splay::TransportEvent::Kind::Line:sample_changes(now);
                    {const bool logged=session.logged();
                    session.receive(e.text,now,e.time);
                    if(!logged&&session.logged()){reconnect.connected();publish();}}
                    break;
                    case splay::TransportEvent::Kind::Closed:session.disconnected("Connection closed",true);terminal=true;
                    break;
                    case splay::TransportEvent::Kind::Error:session.disconnected(e.text,e.retryable);terminal=true;
                    break;
                }
                if(terminal||session.connection()=="error"){
                    reconnect.failed(session.retryable(),session.error(),now);
                    cancel_secret();
                    transport.disconnect();
                    publish();
                    break;
                }
            }
            const bool failed_before_tick=session.connection()=="error";
            session.tick(now);
            if(!failed_before_tick&&session.connection()=="error"){
                reconnect.failed(session.retryable(),session.error(),now);
                cancel_secret(); transport.disconnect(); publish();
            }
            if(reconnect.due(now)){
                pending_seek=false;expected_seek.reset();expected_pause.reset();have_previous=false;
                sample();session.reconnect();transport.connect(connection_options);suppress_until=now+1;publish();
            }
            const auto remaining=reconnect.remaining(now);
            if(remaining!=last_remaining){last_remaining=remaining;publish();}
            }
            catch(const std::exception& exception){
                // A failure outside command handling must not end this thread:
                // the interface would stay loaded with no core behind it. Drop
                // the connection, show the reason and keep serving commands.
                reconnect.cancel();cancel_secret();password_token.clear();
                transport.disconnect();
                have_previous=false;pending_seek=false;
                expected_seek.reset();expected_pause.reset();
                session.disconnected(std::string("Internal error: ")+exception.what());
            }
        }
        reconnect.cancel();cancel_secret();password_token.clear();session.forget_password();
        transport.disconnect();
        return 0;
    }
    catch(...){
        return -1;
    }
}
