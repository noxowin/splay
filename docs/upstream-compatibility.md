# Syncplay 更新与兼容性

**官方更新不会自动进入 splay。** 本项目独立实现协议，使用原生 DLL 控制 mpv，没有运行官方 Python 客户端或打包官方 mpv 界面。

| 上游改动 | 对 splay 的影响 |
| --- | --- |
| 保持协议兼容的服务端修复 | 对应服务器升级后可能受益，仍需验证权限与状态行为 |
| 协议字段、能力协商、聊天或列表限制 | 可能需要适配核心，并与新旧客户端及服务端互通测试 |
| 同步算法、断线和状态时序修复 | 需检查本项目是否存在同类问题，独立修复并补充回归验证 |
| 官方 GUI、Lua 显示或 Python 依赖 | 不直接更新本项目；可能影响测试工具或提示类似问题 |
| TLS 实现 | splay 使用 Windows Schannel，不继承 pyOpenSSL 修复；仍需跟进服务端兼容性 |

当前已验证的协议基线是 [Syncplay 1.7.6](https://github.com/Syncplay/syncplay/releases/tag/v1.7.6)，测试范围见 [preview.4 验证记录](validation-v4.md)。这表示测试所用版本，不代表上游最新版本；共享列表已支持，已观看标记尚未实现。

维护时先查看 [官方更新记录](https://syncplay.pl/changelog/) 和 [源码](https://github.com/Syncplay/syncplay)，固定待验证版本或提交，再评估协议、权限、同步和 mpv 适配变化。相关修改须通过未修改的官方服务端与客户端联调，并更新验证记录，不自动合并上游代码或改写用户配置。
