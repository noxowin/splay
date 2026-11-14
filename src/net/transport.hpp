#pragma once
#include <memory>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace splay {
enum class TlsMode { Prefer, Require, Off };
struct ConnectOptions { std::string host; int port = 8999; TlsMode tls = TlsMode::Prefer; };
struct TransportEvent {
    enum class Kind { Connected, Line, Closed, Error };
    Kind kind; std::string text; bool encrypted = false;
    uint64_t generation = 0;
    bool retryable = false;
    // std::chrono::steady_clock seconds, taken on the transport thread when
    // the event was produced: for a Line, when its bytes arrived.
    double time = 0;
};
class Transport {
public:
    Transport();
    ~Transport();
    Transport(const Transport&) = delete;
    Transport& operator=(const Transport&) = delete;
    void connect(const ConnectOptions&);
    void send_line(const std::string&);
    void disconnect();
    std::vector<TransportEvent> poll();
    // Called on the transport thread after an event is queued, so the owner
    // can wake its own loop instead of polling. Set it before connect(); it
    // must be safe to call from another thread and must not call back here.
    void on_event(std::function<void()> callback);
    uint64_t generation() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
