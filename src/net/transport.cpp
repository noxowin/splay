#ifndef SECURITY_WIN32
#define SECURITY_WIN32
#endif
#define _WIN32_WINNT 0x0602
#include "transport.hpp"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <security.h>
#include <schannel.h>
#include <atomic>
#include <chrono>
#include <deque>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <algorithm>
#include <cstring>

namespace splay {
namespace {
using Clock = std::chrono::steady_clock;
constexpr size_t MaxLine = 16384, MaxQueue = 1024 * 1024;
std::wstring wide(const std::string& s) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), int(s.size()), nullptr, 0);
    if (!n) throw std::runtime_error("Invalid UTF-8 hostname");
    std::wstring w(n, 0); MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), int(s.size()), w.data(), n); return w;
}
}
struct Transport::Impl {
    std::mutex mutex;
    std::deque<std::string> outgoing;
    std::vector<TransportEvent> events;
    size_t queued = 0, eventBytes = 0;
    std::thread worker;
    std::atomic<bool> stop{false};
    SOCKET sock = INVALID_SOCKET;
    CredHandle cred{}; CtxtHandle ctx{};
    bool haveCred = false, haveCtx = false, encrypted = false;
    SecPkgContext_StreamSizes sizes{};
    std::string ciphertext, plaintext;
    void emit(TransportEvent::Kind k, std::string text = {}) {
        std::lock_guard<std::mutex> lock(mutex);
        if (k != TransportEvent::Kind::Error && k != TransportEvent::Kind::Closed &&
            (eventBytes + text.size() > MaxQueue || events.size() >= 4096)) throw std::runtime_error("Incoming event queue exceeded limit");
        eventBytes += text.size(); events.push_back({k, std::move(text), encrypted});
    }
    void check(Clock::time_point deadline) {
        if (stop) throw std::runtime_error("Cancelled");
        if (Clock::now() >= deadline) throw std::runtime_error("Network operation timed out");
    }
    void ready(bool writing, Clock::time_point deadline) {
        for (;;) {
            check(deadline); fd_set f; FD_ZERO(&f); FD_SET(sock, &f); timeval tv{0, 50000};
            int r = select(0, writing ? nullptr : &f, writing ? &f : nullptr, nullptr, &tv);
            if (r > 0) return;
            if (r == SOCKET_ERROR) throw std::runtime_error("Socket wait failed");
        }
    }
    void rawSend(const std::string& data, Clock::time_point deadline) {
        size_t at = 0;
        while (at < data.size()) {
            ready(true, deadline); int n = ::send(sock, data.data() + at, int(data.size() - at), 0);
            if (n > 0) at += size_t(n);
            else if (n == 0 || WSAGetLastError() != WSAEWOULDBLOCK) throw std::runtime_error("Socket write failed");
        }
    }
    void rawRead(std::string& into, Clock::time_point deadline) {
        for (;;) {
            ready(false, deadline); char buf[32768]; int n = recv(sock, buf, sizeof(buf), 0);
            if (n > 0) { into.append(buf, n); return; }
            if (!n) throw std::runtime_error("Peer closed connection");
            if (WSAGetLastError() != WSAEWOULDBLOCK) throw std::runtime_error("Socket read failed");
        }
    }
    void dial(const ConnectOptions& o) {
        auto host = wide(o.host), service = std::to_wstring(o.port);
        ADDRINFOEXW hints{}; hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP;
        PADDRINFOEXW addresses = nullptr; OVERLAPPED ov{}; ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!ov.hEvent) throw std::runtime_error("Cannot create DNS event");
        HANDLE query = nullptr; timeval timeout{10, 0};
        using Cancel = int (WSAAPI*)(LPHANDLE);
        using Result = int (WSAAPI*)(LPOVERLAPPED);
        auto module = GetModuleHandleW(L"ws2_32.dll");
        Cancel cancel = nullptr; Result result = nullptr;
        auto cancelAddress = GetProcAddress(module, "GetAddrInfoExCancel");
        auto resultAddress = GetProcAddress(module, "GetAddrInfoExOverlappedResult");
        static_assert(sizeof(cancel) == sizeof(cancelAddress), "Windows function pointer size");
        std::memcpy(&cancel, &cancelAddress, sizeof(cancel));
        std::memcpy(&result, &resultAddress, sizeof(result));
        if (!cancel || !result) { CloseHandle(ov.hEvent); throw std::runtime_error("Asynchronous DNS unavailable"); }
        int rc = GetAddrInfoExW(host.c_str(), service.c_str(), NS_DNS, nullptr, &hints, &addresses, &timeout, &ov, nullptr, &query);
        if (rc == WSA_IO_PENDING) {
            auto until = Clock::now() + std::chrono::seconds(10);
            while (WaitForSingleObject(ov.hEvent, 50) == WAIT_TIMEOUT) {
                if (stop || Clock::now() >= until) { cancel(&query); break; }
            }
            // Cancellation completion owns the OVERLAPPED storage until signalled.
            WaitForSingleObject(ov.hEvent, INFINITE); rc = result(&ov);
        }
        CloseHandle(ov.hEvent);
        struct Free { PADDRINFOEXW p; ~Free(){ if(p) FreeAddrInfoExW(p); } } free{addresses};
        if (rc || stop) throw std::runtime_error("DNS lookup failed or cancelled");
        auto until = Clock::now() + std::chrono::seconds(10);
        for (auto a = addresses; a; a = a->ai_next) {
            check(until); sock = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
            if (sock == INVALID_SOCKET) continue;
            u_long nonblock = 1; ioctlsocket(sock, FIONBIO, &nonblock);
            int r = ::connect(sock, a->ai_addr, int(a->ai_addrlen));
            if (!r) return;
            if (WSAGetLastError() == WSAEWOULDBLOCK) {
                // Winsock reports refused asynchronous connections through
                // exceptfds, rather than writefds. Consume SO_ERROR and try
                // the next resolved address under the same deadline.
                for (;;) {
                    check(until);
                    fd_set writable, failed;
                    FD_ZERO(&writable); FD_SET(sock, &writable);
                    FD_ZERO(&failed); FD_SET(sock, &failed);
                    timeval tv{0, 50000};
                    int waiting = select(0, nullptr, &writable, &failed, &tv);
                    if (waiting == SOCKET_ERROR) throw std::runtime_error("Socket connect wait failed");
                    if (waiting > 0) break;
                }
                int err = 0, len = sizeof(err);
                if (!getsockopt(sock, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&err), &len) && !err) return;
            }
            closesocket(sock); sock = INVALID_SOCKET;
        }
        throw std::runtime_error("TCP connection failed");
    }
    void tls(const std::string& hostname) {
        SCHANNEL_CRED settings{}; settings.dwVersion = SCHANNEL_CRED_VERSION;
        settings.grbitEnabledProtocols = SP_PROT_TLS1_2_CLIENT;
        // Cached chain/revocation data prevents certificate validation from doing
        // uninterruptible network retrieval on the transport worker.
        settings.dwFlags = SCH_CRED_AUTO_CRED_VALIDATION | SCH_CRED_NO_DEFAULT_CREDS | SCH_CRED_CACHE_ONLY_URL_RETRIEVAL;
        TimeStamp expiry{};
        auto credentialStatus = AcquireCredentialsHandleW(nullptr, const_cast<wchar_t*>(UNISP_NAME_W), SECPKG_CRED_OUTBOUND, nullptr, &settings, nullptr, nullptr, &cred, &expiry);
        if (credentialStatus != SEC_E_OK) throw std::runtime_error("TLS credentials failed (" + std::to_string(static_cast<unsigned long>(credentialStatus)) + ")");
        haveCred = true; auto host = wide(hostname); auto until = Clock::now() + std::chrono::seconds(15);
        bool first = true;
        for (;;) {
            check(until);
            SecBuffer in[2]{{static_cast<unsigned long>(ciphertext.size()), SECBUFFER_TOKEN, ciphertext.empty() ? nullptr : ciphertext.data()}, {0, SECBUFFER_EMPTY, nullptr}};
            SecBufferDesc input{SECBUFFER_VERSION, 2, in};
            SecBuffer out{0, SECBUFFER_TOKEN, nullptr}; SecBufferDesc output{SECBUFFER_VERSION, 1, &out}; ULONG attrs = 0;
            SECURITY_STATUS status = InitializeSecurityContextW(&cred, first ? nullptr : &ctx, host.data(), ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT | ISC_REQ_CONFIDENTIALITY | ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM, 0, SECURITY_NATIVE_DREP, first ? nullptr : &input, 0, &ctx, &output, &attrs, &expiry);
            if (status == SEC_E_OK || status == SEC_I_CONTINUE_NEEDED || status == SEC_E_INCOMPLETE_MESSAGE) haveCtx = true;
            if (out.pvBuffer) { std::string token(static_cast<char*>(out.pvBuffer), out.cbBuffer); FreeContextBuffer(out.pvBuffer); rawSend(token, until); }
            if (status == SEC_E_INCOMPLETE_MESSAGE) { rawRead(ciphertext, until); if(ciphertext.size()>262144) throw std::runtime_error("TLS handshake exceeded limit"); continue; }
            first = false;
            if (status != SEC_E_OK && status != SEC_I_CONTINUE_NEEDED) throw std::runtime_error("TLS handshake or certificate validation failed");
            if (in[1].BufferType == SECBUFFER_EXTRA) ciphertext.erase(0, ciphertext.size() - in[1].cbBuffer); else ciphertext.clear();
            if (status == SEC_E_OK) break;
            if (ciphertext.empty()) rawRead(ciphertext, until);
        }
        if (QueryContextAttributes(&ctx, SECPKG_ATTR_STREAM_SIZES, &sizes) != SEC_E_OK) throw std::runtime_error("TLS stream setup failed");
        encrypted = true;
    }
    void write(const std::string& data) {
        auto until = Clock::now() + std::chrono::seconds(10);
        if (!encrypted) { rawSend(data, until); return; }
        for (size_t at = 0; at < data.size();) {
            size_t count = std::min<size_t>(sizes.cbMaximumMessage, data.size()-at);
            std::string record(sizes.cbHeader + count + sizes.cbTrailer, 0);
            std::copy_n(data.data()+at, count, record.data()+sizes.cbHeader);
            SecBuffer b[4]{{sizes.cbHeader, SECBUFFER_STREAM_HEADER, record.data()}, {static_cast<unsigned long>(count), SECBUFFER_DATA, record.data()+sizes.cbHeader}, {sizes.cbTrailer, SECBUFFER_STREAM_TRAILER, record.data()+sizes.cbHeader+count}, {0,SECBUFFER_EMPTY,nullptr}};
            SecBufferDesc d{SECBUFFER_VERSION,4,b};
            if (EncryptMessage(&ctx,0,&d,0)!=SEC_E_OK) throw std::runtime_error("TLS encryption failed");
            record.resize(b[0].cbBuffer+b[1].cbBuffer+b[2].cbBuffer); rawSend(record,until); at+=count;
        }
    }
    void read(Clock::time_point until) {
        if (!encrypted) { rawRead(plaintext,until); return; }
        for (;;) {
            if(ciphertext.empty()) rawRead(ciphertext,until);
            SecBuffer b[4]{{static_cast<unsigned long>(ciphertext.size()),SECBUFFER_DATA,ciphertext.data()},{0,SECBUFFER_EMPTY,nullptr},{0,SECBUFFER_EMPTY,nullptr},{0,SECBUFFER_EMPTY,nullptr}};
            SecBufferDesc d{SECBUFFER_VERSION,4,b}; auto status=DecryptMessage(&ctx,&d,0,nullptr);
            if(status==SEC_E_INCOMPLETE_MESSAGE) { rawRead(ciphertext,until); if(ciphertext.size()>262144) throw std::runtime_error("TLS record exceeded limit"); continue; }
            if(status!=SEC_E_OK) throw std::runtime_error("TLS stream closed or decryption failed");
            size_t extra=0;
            for(auto& v:b) { if(v.BufferType==SECBUFFER_DATA) plaintext.append(static_cast<char*>(v.pvBuffer),v.cbBuffer); if(v.BufferType==SECBUFFER_EXTRA) extra=v.cbBuffer; }
            ciphertext.erase(0,ciphertext.size()-extra); return;
        }
    }
    bool line(std::string& result) {
        auto end=plaintext.find('\n');
        if(end==std::string::npos) { if(plaintext.size()>MaxLine+1) throw std::runtime_error("Protocol line exceeded 16384 bytes"); return false; }
        size_t size=end; if(size && plaintext[size-1]=='\r') --size;
        if(size>MaxLine) throw std::runtime_error("Protocol line exceeded 16384 bytes");
        result=plaintext.substr(0,size); plaintext.erase(0,end+1);
        if(!result.empty() && !MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,result.data(),int(result.size()),nullptr,0)) throw std::runtime_error("Invalid UTF-8 protocol line");
        return true;
    }
    void run(ConnectOptions o) {
        const char* phase = "TCP/DNS";
        try {
            if(o.host.empty() || o.host.size()>253 || o.host.find('\0')!=std::string::npos || o.port<1 || o.port>65535) throw std::runtime_error("Invalid connection options");
            dial(o);
            if(o.tls!=TlsMode::Off) {
                phase = "STARTTLS negotiation";
                write("{\"TLS\":{\"startTLS\":\"send\"}}\r\n");
                auto until=Clock::now()+std::chrono::seconds(10); std::string response;
                while(!line(response)) read(until);
                // Strict fixed-shape response; arbitrary JSON is handled by the protocol layer.
                std::string compact; bool quoted=false, escaped=false;
                for(char c:response) { if(c=='"' && !escaped) quoted=!quoted; if(quoted || (c!=' ' && c!='\t' && c!='\r')) compact+=c; escaped=(c=='\\' && !escaped); }
                if(compact=="{\"TLS\":{\"startTLS\":\"true\"}}") { phase="TLS handshake"; ciphertext.swap(plaintext); tls(o.host); }
                else if(compact=="{\"TLS\":{\"startTLS\":\"false\"}}" && o.tls==TlsMode::Prefer) {}
                else throw std::runtime_error("Server rejected TLS or sent invalid TLS response");
            }
            emit(TransportEvent::Kind::Connected);
            phase = "Protocol stream";
            auto partialUntil=Clock::time_point::max();
            while(!stop) {
                std::deque<std::string> batch;
                { std::lock_guard<std::mutex> lock(mutex); batch.swap(outgoing); queued=0; }
                for(auto& s:batch) write(s);
                std::string message; while(line(message)) emit(TransportEvent::Kind::Line,std::move(message));
                if(plaintext.empty() && ciphertext.empty()) partialUntil=Clock::time_point::max();
                else if(partialUntil==Clock::time_point::max()) partialUntil=Clock::now()+std::chrono::seconds(15);
                check(partialUntil);
                fd_set f; FD_ZERO(&f); FD_SET(sock,&f); timeval tv{0,50000}; int r=select(0,&f,nullptr,nullptr,&tv);
                if(r==SOCKET_ERROR) throw std::runtime_error("Socket read wait failed");
                if(r>0 || !ciphertext.empty()) read(std::min(partialUntil,Clock::now()+std::chrono::seconds(15)));
            }
        } catch(const std::exception& e) {
            if(!stop) { try { emit(TransportEvent::Kind::Error,std::string(phase)+": "+e.what()); } catch(...) {} }
        }
        if(haveCtx) DeleteSecurityContext(&ctx);
        if(haveCred) FreeCredentialsHandle(&cred);
        if(sock!=INVALID_SOCKET) closesocket(sock);
        sock=INVALID_SOCKET; haveCtx=haveCred=false;
        if(!stop) { try { emit(TransportEvent::Kind::Closed); } catch(...) {} }
    }
};
Transport::Transport():impl_(new Impl) { WSADATA w{}; if(WSAStartup(MAKEWORD(2,2),&w)) throw std::runtime_error("Winsock initialization failed"); }
Transport::~Transport() { disconnect(); WSACleanup(); }
void Transport::disconnect() { impl_->stop=true; if(impl_->worker.joinable()) impl_->worker.join(); std::lock_guard<std::mutex> lock(impl_->mutex); impl_->outgoing.clear(); impl_->events.clear(); impl_->queued=impl_->eventBytes=0; }
void Transport::connect(const ConnectOptions& o) { disconnect(); impl_->plaintext.clear(); impl_->ciphertext.clear(); impl_->encrypted=false; impl_->stop=false; impl_->worker=std::thread([this,o]{impl_->run(o);}); }
void Transport::send_line(const std::string& s) {
    std::string line=s;
    if(line.size()>=2 && line.compare(line.size()-2,2,"\r\n")==0) line.resize(line.size()-2);
    if(line.size()>MaxLine || line.find_first_of("\r\n")!=std::string::npos) throw std::runtime_error("Invalid outgoing protocol line");
    if(!line.empty() && !MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,line.data(),int(line.size()),nullptr,0)) throw std::runtime_error("Invalid outgoing UTF-8");
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if(impl_->stop || !impl_->worker.joinable()) return;
    if(impl_->queued+line.size()+2>MaxQueue) throw std::runtime_error("Outgoing queue exceeded limit");
    impl_->queued+=line.size()+2; impl_->outgoing.push_back(line+"\r\n");
}
std::vector<TransportEvent> Transport::poll() { std::lock_guard<std::mutex> lock(impl_->mutex); std::vector<TransportEvent> out; out.swap(impl_->events); impl_->eventBytes=0; return out; }
}
