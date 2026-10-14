#pragma once
#include "../../third_party/json/json.hpp"
#include <string>
namespace splay {
    using Json = nlohmann::json;
    // Local non-secret connection preferences. Loading never connects to a server.
    class History {
    public:
        Json handle(const Json& command);
    private:
        std::string path_;
    };
}
