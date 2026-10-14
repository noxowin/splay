# 开发预览验证记录

验证日期：2026-10-13（America/Los_Angeles）。代码由用户指定的 GPT-6.1-sol 实现，经过源码审查和以下实际运行检查。本记录不代表所有 mpv 整合包、平台调用方式或网络环境均已兼容。

## 环境与来源

| 项目 | 实际环境 |
| --- | --- |
| 系统 | Windows x64，系统版本 10.0.26200.0 |
| 编译器 | MinGW-w64 GCC 14.2.0，C++17；静态链接编译器运行库 |
| 播放器 | [mpv v0.41.0 的 Windows x64 MinGW 资源](https://github.com/mpv-player/mpv/releases/tag/v0.41.0)，二进制报告 `v0.41.0-dev-g41f6a6450`，构建于 2025-12-21 |
| 可选菜单 | [uosc 5.13.0](https://github.com/tomasklaen/uosc/releases/tag/5.13.0) |
| 官方互通参照 | [Syncplay 1.7.6](https://github.com/Syncplay/syncplay/tree/v1.7.6)，提交 `993232ab095bb810593459bc705b3e6fc64ad161`，服务端与客户端源码均未修改 |
| 测试工具 | Python 3.12；独立虚拟环境中的 Twisted 26.4.0、pyOpenSSL 26.4.0、cryptography 50.0.2、pywin32 312 |
| 测试媒体 | 自行生成的 180 秒测试图与音频，320×180、10 fps，无用户媒体 |

下载 ZIP 的 SHA-256：

```text
mpv:      a49811c0752c108b8260636f9c6f6fcb97406641c98b30f1e7b500dfb20177de
Syncplay: 90481460a71580237f1ce78b69061f63556e53d13815d75e21aa0553cef8bc9e
uosc:     4be9da3289285300fa374496c3f1bfd7bb20ac08e890d25bd5a06b28eebe4882
```

测试播放器与官方客户端依赖留在被 Git 忽略的本地目录，不进入安装包。插件运行不需要这些开发工具。

## 已通过的检查

| 检查 | 结果与边界 |
| --- | --- |
| 原生构建 | DLL 成功构建；导出 `mpv_open_cplugin`；导入仅 Windows 系统/UCRT 库，无额外 libgcc、libstdc++、libwinpthread DLL |
| 协议核心 | 握手前强制状态、序号确认、旧确认抑制、服务端强制状态优先、成员状态覆盖、权限、密码摘要、错误消息、媒体脱敏和清空、超时、非 1x 暂停同步等断言通过 |
| 网络 | 分片/多行读取、CRLF 写入、TLS 明确降级/拒绝、消息大小限制、停滞协商时取消、800 KB 队列分片写入、localhost 到 IPv4-only 服务端的地址回退通过 |
| TLS | 对 `syncplay.pl:8995` 的 TLS 1.2 系统证书校验握手与加密消息往返通过；自签名证书被拒绝，未产生明文连接；未修改系统证书库 |
| 原生界面 / uosc | 两种入口加载检查 2/2 通过；实际媒体窗口截图检查及准备按钮命令断言 2/2 通过。此界面测试使用模拟核心，只证明界面交互，不代替协议互通 |
| 安装包共存 | 将最终 ZIP 解压到独立配置目录，真实 DLL 与 Lua 自动加载、核心状态回传、原生面板打开、正常退出均通过；此项未使用模拟核心，也不联网 |
| 官方互通 | 两个真实 mpv，其中一个由官方客户端控制；本地文件和 HTTP 点播均经过完整互通脚本，具体项目如下 |

互通检查包括：

- 错误服务器密码拒绝、正确密码连接、成员发现及双方准备状态。
- 后加入对齐，官方客户端播放、插件暂停，以及两个方向的跳转；连续六次插件暂停/恢复均等待官方播放器确认，检查操作不被状态更新吞掉。
- 切房、创建受控房间、普通成员操作不影响房间、操作员认证后控制。
- 主动断开后独立播放、手动重连、错误操作员密码拒绝、正确认证后清除错误。
- 暂停状态下持续 30 秒心跳，不因没有本地操作而断开。
- 两端分别打开不同的 HTTP URL 参数；加入和同步不改写原有媒体地址。
- 独立协议探针读取服务端实际 List，确认插件上传的是隐藏文件元数据，而非 URL 或参数。
- 停止媒体后服务端文件信息清空，重新加载测试媒体后恢复隐藏元数据。
- 服务端结束后停止同步，仍可本地跳转并继续播放推进。

同步断言使用宽松的集成测试容差：两播放器位置相差小于 2 秒，指定跳转目标误差小于 3 秒。这是功能检查，未测量或保证毫秒级同步。HTTP 地址的参数均为合成测试凭据；没有连接真实视频平台或复制浏览器登录状态。

公共 TLS 往返探测只发送一条无效测试命令，实际解密收到服务端 `Unknown command 1` 错误后关闭连接，未登录或加入房间。该检查证明加密传输收发，不代表在公共房间进行过多人同步实测。

最终互通运行记录（本机保留，未提交包含瞬态参数的原始日志）：

| 媒体 | 本地结果文件 | 结果 |
| --- | --- | --- |
| 本地文件 | `.local/integration/20261013-193628-a05181/result.json` | passed |
| 独立 HTTP 地址 | `.local/integration/20261013-193628-72d9b8/result.json` | passed |

两轮使用同一 DLL，SHA-256 为 `002452770308361272d24c21c0feb880b505791f84d7af02c727b134b381bfcc`。ZIP 的校验值由打包脚本生成在旁边的 `.zip.sha256` 文件中；重新构建可能因时间戳等因素改变二进制校验值。测试结束后未残留测试播放器进程。

## 复现

构建和单元/传输检查：

```powershell
python tools/build.py build
python tools/check.py core
python tools/check.py net
```

编译器可通过 `--compiler` 指定，或设置 `CXX` 为编译器可执行文件路径。`tls-rejection` 检查还需要开发环境中的 `cryptography`：

```powershell
.venv\Scripts\python.exe tools/check.py tls-rejection
```

Schannel 检查应使用普通 Windows 用户环境；本次受限执行环境曾导致系统凭据初始化失败，用普通用户环境后通过。无需管理员证书导入，也不应关闭证书验证。

实际播放器测试需要自行准备上述来源的工具：mpv 位于 `.local/mpv/runtime`，uosc 解压至 `.local/uosc`（含字体），官方源码位于 `.local/upstream/syncplay-1.7.6`，测试媒体位于 `.local/test-media.mp4`。开发依赖可按官方源码中的 `requirements.txt` 安装到 `.venv`。所有路径均可对照测试脚本；互通脚本提供 `--mpv`、`--python`、`--upstream`、`--plugin`、`--media` 参数。

```powershell
python tools/check.py ui
python tools/check.py ui-review
.venv\Scripts\python.exe tests/integration/interop.py
.venv\Scripts\python.exe tests/integration/interop.py --http
python tools/package.py
python tests/ui/package_smoke.py
```

互通脚本为官方客户端设置隔离的 `APPDATA`，使用 `--no-gui --no-store`；双方 mpv 使用 `--no-config --vo=null --ao=null`。本地服务只监听回环地址，结束后通过 Windows Job Object 清理客户端和播放器子进程。截图检查单独运行真实视频窗口，不读取用户配置。测试日志与结果位于 `.local/integration`、`.local/ui-review`。

## 尚未验证与已知限制

- 用户实际使用的 mpv 整合包和真实浏览器调用链尚未提供；命令行加载和保留 URL 的测试不能替代这两项。其他系统、架构、mpv.net/嵌入 libmpv、旧版 mpv 均未认证。
- 长时间弱网、高延迟抖动、密集交错操作、复杂缓冲、带广告或不同剪辑时间轴尚未做全面实测；核心序号测试不能替代真实弱网测试。
- 仅支持 1x 同步；不提供自动变速纠偏、聊天、共享播放列表、全员准备后自动开播或自动重连。
- 密码输入屏幕可见，mpv 输入历史可能在当前进程保留。原生面板需手动刷新；uosc 可实时更新。
- 所有媒体文件名统一隐藏，因此插件不判断内容相同或向用户报告文件名匹配。
- 项目自身的公开许可证尚未确定；当前只交付私有仓库源码和本地开发预览包，不标记稳定版或自动公开。
