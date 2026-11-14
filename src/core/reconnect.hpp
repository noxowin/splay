#pragma once
#include "../../third_party/json/json.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>

namespace splay {
// This policy has no timer thread: the adapter owns the connection and calls
// due() from its event loop. Only an explicit connect grants retry consent.
class Reconnect {
public:
    void start(bool enabled) { cancel(); active_=true; enabled_=enabled; }
    void cancel() { ++generation_; active_=false; pending_=false; attempt_=0; delay_=0; reason_.clear(); }
    void disable() { enabled_=false; pending_=false; ++generation_; }
    void enable() { enabled_=true; }
    void connected() { pending_=false; attempt_=0; delay_=0; reason_.clear(); }
    bool failed(bool transient,const std::string& reason,double now) {
        pending_=false; reason_=reason;
        if(!active_||!enabled_||!transient) { active_=false; return false; }
        if(attempt_>=5) { active_=false; reason_="Retry limit reached: "+reason; return false; }
        static constexpr int delays[]={2,5,10,30,30};
        delay_=delays[attempt_++]; deadline_=now+delay_; pending_=true;
        return true;
    }
    bool due(double now) {
        if(!pending_||!active_||!enabled_||now<deadline_)return false;
        pending_=false; return true;
    }
    // Changing rooms invalidates outstanding work without granting new consent.
    void room_changed() { ++generation_; pending_=false; attempt_=0; delay_=0; reason_.clear(); }
    uint64_t generation() const { return generation_; }
    bool pending() const { return pending_; }
    int remaining(double now) const { return pending_?std::max(0,int(std::ceil(deadline_-now))):0; }
    nlohmann::json status(double now) const {
        return {{"enabled",enabled_},{"pending",pending_},{"attempt",attempt_},
                {"delay",delay_},{"remaining",remaining(now)},{"reason",reason_}};
    }
private:
    bool active_=false,enabled_=false,pending_=false;
    uint64_t generation_=0;
    int attempt_=0,delay_=0;
    double deadline_=0;
    std::string reason_;
};
}
