# 架构与接口

splay 在现有 mpv 进程中运行：C++17 原生插件处理协议和播放同步，Lua 提供界面，uosc 为可选集成。DLL 通过 `MPV_CPLUGIN_DYNAMIC_SYM` 使用宿主 API，不链接另一份 libmpv。构建方法见 [贡献指南](../CONTRIBUTING.md)。

## 模块

| 位置 | 职责 |
| --- | --- |
| `src/core/` | Syncplay 协议、房间权限与同步决策；非密码连接历史、Windows DPAPI 凭据存储 |
| `src/net/` | Winsock 连接、STARTTLS 与 Schannel TLS；传输线程不调用 mpv API |
| `src/mpv/` | 插件入口、播放属性观察、远端状态应用与 Lua 消息桥接 |
| `scripts/splay.lua` | 主菜单、连接表单、历史选择与可选 uosc 适配 |
| `scripts/splay_overlay.lua` | 屏幕图标、短时消息与房间状态 |
| `scripts/splay_playlist.lua` | 共享列表菜单、本机文件匹配、显式跟随与 EOF 下一项 |

核心与界面通过 `script-message-to` 交换 JSON。历史和凭据分别保存，使用文件锁与原子替换；界面只收到密码是否已保存，不收到解密后的明文。

## 自动化接口

使用 `script-message-to splay splay-command <JSON>`，由主界面统一处理启用状态。以下为常用 `action` 及参数；完整行为以 [Lua 入口](../scripts/splay.lua) 和 [原生适配](../src/mpv/plugin.cpp) 为准。

| action | 参数与用途 |
| --- | --- |
| `status` / `disconnect` | 查询状态 / 断开连接 |
| `connect` | `host`、`port`、`username`、`room`、`password`、`tls`；自动化须显式选择 `remember_password` / `use_saved_password` |
| `room` / `ready` | `room` 为房间名；`ready` 为布尔值 |
| `chat` | `text` 为消息正文 |
| `authenticate` | `password` 为操作员密码，不是服务器连接密码 |
| `create-room` | `room`、`password`，创建受控房间 |
| `playlist-set` | `files` 为完整列表，遵守服务器能力与长度限制 |
| `playlist-index` | `index` 为从 0 开始的索引，遵守房间控制权限 |

原生核心以 `splay-state` 返回版本化状态，包含连接、房间、成员、准备和列表信息；事件通过 `splay-event` 通知界面。`splay_core` 的直接入口供内部桥接与测试使用。自动化应使用受保护的本机 IPC，避免记录包含密码的命令。

## 行为边界

- 每个新进程默认关闭且不自动连接；启用或入房不重新加载视频、不改写调用方媒体参数。
- 同步处理暂停与进度，加载/缓冲状态不作为主动操作广播。非 1x 播放暂停同步；重连由用户手动发起。
- 当前媒体默认以隐藏名称、时长和大小 0 上报，不广播完整路径或私有 URL。共享列表的显式添加/导入是独立操作；只有明确选集或开启跟随才可能加载已匹配媒体。
- 未知 HTTP(S) 地址需逐项确认，远端绝对路径和其他协议不自动加载。共享列表不传输媒体。
- TLS 使用 Windows Schannel。`prefer` 仅在服务器明确不支持 TLS 时允许明文；握手或证书失败不降级，`require` 拒绝明文。
- 仅管理 splay 自身文件；uosc 控制条只在当前进程扩展，不修改磁盘配置。协议文本作为数据处理。

当前互通基线为未修改的 Syncplay 1.7.6；真实测试与未覆盖范围见 [验证记录](validation-v4.md)。官方更新的跟进方式见 [上游兼容说明](upstream-compatibility.md)。

## 参考与来源

- [mpv](https://github.com/mpv-player/mpv)：[C 插件](https://mpv.io/manual/stable/#c-plugins) 与宿主接口。
- [Syncplay 1.7.6](https://github.com/Syncplay/syncplay/tree/v1.7.6)：协议和互通参照；本项目未打包官方客户端实现。
- [uosc](https://github.com/tomasklaen/uosc) 及其 [Menu API](https://github.com/tomasklaen/uosc/wiki/Menu-API)：可选界面集成。
- 整合与构建参考：[mpv-config](https://github.com/dyphire/mpv-config/)、[mpv-winbuild-cmake](https://github.com/shinchiro/mpv-winbuild-cmake)、[mpv-winbuild](https://github.com/dyphire/mpv-winbuild)、[uosc_danmaku](https://github.com/Tony15246/uosc_danmaku)。

实际随源码分发的第三方文件及固定哈希见 [SOURCES.json](../third_party/SOURCES.json)，许可见 [第三方声明](../THIRD_PARTY_NOTICES.md)。参考项目的链接不表示其代码已纳入本项目。
