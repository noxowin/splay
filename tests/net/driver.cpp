#include "../../src/net/transport.hpp"
#include <atomic>
#include <chrono>
#include <iostream>
#include <thread>
int main(int argc,char** argv) {
    if(argc<3) return 2;
    splay::Transport t;
    std::atomic<int> wakes{0};
    t.on_event([&]{++wakes;});
    splay::ConnectOptions o; o.host="127.0.0.1"; o.port=std::stoi(argv[1]);
    std::string mode=argv[2]; o.tls=mode=="off"?splay::TlsMode::Off:mode=="require"?splay::TlsMode::Require:splay::TlsMode::Prefer;
    if(argc>3) o.host=argv[3];
    bool handshakeOnly=argc>4 && std::string(argv[4])=="handshake-only";
    bool protocolProbe=argc>4 && std::string(argv[4])=="protocol-probe";
    bool bulk=argc>4 && std::string(argv[4])=="bulk";
    // Return every received line at once and poll without sleeping, so the
    // peer measures the transport's own send delay rather than this loop's.
    bool echo=argc>4 && std::string(argv[4])=="echo";
    auto seconds=[]{return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();};
    const double started=seconds(); double previous=started;
    t.connect(o); auto until=std::chrono::steady_clock::now()+std::chrono::seconds(handshakeOnly || protocolProbe?25:3);
    while(std::chrono::steady_clock::now()<until) {
        for(auto& e:t.poll()) {
            // The owner is told about every event. The transport queues the
            // event first and calls back right after, so this poll can see the
            // first event a moment before its wake is counted; allow for that.
            for(int waited=0;wakes.load()==0&&waited<1000;++waited) std::this_thread::sleep_for(std::chrono::milliseconds(1));
            if(wakes.load()==0) { std::cout<<"missing_wake"<<std::endl; return 4; }
            // Events carry the transport thread's own clock reading, in order.
            if(e.time<previous || e.time>seconds()) { std::cout<<"bad_event_time"<<std::endl; return 3; }
            previous=e.time;
            if(echo && e.kind==splay::TransportEvent::Kind::Line) { t.send_line(e.text); continue; }
            std::cout<<int(e.kind)<<":"<<e.encrypted<<":"<<e.text<<std::endl;
            if(e.kind==splay::TransportEvent::Kind::Connected) {
                if(handshakeOnly) { t.disconnect(); return 0; }
                if(bulk) { for(int i=0;i<50;++i) t.send_line("{\"payload\":\""+std::string(16000,'x')+"\"}"); }
                else t.send_line("{\"hello\":1}");
            }
            if(e.kind==splay::TransportEvent::Kind::Closed) return 0;
        }
        if(!echo) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    auto start=std::chrono::steady_clock::now(); t.disconnect();
    std::cout<<"disconnect_ms:"<<std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-start).count()<<std::endl;
}
