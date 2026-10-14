# splay

[![Windows build](https://github.com/noxowin/splay/actions/workflows/windows.yml/badge.svg)](https://github.com/noxowin/splay/actions/workflows/windows.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

**[下载 Windows x64 预览版](https://github.com/noxowin/splay/releases/tag/v0.1.0-preview.2)** · [安装说明](docs/install.md) · [问题反馈](https://github.com/noxowin/splay/issues) · [更新记录](CHANGELOG.md)

为 mpv 增加可选的 Syncplay 同步功能。在浏览器或其他软件打开视频后，直接在当前播放器中连接服务器、加入房间并选择是否同步。

An optional Syncplay-compatible plugin for your existing mpv player. Windows x64 first; no separate Syncplay client required at runtime.

**当前版本：`v0.1.0-preview.2`，公开开发预览版，尚非稳定版。** 支持连接历史、聊天、状态文字和鼠标按钮；兼容范围和实际测试结果见 [验证记录](docs/validation-v2.md)。

先以独立插件接入用户现有的 mpv 或 mpv 整合包；后续再评估包含同一插件的集成版播放器。splay 是独立项目，不是 Syncplay 或 mpv 的官方发行版。

## 使用流程

1. 用原有方式打开视频，例如浏览器调用外部 mpv。
2. 按 **Shift+s**，或把鼠标移到底部点击“同步”，填写或选择历史服务器、昵称和房间。
3. 查看成员和准备状态，按需加入同步。
4. 同步播放、暂停、跳转；受控房间由操作员控制播放。
5. 退出同步后继续独立播放当前视频。

插件默认不自动连接服务器。媒体仍由各成员自己的播放器获取，Syncplay 仅同步播放状态，不传输视频。

## 已实现的功能

- 兼容现有 Syncplay 服务器，并与官方客户端互通。
- 连接、断开、切换房间，以及明确的连接状态与错误提示。
- 成员列表、准备状态、受控房间及操作员认证。
- 播放、暂停、跳转、进度纠偏与手动重连。
- 记住服务器、端口、昵称、房间、TLS；支持完整连接组合和单个字段历史。
- 与官方客户端双向聊天，显示本房间聊天记录、准备状态和播放操作提示。
- 无 uosc 时提供独立面板与底部鼠标按钮；安装 uosc 后可使用其菜单。
- 保留已有播放器配置、当前媒体和平台传入的播放参数。

共享播放列表、自动获取他人媒体和自动重连不在本版范围内。准备状态用于查看与切换，不自动实现“全员准备后开播”。

## 安装

在 [Release 页面](https://github.com/noxowin/splay/releases/tag/v0.1.0-preview.2) 下载 `splay-windows-x64-preview2.zip` 和同名 `.sha256` 文件。GitHub 自动生成的 Source code 压缩包是源码，不含已编译 DLL。可用 PowerShell 的 `Get-FileHash .\splay-windows-x64-preview2.zip -Algorithm SHA256` 与校验文件比对。

关闭播放器，将预览包中的 **三个运行文件** `scripts/splay.lua`、`scripts/splay_core.dll`、`scripts/splay_overlay.lua` 放入该播放器实际使用的配置目录下的 `scripts` 文件夹。升级旧版时替换前两个并新增第三个。便携版通常使用 `mpv.exe` 旁的 `portable_config`；不要覆盖其他配置。

正常打开视频，按 **Shift+s** 进入面板，首次默认服务器为 **syncplay.pl:8999**、昵称为 **splayuser**。填写房间后选择连接。下次打开会恢复上次填写的非密码信息，仍需手动连接。密码仅保留在进程内存，输入时屏幕可见。

完整步骤、uosc 按钮与卸载方式见 [安装说明](docs/install.md)。运行插件不需要安装 Python、Syncplay 客户端或 LuaSocket。

下面是实际 mpv 中的准备状态、播放提示与聊天截图，视频为自行生成的测试画面：

![splay 在 mpv 中显示准备状态、播放提示与双向聊天](docs/images/status-chat.png)

## 从源码构建

开发需要 Windows x64、Python 3 与 MinGW-w64 GCC（本次使用 GCC 14.2.0）。在项目目录执行：

```powershell
python tools/build.py package --compiler 'C:\path\to\g++.exe'
```

输出为 `dist/splay-windows-x64-preview2.zip`。源码内固定了 JSON 与 mpv API 头文件；构建不下载依赖。官方客户端、播放器和测试媒体仅用于开发验证，不随插件打包。

GitHub Actions 在 Windows 上构建并运行核心、连接历史与包内容检查。CI 产物用于开发验证，公开下载以 Release 为准。完整播放器互通与界面验证仍按 [贡献指南](CONTRIBUTING.md) 单独执行。

## 兼容范围

“通用插件”指不依赖某一个 mpv 整合包或启动器。插件仍须被目标 mpv 实例加载，并获得必要接口。禁用脚本、使用另一配置目录、架构不匹配或内嵌 libmpv 的软件需要单独核实。

网络点播首版以各自打开的、可跳转且时间轴一致的媒体为验证对象。浏览器的登录信息、临时链接和请求头不会因为加入房间而自动转移给其他成员。

已测参考宿主报告 `v0.41.0-dev-g41f6a6450`，uosc 为 5.13.0；也使用整合包中的 `v0.41.0-560-g05b327c72` 和 uosc 5.12.0 在隔离配置下验证界面与历史恢复。协议互通基线为 Syncplay 1.7.6。完整整合包内其他脚本、真实浏览器调用链和最低兼容版本仍待验证。非 1x 播放暂停同步；不可跳转流只具备有限同步能力。

## 项目文档

- [架构与插件边界](docs/architecture.md)
- [安装与使用](docs/install.md)
- [本轮实际验证与限制](docs/validation-v2.md)
- [第一轮验证存档](docs/validation.md)
- [官方更新的影响与跟进方式](docs/upstream-compatibility.md)
- [本轮需求与实现边界](docs/iteration-2.md)
- [首版实施计划](docs/implementation-plan.md)
- [开发路线与验收条件](docs/roadmap.md)
- [参考项目与来源记录](docs/references.md)
- [协作约定](AGENTS.md)
- [贡献指南](CONTRIBUTING.md)
- [安全问题反馈](SECURITY.md)
- [发布与来源对应](docs/releases.md)

项目原创代码以 **GNU GPL 第 3 版（仅此版本，`GPL-3.0-only`）** 发布，完整条款见 [LICENSE](LICENSE)。Copyright (C) 2026 noxowin and splay contributors。第三方组件继续适用各自的许可，见 [声明](THIRD_PARTY_NOTICES.md) 和 [来源清单](third_party/SOURCES.json)。
