#include "secret_input.hpp"

#include <deque>
#include <cstring>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

namespace splay {
namespace {
void wipe(std::string& value) {
    if (!value.empty()) {
#ifdef _WIN32
        SecureZeroMemory(value.data(), value.size());
#else
        volatile char* p = value.data();
        for (std::size_t i = 0; i < value.size(); ++i) p[i] = 0;
#endif
    }
    value.clear();
}
}

struct SecretInput::Impl {
    struct Request { std::uint64_t id; std::string title, prompt, note, ok, cancel; };
    std::mutex mutex;
    std::optional<Request> pending;
    std::deque<SecretResult> results;
    bool cancelling = false, stopping = false;
#ifdef _WIN32
    HANDLE wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    std::thread worker;
    HWND window = nullptr, edit = nullptr, owner = nullptr;
    HFONT font = nullptr;
    std::uint64_t active_id = 0;
    static constexpr int max_units = 1024;

    Impl() {
        if (wake) worker = std::thread([this] { run(); });
    }
    ~Impl() {
        { std::lock_guard<std::mutex> lock(mutex); stopping = true; pending.reset(); }
        if (wake) SetEvent(wake);
        if (worker.joinable()) worker.join();
        if (wake) CloseHandle(wake);
        for (auto& result : results) wipe(result.value);
    }
    static std::wstring wide(const std::string& value) {
        const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                                            static_cast<int>(value.size()), nullptr, 0);
        if (size <= 0) return {};
        std::wstring result(size, L'\0');
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), result.data(), size);
        return result;
    }
    static std::wstring label(const std::string& value, const wchar_t* fallback) {
        auto text = wide(value);
        return text.empty() ? std::wstring(fallback) : text;
    }
    void result(SecretResult value) {
        std::lock_guard<std::mutex> lock(mutex);
        // Replacing or abandoning inputs must not leave unconsumed secrets behind.
        for (auto& old : results) wipe(old.value);
        results.clear();
        results.push_back(std::move(value));
    }
    void finish(bool cancelled) {
        if (!window) return;
        SecretResult value;
        value.id = active_id;
        value.cancelled = cancelled;
        if (!cancelled) {
            const int length = GetWindowTextLengthW(edit);
            std::vector<wchar_t> buffer(static_cast<std::size_t>(length) + 1, L'\0');
            GetWindowTextW(edit, buffer.data(), static_cast<int>(buffer.size()));
            const int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                buffer.data(), length, nullptr, 0, nullptr, nullptr);
            if ((length && bytes <= 0) || bytes > 1024) value.error = "Password must be valid Unicode and at most 1024 UTF-8 bytes";
            else if (bytes) {
                // Avoid small-string copies of short passwords during result moves.
                value.value.reserve(1025);
                value.value.resize(bytes);
                WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, buffer.data(), length,
                    value.value.data(), bytes, nullptr, nullptr);
            }
            SecureZeroMemory(buffer.data(), buffer.size() * sizeof(wchar_t));
        }
        SetWindowTextW(edit, L"");
        const HWND closing = window;
        window = nullptr; edit = nullptr;
        DestroyWindow(closing);
        if (font) { DeleteObject(font); font = nullptr; }
        if (!background && owner && IsWindow(owner)) SetForegroundWindow(owner);
        result(std::move(value));
    }
    // A launcher that starts the player with a no-activate show command has
    // asked for its windows to stay out of the foreground. The box then opens
    // without taking it and waits to be clicked; the test harnesses rely on
    // this. "Run minimized" shortcuts use a different command and are not
    // affected.
    static bool background_start() {
        STARTUPINFOW info{}; info.cb = sizeof(info);
        GetStartupInfoW(&info);
        return (info.dwFlags & STARTF_USESHOWWINDOW) &&
               (info.wShowWindow == SW_SHOWNOACTIVATE || info.wShowWindow == SW_SHOWNA);
    }
    const bool background = background_start();
    static LRESULT CALLBACK procedure(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        auto self = reinterpret_cast<Impl*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (message == WM_NCCREATE) {
            self = static_cast<Impl*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
        }
        if (self) {
            if (message == WM_CLOSE) { self->finish(true); return 0; }
            if (message == WM_COMMAND && (LOWORD(wparam) == IDOK || LOWORD(wparam) == IDCANCEL)) {
                self->finish(LOWORD(wparam) == IDCANCEL); return 0;
            }
            if (message == WM_SETFOCUS && self->edit) { SetFocus(self->edit); return 0; }
        }
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    static BOOL CALLBACK find_owner(HWND hwnd, LPARAM pointer) {
        DWORD pid = 0; GetWindowThreadProcessId(hwnd, &pid);
        if (pid != GetCurrentProcessId() || !IsWindowVisible(hwnd) || GetWindow(hwnd, GW_OWNER)) return TRUE;
        wchar_t name[128]{}; GetClassNameW(hwnd, name, 128);
        if (std::wstring(name) == L"splay.SecretInput") return TRUE;
        *reinterpret_cast<HWND*>(pointer) = hwnd;
        return FALSE;
    }
    void open(const Request& request) {
        active_id = request.id;
        owner = nullptr;
        EnumWindows(find_owner, reinterpret_cast<LPARAM>(&owner));
        using DpiFunction = UINT(WINAPI*)(HWND);
        const auto address = GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForWindow");
        DpiFunction dpi_function = nullptr;
        static_assert(sizeof(address) == sizeof(dpi_function));
        std::memcpy(&dpi_function, &address, sizeof(address));
        const UINT dpi = owner && dpi_function ? dpi_function(owner) : 96;
        const auto scale = [dpi](int value) { return MulDiv(value, static_cast<int>(dpi), 96); };
        RECT bounds{0, 0, scale(520), scale(190)};
        constexpr DWORD style = WS_POPUP | WS_CAPTION | WS_SYSMENU;
        AdjustWindowRectEx(&bounds, style, FALSE, WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT);
        const int width = bounds.right - bounds.left, height = bounds.bottom - bounds.top;
        RECT parent{};
        if (!owner || !GetWindowRect(owner, &parent)) {
            SystemParametersInfoW(SPI_GETWORKAREA, 0, &parent, 0);
        }
        window = CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, L"splay.SecretInput",
            wide(request.title).c_str(), style, parent.left + (parent.right-parent.left-width)/2,
            parent.top + (parent.bottom-parent.top-height)/2, width, height, owner, nullptr,
            GetModuleHandleW(nullptr), this);
        if (!window) { result({request.id, false, {}, "Could not create the Windows password dialog"}); return; }
        font = CreateFontW(-MulDiv(10, static_cast<int>(dpi), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY, DEFAULT_PITCH, L"Segoe UI");
        const auto control_font = font ? font : static_cast<HFONT>(GetStockObject(DEFAULT_GUI_FONT));
        auto control = [&](DWORD extended, const wchar_t* kind, const wchar_t* text, DWORD flags,
                           int x, int y, int w, int h, int id) {
            HWND handle = CreateWindowExW(extended, kind, text, WS_CHILD | WS_VISIBLE | flags,
                scale(x), scale(y), scale(w), scale(h), window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
            SendMessageW(handle, WM_SETFONT, reinterpret_cast<WPARAM>(control_font), TRUE);
            return handle;
        };
        control(0, L"STATIC", wide(request.prompt).c_str(), 0, 16, 14, 488, 38, -1);
        edit = control(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_TABSTOP | ES_PASSWORD | ES_AUTOHSCROLL,
                       16, 56, 488, 26, 1001);
        SendMessageW(edit, EM_SETLIMITTEXT, max_units, 0);
        control(0, L"STATIC", label(request.note, L"密码由 Windows 输入框接收，不会写入 mpv 输入历史。").c_str(),
                0, 16, 92, 488, 28, 1002);
        const HWND ok = control(0, L"BUTTON", label(request.ok, L"确定").c_str(),
                                WS_TABSTOP | BS_DEFPUSHBUTTON, 316, 136, 88, 28, IDOK);
        const HWND cancel = control(0, L"BUTTON", label(request.cancel, L"取消").c_str(),
                                    WS_TABSTOP | BS_PUSHBUTTON, 416, 136, 88, 28, IDCANCEL);
        if (!edit || !ok || !cancel) {
            finish(true);
            result({request.id, false, {}, "Could not create the Windows password controls"});
            return;
        }
        // SetFocus also activates the window, so it is left out as well; the
        // box moves the focus to its edit control once it is activated.
        if (background) ShowWindow(window, SW_SHOWNOACTIVATE);
        else { ShowWindow(window, SW_SHOW); SetForegroundWindow(window); SetFocus(edit); }
    }
    void run() {
        WNDCLASSW wc{};
        wc.lpfnWndProc = procedure; wc.hInstance = GetModuleHandleW(nullptr);
        wc.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
        wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_BTNFACE + 1);
        wc.lpszClassName = L"splay.SecretInput";
        const bool registered = RegisterClassW(&wc) != 0;
        if (!registered && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
            // Retain a worker that reports failures rather than silently falling back.
            for (;;) {
                WaitForSingleObject(wake, INFINITE);
                std::lock_guard<std::mutex> lock(mutex);
                if (stopping) return;
                if (pending) { results.push_back({pending->id, false, {}, "Could not register the Windows password dialog"}); pending.reset(); }
            }
        }
        for (;;) {
            const DWORD status = MsgWaitForMultipleObjects(1, &wake, FALSE, INFINITE, QS_ALLINPUT);
            if (status == WAIT_OBJECT_0) {
                std::optional<Request> request;
                bool stop, cancel;
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    stop = stopping; cancel = cancelling; cancelling = false;
                    request = std::move(pending); pending.reset();
                }
                if (stop || cancel || request) finish(true);
                if (stop) break;
                if (request) open(*request);
            }
            MSG msg;
            while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
                if (window && msg.message == WM_KEYDOWN && (msg.wParam == VK_RETURN || msg.wParam == VK_ESCAPE)) {
                    finish(msg.wParam == VK_ESCAPE); continue;
                }
                if (window && IsDialogMessageW(window, &msg)) continue;
                TranslateMessage(&msg); DispatchMessageW(&msg);
            }
        }
        if (registered) UnregisterClassW(L"splay.SecretInput", GetModuleHandleW(nullptr));
    }
#else
    ~Impl() { for (auto& result : results) wipe(result.value); }
#endif
};

SecretInput::SecretInput() : impl_(std::make_unique<Impl>()) {}
SecretInput::~SecretInput() = default;
void SecretInput::request(std::uint64_t id, const std::string& title, const std::string& prompt,
                          const std::string& note, const std::string& ok, const std::string& cancel) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    for (auto& result : impl_->results) wipe(result.value);
    impl_->results.clear();
#ifdef _WIN32
    if (!impl_->wake) { impl_->results.push_back({id, false, {}, "Could not initialize the Windows password dialog"}); return; }
    impl_->pending = Impl::Request{id, title, prompt, note, ok, cancel};
    SetEvent(impl_->wake);
#else
    (void)title; (void)prompt; (void)note; (void)ok; (void)cancel;
    impl_->results.push_back({id, false, {}, "Native password input is only available on Windows"});
#endif
}
std::optional<SecretResult> SecretInput::poll() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->results.empty()) return std::nullopt;
    auto result = std::move(impl_->results.front());
    impl_->results.pop_front();
    return result;
}
void SecretInput::cancel() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->pending.reset(); impl_->cancelling = true;
    for (auto& result : impl_->results) wipe(result.value);
    impl_->results.clear();
#ifdef _WIN32
    if (impl_->wake) SetEvent(impl_->wake);
#endif
}
} // namespace splay
