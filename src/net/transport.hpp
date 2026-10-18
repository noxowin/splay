#pragma once
#include <memory>
#include <cstdint>
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
    uint64_t generation() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
