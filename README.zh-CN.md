# splay

[![Windows build](https://github.com/noxowin/splay/actions/workflows/windows.yml/badge.svg)](https://github.com/noxowin/splay/actions/workflows/windows.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

为现有 mpv 添加兼容 Syncplay 的房间、同步播放、聊天与共享播放列表，无需额外运行 Syncplay 客户端。

[English](README.md) · **简体中文**

**[下载 Windows x64 v0.1.1 预发布版](https://github.com/noxowin/splay/releases/download/v0.1.1/splay-windows-x64-v0.1.1.zip)** · [发布页面](https://github.com/noxowin/splay/releases/tag/v0.1.1) · [安装与使用](docs/install.zh-CN.md) · [更新记录](CHANGELOG.md) · [问题反馈](https://github.com/noxowin/splay/issues)

splay 是独立项目，并非 mpv 或 Syncplay 的官方发行版。同步不传输视频，每位成员需要自行获取媒体。

## 功能

- 与 Syncplay 服务器及官方客户端同步播放、暂停和跳转；支持成员、准备状态与受控房间权限。
- 小偏差时平滑追赶：领先房间 1.5 至 4 秒时暂时以 0.95 倍速追平，不再跳回。
- 连接后默认开启全员准备后 5 秒倒计时开播，以及服务器延迟显示与共享。
- Enter 快聊；Shift+h 打开透明的全窗口消息记录，支持连续发送、翻阅历史与彩色昵称。
- 聊天室与弹幕模式可切换并记忆；可选的平滑弹幕默认关闭。
- 按上报的精确时长比较媒体；支持本机时间偏移，并可按成员时长差预填后修改确认。
- 房间共享播放列表、本机文件匹配、网络地址显式确认；本机跟随默认关闭。
- 命名连接组合、在 mpv 输入框中输入密码（输入时可见）、Windows 加密密码记忆与有限自动重连。
- 界面支持简体中文与英文，默认跟随 Windows 显示语言，也可在设置中切换。
- 原生 mpv 界面，可选 uosc 集成；每个播放器进程都默认关闭 splay，手动连接。

## 快速开始

1. 下载上方 ZIP，并用发布页面的 SHA256 校验值核对。关闭 mpv。
2. 将以下四个文件复制到 mpv **实际配置目录**下的 `scripts` 文件夹；升级时全部替换：

   ```text
   scripts/splay.lua
   scripts/splay_core.dll
   scripts/splay_overlay.lua
   scripts/splay_playlist.lua
   ```

3. 正常打开视频，按 **Shift+s** 或点击同步图标，启用 splay、填写房间并连接。初始服务器为 `syncplay.pl:8999`，昵称为 `splayuser`，房间需自行填写。
4. **Enter** 输入、发送快聊，**Esc** 取消；**Shift+h** 查看消息记录并连续聊天。聊天模式与房间行为在“设置”中调整。

便携 mpv 通常使用 `mpv.exe` 旁的 `portable_config`，其他安装通常使用 `%APPDATA%\mpv`。保留原有播放器配置。GitHub 的 Source code 压缩包不含已编译 DLL。

默认加入房间时请求全房暂停，同房成员退出或换房时也请求暂停，并遵守受控房间权限。两个选项均可在设置中关闭并记忆。加入房间保留当前媒体与播放参数。共享列表的本机跟随默认关闭；分享或打开陌生网络地址需要明确确认。

## 兼容与开发

需要支持 C 插件和 Lua `mp.input` 的 Windows x64 mpv；uosc 可选。确切测试版本、验证结果与未覆盖范围见 [v0.1.1 验证记录](docs/validation-v0.1.1.md)，不保证所有 mpv 构建、整合包或浏览器鉴权流程均兼容。

构建见 [贡献指南](CONTRIBUTING.md)，技术说明见 [架构](docs/architecture.zh-CN.md) 与 [上游兼容说明](docs/upstream-compatibility.md)。原创代码采用 [GPL-3.0-only](LICENSE)，第三方文件保留各自许可，见 [第三方声明](THIRD_PARTY_NOTICES.md)。安全问题按 [SECURITY.md](SECURITY.md) 反馈。
