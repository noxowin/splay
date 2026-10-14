#include "../../src/net/transport.hpp"
#include <chrono>
#include <iostream>
#include <thread>
int main(int argc,char** argv) {
    if(argc<3) return 2;
    splay::Transport t;
    splay::ConnectOptions o; o.host="127.0.0.1"; o.port=std::stoi(argv[1]);
    std::string mode=argv[2]; o.tls=mode=="off"?splay::TlsMode::Off:mode=="require"?splay::TlsMode::Require:splay::TlsMode::Prefer;
    if(argc>3) o.host=argv[3];
    bool handshakeOnly=argc>4 && std::string(argv[4])=="handshake-only";
    bool protocolProbe=argc>4 && std::string(argv[4])=="protocol-probe";
    bool bulk=argc>4 && std::string(argv[4])=="bulk";
    t.connect(o); auto until=std::chrono::steady_clock::now()+std::chrono::seconds(handshakeOnly || protocolProbe?25:3);
    while(std::chrono::steady_clock::now()<until) {
        for(auto& e:t.poll()) {
            std::cout<<int(e.kind)<<":"<<e.encrypted<<":"<<e.text<<std::endl;
            if(e.kind==splay::TransportEvent::Kind::Connected) {
                if(handshakeOnly) { t.disconnect(); return 0; }
                if(bulk) { for(int i=0;i<50;++i) t.send_line("{\"payload\":\""+std::string(16000,'x')+"\"}"); }
                else t.send_line("{\"hello\":1}");
            }
            if(e.kind==splay::TransportEvent::Kind::Closed) return 0;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    auto start=std::chrono::steady_clock::now(); t.disconnect();
    std::cout<<"disconnect_ms:"<<std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-start).count()<<std::endl;
}
