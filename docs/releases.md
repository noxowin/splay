# 发布与来源对应

## v0.1.0-preview.4

[发布页面](https://github.com/noxowin/splay/releases/tag/v0.1.0-preview.4) 提供 `splay-windows-x64-preview4.zip` 及同名 `.sha256`。对应源码为 [`v0.1.0-preview.4`](https://github.com/noxowin/splay/tree/v0.1.0-preview.4)，仍为开发预发布。

本版新增当前用户加密凭据、分区状态与消息历史、房间共享播放列表。安装时替换已有三个运行文件，并新增 `scripts/splay_playlist.lua`；原有播放器配置不必替换。

使用本机 MinGW-Builds GCC 14.2.0 重新编译，DLL SHA-256：`04d855caad68984fa862b67dc2adbd8bf03d08850f3ccf799c28c1c563efe9ed`。完整测试范围见 [本轮记录](validation-v4.md)。包包含主许可证、第三方声明、来源和原始许可，凭据/配置/测试播放器不在包内。

## v0.1.0-preview.3

[发布页面](https://github.com/noxowin/splay/releases/tag/v0.1.0-preview.3) 提供 `splay-windows-x64-preview3.zip` 及同名 `.sha256` 校验文件。对应源码为 [`v0.1.0-preview.3`](https://github.com/noxowin/splay/tree/v0.1.0-preview.3)，仍为开发预发布。

本版更新 Lua 界面、聊天输入与原生历史草稿保存，升级须替换三个运行文件。使用与前版相同的本机 MinGW-Builds GCC 14.2.0 工具链重新编译；DLL SHA-256 为 `024a926e4c1392d3723a1d2a5e78ba04d15fe4d02ef6d1b2509df5e20d35a062`。实际验证与限制见 [本轮记录](validation-v3.md)。

ZIP 中包含 GPL-3.0-only 主许可证、第三方声明、固定来源与原始许可文件；运行不需要 Python、独立 Syncplay 客户端或 LuaSocket。用户的播放器、配置、媒体和连接历史均不在包内。

## v0.1.0-preview.2

[发布页面](https://github.com/noxowin/splay/releases/tag/v0.1.0-preview.2) 提供 Windows x64 插件 ZIP 和 SHA-256 校验文件。该版本为预发布，不代表稳定版或所有 mpv 整合包均兼容。

- 安装包：`splay-windows-x64-preview2.zip`。
- 校验文件：`splay-windows-x64-preview2.zip.sha256`，内容为安装包的 SHA-256 与文件名。
- 对应源码：标签 [`v0.1.0-preview.2`](https://github.com/noxowin/splay/tree/v0.1.0-preview.2)。GitHub 的 Source code 下载包含项目源码、固定的第三方头文件和构建脚本；它不含预编译 DLL。
- 构建方式：[贡献指南](../CONTRIBUTING.md)，需要 Windows x64、Python 和 MinGW-w64 GCC。
- 项目许可：GNU GPL 第 3 版，仅此版本；第三方 JSON/mpv 头文件保留 MIT/ISC 许可。

公开包沿用经过第二轮互通验证的 DLL，新增许可证与公开发布文档；原生同步实现、Lua 功能未在此次仓库整理中改动。DLL SHA-256 为 `95a4ebd71b8413707b6ef75992ac9a3543b01027512cf31ca7395d1dfd822991`。ZIP 因文档和许可证变化产生新校验值，以 Release 附带的校验文件为准。

CI 会从提交重新构建并执行核心、历史和包校验，记录编译器版本。CI 产物不等同于经过本地播放器联调的发布包；更换编译器或重建时间可能改变 DLL 字节，不声称可逐字节复现。

## 发布约定

每个二进制包对应保留的源码标签，包含主许可证、第三方声明、来源清单和安装说明。发布前验证原始 vendor 哈希、包白名单、运行文件与构建输入一致、校验值，并核对真实测试范围。修改原生/Lua 功能时需完成相关运行测试；仅整理文档不扩大兼容声明。

除非完成稳定性验收，版本继续标记为 prerelease。正式下载置于 GitHub Releases，不把自动 CI artifact 宣传为已验收的发布版本。
