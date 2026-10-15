#pragma once
#include "../../third_party/json/json.hpp"
#include <string>

namespace splay {
    // Passwords stay native: handle() only returns endpoint metadata and saved state.
    // Files use current-user Windows DPAPI, with endpoint-bound optional entropy.
    class Credentials {
    public:
        nlohmann::json handle(const nlohmann::json& command);
        std::string password(const std::string& host,int port) const;
        static std::string normalize_host(const std::string& host);
    private:
        std::string path_;
    };
    void erase_secret(std::string& value);
}
