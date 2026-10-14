# 首版实施计划

状态：规划完成，用户于 2026-10-13 授权由 GPT-6.1-sol 开始代码实现。以下是本轮执行范围；实际完成情况和测试证据另行记录。

## 本轮交付

实现 Windows x64 可选插件的首个可测试版本：连接 Syncplay、成员与准备状态、受控房间操作员认证/创建、播放暂停跳转同步、主动断开和手动重连。保留原有 mpv 与当前媒体；uosc 可选。交付源代码、可复现构建脚本、仅含插件的 ZIP、安装说明和测试记录。仓库继续私有，不自动公开或标记稳定版。

## 已决定的技术方案

- 验证宿主：mpv **0.41.0 Windows x64** 官方仓库提供的 MinGW 构建。uosc 验证版本 **5.13.0**。首版不声称低版本或所有整合包已兼容。
- 协议基线：**Syncplay 1.7.6** 未修改的官方服务端与客户端。
- 原生核心：**C++17**，mpv C plugin DLL；**Winsock + Windows Schannel** 提供网络与 TLS，不要求用户安装 Python、LuaSocket 或额外 TLS 运行时。
- 界面：Lua，原生 `mp.input` 与可选 uosc 菜单。优先独立快捷键 `Ctrl+Shift+s`；不强制覆盖用户已有键位。
- 构建：仓库内 Python 脚本驱动现有 MinGW-w64 `g++`，静态链接编译器运行库。Python 仅用于开发/构建/验证，不是插件运行依赖。
- JSON：固定版本的 nlohmann/json 单头文件；mpv 头文件固定到 0.41.0。保留第三方许可证及来源，不复制整合包配置。
- TLS 默认先协商。服务器明确不支持时可按 `prefer` 模式明示明文连接；`require` 模式拒绝。证书或 TLS 握手失败不得悄悄降级；`off` 仅在用户明确选择时不协商。
- 密码默认只保留在内存中；保存连接配置不包含服务器密码或操作员密码。每个播放器实例独立且默认断开。
- 断线后停止同步并继续本地播放，保留可手动重连的连接参数；不自动跳回房间进度。

## 模块接口

发行文件命名为 `scripts/splay_core.dll`、`scripts/splay.lua`，核心 client 名称使用 `splay_core`，Lua 名称使用 `splay`。若宿主命名与此不同，启动测试必须发现并修正。

Lua 到核心统一调用：

```text
script-message-to splay_core splay-command <JSON>
```

命令对象的 `action`：

- `status`：请求完整状态。
- `connect`：`host`, `port`, `username`, `room`, `password`, `tls`。
- `disconnect`：断开，清理同步状态。
- `room`：`room`，切换房间。
- `ready`：`ready` 布尔值。
- `authenticate`：`password`，认证当前受控房间操作员。
- `create-room`：`room`, `password`，按官方协议创建受控房间并进入。

核心到 Lua：`script-message-to splay splay-state <JSON>`。状态包含 `schema:1`、`connection`（`disconnected`/`connecting`/`connected`/`error`）、`encrypted`、`host`、`port`、`username`、`room`、`ready`、`is_controller`、`controlled`、`error`、`warning`、`members`。成员包含 `username`、`room`、`ready`、`is_controller`、`file`（仅公开或已脱敏的元信息）。状态与日志不包含密码或媒体完整 URL。

所有用户或服务器文本作为数据传入，不拼接为可执行 mpv 命令。原生接口校验类型、范围、字符串长度、协议消息尺寸和数值是否有限。

## 核心与传输的内部接口

`src/net/transport.hpp` 提供独立 `splay::Transport`，隐藏 Windows 类型：

```cpp
enum class TlsMode { Prefer, Require, Off };
struct ConnectOptions { std::string host; int port = 8999; TlsMode tls = TlsMode::Prefer; };
struct TransportEvent { enum class Kind { Connected, Line, Closed, Error }; Kind kind; std::string text; bool encrypted = false; };
class Transport {
public:
    Transport();
    ~Transport();
    void connect(const ConnectOptions&);
    void send_line(const std::string&);
    void disconnect();
    std::vector<TransportEvent> poll();
};
```

网络工作在自有后台线程，`poll()` 不阻塞；连接、读写、停止有界，析构回收线程与句柄。传输层自行处理 STARTTLS 协商，并且只在 TLS 已就绪或允许明文后发出 `Connected`；业务层随后发送 Hello。每条协议消息为一行 UTF-8 JSON，传输层限制行长。连接切换不能混入旧连接事件。

## 同步规则

- 实现官方握手、心跳、延迟估计及 `ignoringOnTheFly` 双向确认，避免旧状态覆盖主动操作。
- 加入时先取得房间状态，再对齐当前已加载媒体；不能 `loadfile` 当前媒体或共享带鉴权的 URL。
- 区分用户操作、应用远端状态、文件加载、缓冲和文件结束，抑制反馈循环。
- 受控房间普通成员不能改变全局播放状态。操作员权限以服务端消息为准。
- 首轮优先明确阈值的跳转纠偏；不必通过临时改速实现，以减少对用户速度设置的干扰。非 1x 播放、不可跳转流和不同时间轴需明确提示限制。
- 离开、切房和重连时清除旧同步确认与媒体状态；断开后不继续修改播放属性。

## 验证与完成标准

1. 编译原生 DLL，检查导出入口、运行库依赖和 mpv 实际加载；关闭 mpv 时无挂起。
2. 核心测试覆盖异常协议、服务端强制序号确认、权限、房间/准备状态、旧消息、脱敏和回声抑制。
3. 与本机启动的未修改 Syncplay 1.7.6 服务端联调；两个 mpv 实例至少一个由官方 Syncplay 客户端控制。
4. 验证播放/暂停/跳转、后加入、切房、受控权限、断线后独立播放、手动重连及错误密码。
5. 验证 Lua 原生面板和 uosc 菜单；检查包含当前媒体的外部启动参数得到保留。真实浏览器与未提供的整合包测试不能用命令行模拟冒充。
6. 网络媒体测试使用本机 HTTP 点播服务和不同 URL，证明只同步状态且不泄露 URL；TLS 测试记录成功与证书拒绝行为。
7. 包含真实结果和未完成项的安装/验证文档；检查 ZIP 仅包含插件文件与声明，Git 不含工具下载、凭据或私有媒体。

若发现宿主或协议实际行为与规划冲突，以运行证据修正规划和实现，不能用占位功能标记完成。
