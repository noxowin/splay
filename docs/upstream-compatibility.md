# Syncplay 官方更新对 splay 的影响

核查日期：2026-10-14。官方最新发布为 [v1.7.6](https://github.com/Syncplay/syncplay/releases/tag/v1.7.6)，发布日期为 2026-08-04；[更新记录](https://syncplay.pl/changelog/)列出了相关修复。本次同时检查主分支快照 [`49e2a1bf36e5be1fc397c5bea14bed350609a9ed`](https://github.com/Syncplay/syncplay/tree/49e2a1bf36e5be1fc397c5bea14bed350609a9ed)，其提交时间为 2026-10-12。

**官方更新不会自动进入 splay。** splay 自行实现协议，通过原生 DLL 控制当前 mpv，没有运行官方 Python 客户端，也没有直接打包官方的 mpv Lua 界面。

| 官方改动类型 | 对本项目的影响 |
| --- | --- |
| 服务端修复，保持协议兼容 | 对应服务器升级后可能直接受益；splay 仍需验证房间、权限和状态行为 |
| 协议字段、能力协商、聊天限制、权限变化 | 可能需要修改 splay 核心，并与新旧官方客户端/服务端重新互通测试 |
| 同步算法、断线处理、状态时序修复 | 不会自动获得；需要评估本项目是否有同类问题，添加回归测试并独立修复 |
| mpv 聊天、字幕样式、Unicode 修复 | 官方 Lua 的代码不在本项目内；需审查我们的显示实现是否同样受影响 |
| 官方 GUI、安装器、Python/PySide 依赖 | 通常不直接影响 splay 的运行时；可能影响开发测试所用的官方客户端 |
| 官方 pyOpenSSL TLS 修复 | splay 使用 Windows Schannel，不直接继承或依赖该修复；服务端 TLS 行为仍需跟进 |

## 本次对比结果

按原始文件字节与固定的 1.7.6 源码比较，主分支的 `syncplay/protocols.py` 和 `syncplay/server.py` 完全一致；`client.py`、`constants.py`、`players/mpv.py` 和 `resources/syncplayintf.lua` 已有变化。这只说明这两个文件当前无差异，不代表主分支全部行为与发行版相同，也不替代运行测试。

与本轮功能有关的变化包括官方 mpv 界面的 ASS 文本转义和 Unicode/组合字符换行处理。splay 的聊天与状态显示独立实现，将特殊字符作为文本处理，并验证中文、表情、反斜杠和样式标签不会被执行。[对应上游界面源码](https://github.com/Syncplay/syncplay/blob/49e2a1bf36e5be1fc397c5bea14bed350609a9ed/syncplay/resources/syncplayintf.lua)

客户端主分支还增加了已观看标记及播放列表相关逻辑。preview.4 已独立实现官方 1.7.6 的房间共享列表，但尚未实现主分支的已观看标记。继续以已发布的 1.7.6 作为实际互通基线，不把未发布主分支直接替换进产品。

## 后续维护方式

每次兼容升级固定上游版本/提交，先检查协议、服务端、客户端同步逻辑及 mpv 适配变化，再按影响补测试。协议和同步变更必须通过未修改官方服务端与客户端的实际联调。更新后的兼容范围写入验证记录；不自动合并上游代码，也不自动更改用户的 mpv 配置。
