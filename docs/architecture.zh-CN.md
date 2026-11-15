# 架构与接口

[English](architecture.md) · **简体中文**

splay 在现有 mpv 进程中运行：C++17 原生插件处理协议和播放同步，Lua 提供界面，uosc 为可选集成。DLL 通过 `MPV_CPLUGIN_DYNAMIC_SYM` 使用宿主 API，不链接另一份 libmpv。构建方法见 [贡献指南](../CONTRIBUTING.md)。

本文描述当前主分支；与已发布 v0.1.0 的差异列在 [更新记录](../CHANGELOG.md) 的“未发布”小节。v0.1.0 实际执行的验证和未覆盖范围见 [版本验证记录](validation-v0.1.0.md)。

## 模块

| 位置 | 职责 |
| --- | --- |
| `src/core/` | Syncplay 协议、房间权限与同步决策；非密码连接历史、Windows DPAPI 凭据存储 |
| `src/net/` | Winsock 连接、STARTTLS 与 Schannel TLS；传输线程只经适配层注入的回调触发线程安全的 `mpv_wakeup`，不调用其他 mpv API，本目录不包含 mpv 头文件 |
| `src/mpv/` | 插件入口、播放属性采样、远端状态应用与 Lua 消息桥接 |
| `scripts/splay.lua` | 主菜单、连接表单、历史选择与可选 uosc 适配 |
| `scripts/splay_overlay.lua` | 屏幕图标、短时消息与房间状态 |
| `scripts/splay_playlist.lua` | 共享列表菜单、本机文件匹配、显式跟随与 EOF 下一项 |

核心与界面通过 `script-message-to` 交换 JSON。历史和凭据分别保存，使用文件锁与原子替换。原生密码框运行在独立线程；交互秘密由原生适配消费，Lua 仅收到结果和短期凭据标识，不收到明文。

## 自动化接口

使用 `script-message-to splay splay-command <JSON>`，由主界面统一处理启用状态。以下为常用 `action` 及参数；完整行为以 [Lua 入口](../scripts/splay.lua) 和 [原生适配](../src/mpv/plugin.cpp) 为准。

| action | 参数与用途 |
| --- | --- |
| `status` / `disconnect` | 查询状态 / 断开连接 |
| `connect` | `host`、`port`、`username`、`room`、`password`、`tls`；自动化须显式选择 `remember_password` / `use_saved_password` / `auto_reconnect` |
| `room` / `ready` | `room` 为房间名；`ready` 为布尔值 |
| `chat` | `text` 为消息正文 |
| `authenticate` | `password` 为操作员密码，不是服务器连接密码 |
| `create-room` | `room`、`password`，创建受控房间 |
| `playlist-set` | `files` 为完整列表，遵守服务器能力与长度限制 |
| `playlist-index` | `index` 为从 0 开始的索引，遵守房间控制权限 |
| `latency` | `enabled` 为布尔值，控制可选的 RTT 显示与元数据共享 |
| `autostart` | `enabled` 为布尔值；可选 `delay` 为 3–30 秒整数（界面固定 5 秒），本次连接的全员准备倒计时策略 |
| `autostart-cancel` | 取消当前倒计时；下一准备阶段或明确重新开启后才可再次计时 |
| `room-policy` | `pause_on_join` / `pause_on_leave` 为布尔值，入房及同房成员退出暂停策略；默认开启，遵守受控房间权限 |
| `set-offset` | `seconds` 为有限数值，范围 ±86400；本机时间 = 房间时间 + 偏移，状态返回 `time_offset` |

原生核心以 `splay-state` 返回版本化状态，包含连接、房间、成员、准备和列表信息；事件通过 `splay-event` 通知界面。`splay_core` 的直接入口供内部桥接与测试使用。自动化应使用受保护的本机 IPC，避免记录包含密码的命令。

## 行为边界

- 每个新进程默认关闭且不自动连接；启用或入房不重新加载视频、不改写调用方媒体参数。
- 未连接、无待重连、无密码输入且无本机时间偏移时，核心只等待 mpv 事件，不采样播放属性；连接或设置偏移的命令先采样一次再恢复每 100 毫秒采样。收到的协议行带传输线程记录的到达时间，延迟与房间时钟按到达时间计算。
- 同步处理暂停与进度，加载/缓冲状态不作为主动操作广播。非 1x 播放暂停同步；自动重连仅获显式连接授权后工作，采用有限重试和连接代次隔离。
- 媒体状态上报本地安全文件名或可信网络媒体标题、时长和大小 0，未知名称仍隐藏，不广播完整路径或媒体 URL。共享列表的显式添加/导入另经确认发送网络地址；只有明确选集或开启跟随才可能加载已匹配媒体。
- 未知 HTTP(S) 地址需逐项确认，远端绝对路径和其他协议不自动加载。共享列表不传输媒体。
- TLS 使用 Windows Schannel，仅 TLS 1.2，并以 `SCH_USE_STRONG_CRYPTO` 拒绝 RC4、DES、出口级与空加密等弱算法。`prefer` 仅在服务器明确不支持 TLS 时允许明文；握手或证书失败不降级，`require` 拒绝明文。
- 仅管理 splay 自身文件；uosc 控制条只在当前进程扩展，不修改磁盘配置。协议文本作为数据处理。

自动开播核心要求完整成员快照、至少两名同房成员、明确准备与媒体、本机可同步播放，以及受控房间的本连接认证。核心换房与重连时先关闭，Lua 在成功连接/换房边界按本机偏好提交一次 5 秒开播策略（偏好默认开启，手动关闭有效），不在每次状态刷新重置计时。到期复核后使用现有播放状态协议，不增加网络选主协议。状态的 `autostart` 包含 `enabled`、`delay`、`pending`、`remaining`、`reason`、`participants`。

入房与同房成员退出（含换房）暂停默认开启，通过现有房间播放权限发起全房暂停，不绕过受控房间操作员限制。`chat_mode`、`pause_on_join`、`pause_on_leave` 保存在非密码历史中，独立于连接组合；其他菜单开关只作用于本进程，可通过 `splay.conf` 设置启动默认值。

Lua 的成员 `media` 是本地显示派生数据，提供时长、名称来源与严格时长比较结果；不作为协议数据发回服务器，不参与自动开播资格判断。

时长按有效原始秒值比较，不使用容差或名称推断同片。`media.check` 与准备状态及延迟配色独立：`duration_match` 为绿，`duration_mismatch` 为红，`unknown` / `self` 为灰；相同或未知时右栏不显示额外提示，只有时长不同时显示差值。绿色只表示时长相同，不能证明文件内容相同。偏移菜单可按指定成员的时长差预填候选值（本机时长减对方时长），经可编辑输入确认后使用原有 `set-offset` 命令；不改变比较结论，也不直接应用或叠加。候选在提交时重新核对连接、成员与媒体快照。

本机时间偏移在核心统一转换：出站位置减偏移，入站位置加偏移。调整偏移只重定位本机并取消本机倒计时，不广播房间跳转。目标超出媒体范围时在边界内暂停本机，保留权威房间时钟；心跳继续上报房间时钟和房间暂停状态，不上传截断的本机位置或本机暂停，避免官方服务器的 watcher 时间戳更新拖慢房间。偏移归零或房间进入可播放片段后恢复跟随，用户主动跳转仍经过原有权限检查。换媒体清零，换房或重连保留当前媒体的偏移；不持久保存、不改变原始时长或同片检查结论。它仅补偿固定时间差，多处不同剪辑需逐段调整或改用相同版本。

`state.settings` 将显示、房间信息和聊天模式偏好交给 overlay。全窗口历史由主 Lua 用 ASS 绘制，使用 `mp.input` 持续接收聊天；`user-data/splay-console-open` 在打开时隐藏 splay 的其他浮层和按钮。最多 300 条消息留在进程内，断线、换房或停用会关闭输入，避免旧草稿发往新房间。

历史层不绘制整屏背景，文字描边保持视频上的可读性。昵称颜色由主脚本按完整昵称分配并缓存，随事件传给 overlay，使历史、聊天室与弹幕使用相同昵称颜色，正文保持白色；前 24 个不同昵称优先分配不同颜色，后续允许复用，缓存最多 1024 人。

弹幕使用独立 ASS 层，缓存文本样式，仅在活动时刷新位置，不在动画帧重建房间面板或广播几何信息。参考 [uosc_danmaku 的渲染模块](https://github.com/Tony15246/uosc_danmaku/blob/main/modules/render.lua) 显式更新文字坐标与分层的方式，自行实现实时聊天的有界轨道和清理逻辑，不接管其他弹幕插件。

mpv 播放时的 OSD 通常随视频帧绘制，暂停时可独立重绘，单独提高 Lua 动画刷新率不能提升低帧率视频的实际显示频率。默认不改视频滤镜；显式开启 `danmaku_smooth` 后，弹幕模式可添加带独立标签的 fps 滤镜，将输出帧率提高到至多 60 帧（低刷新率屏幕按其刷新率）。这是重复帧输出而非运动插帧，会增加处理负担。关闭模式或插件时只撤销自己添加且仍匹配的节点，不替换整条滤镜链；添加失败或外部改动后提示，不按状态刷新反复重试。片名另使用缓存的 ASS 实际字宽测量，避免动画帧中执行昂贵的测量。

当前互通基线为未修改的 Syncplay 1.7.6；真实测试与未覆盖范围见 [验证记录](validation-v0.1.0.md)。官方更新的跟进方式见 [上游兼容说明](upstream-compatibility.md)。

## 参考与来源

- [mpv](https://github.com/mpv-player/mpv)：[C 插件](https://mpv.io/manual/stable/#c-plugins) 与宿主接口。
- [Syncplay 1.7.6](https://github.com/Syncplay/syncplay/tree/v1.7.6)：协议和互通参照；本项目未打包官方客户端实现。
- [uosc](https://github.com/tomasklaen/uosc) 及其 [Menu API](https://github.com/tomasklaen/uosc/wiki/Menu-API)：可选界面集成。
- 整合与构建参考：[mpv-config](https://github.com/dyphire/mpv-config/)、[mpv-winbuild-cmake](https://github.com/shinchiro/mpv-winbuild-cmake)、[mpv-winbuild](https://github.com/dyphire/mpv-winbuild)、[uosc_danmaku](https://github.com/Tony15246/uosc_danmaku)。

实际随源码分发的第三方文件及固定哈希见 [SOURCES.json](../third_party/SOURCES.json)，许可见 [第三方声明](../THIRD_PARTY_NOTICES.md)。参考项目的链接不表示其代码已纳入本项目。
