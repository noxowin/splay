#pragma once

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace splay {

// Only the native adapter consumes value. Never serialize it to mpv/Lua.
struct SecretResult {
    std::uint64_t id = 0;
    bool cancelled = false;
    std::string value;
    std::string error;
};

class SecretInput {
public:
    SecretInput();
    ~SecretInput();
    SecretInput(const SecretInput&) = delete;
    SecretInput& operator=(const SecretInput&) = delete;
    // Interface text is plain data for static and button controls. Empty
    // labels fall back to the built-in Chinese text.
    void request(std::uint64_t id, const std::string& title, const std::string& prompt,
                 const std::string& note = {}, const std::string& ok = {}, const std::string& cancel = {});
    std::optional<SecretResult> poll();
    void cancel();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace splay
