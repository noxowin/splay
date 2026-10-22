#pragma once
#include "../../third_party/json/json.hpp"
#include <string>
namespace splay {
    using Json = nlohmann::json;
    // Local non-secret connection preferences. Loading never connects to a server.
    // Profiles use the exact host/port/username/room/tls settings as identity and
    // may carry a separate display name. Management commands return the complete
    // latest snapshot and echo request_id unchanged, including on failure.
    // history-preferences merges only its whitelisted preferences object;
    // clearing connection history preserves these independent UI preferences.
    class History {
    public:
        Json handle(const Json& command);
    private:
        std::string path_;
    };
}
