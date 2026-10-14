# 参考项目与来源记录

调研窗口：2026-10-12 至 2026-10-13（America/Los_Angeles）。以下 SHA 是本次只读查询取得的快照，不代表未来最新版本，也不等于已经安装或测试过的版本。

## 用户提供的项目

| 项目 | 分支 | 查询到的 HEAD | 在 splay 中的参考用途 |
| --- | --- | --- | --- |
| [mpv-player/mpv](https://github.com/mpv-player/mpv) | master | `c3ac7f39514c7f45bc38a18e66887240539ee33c` | 插件接口、播放属性与生命周期、Lua 输入和 OSD |
| [dyphire/mpv-config](https://github.com/dyphire/mpv-config/) | master | `132e1982ef47269118bd125b20aefd87dc646ab1` | 整合配置共存、实际配置目录与外部调用场景 |
| [tomasklaen/uosc](https://github.com/tomasklaen/uosc) | main | `12b918fcbcae56ded0e073a965d769bb0c5d900e` | 可选播放器内菜单和按钮接口 |
| [shinchiro/mpv-winbuild-cmake](https://github.com/shinchiro/mpv-winbuild-cmake) | master | `1f8d2e76255abc48f0456d9be99b4cab9c6566e6` | 后续 Windows mpv 及依赖的构建工具链 |
| [dyphire/mpv-winbuild](https://github.com/dyphire/mpv-winbuild) | master | `b770f8d92f89b57629f7a9eb6e41decee6a30ea0` | 后续 GitHub Actions 构建与集成发行流程 |
| [Tony15246/uosc_danmaku](https://github.com/Tony15246/uosc_danmaku) | main | `e1a5b06f76295a27a2427f2d4114ba41da5d8488` | 独立 Lua 插件的目录和 uosc 扩展方式 |

未复制这些项目的播放器配置或弹幕实现。构建仅使用固定版本的 mpv API 头文件并保留其 ISC 许可，来源与校验值在 `third_party/SOURCES.json`。uosc 是可选运行组件；某个整合包附带的 LuaSocket 等组件不作为通用插件的默认前提。

## 关键接口文档

- [mpv C plugins](https://mpv.io/manual/stable/#c-plugins)：DLL 加载、入口、宿主 API 和 Windows 动态符号约定。
- [mpv Lua scripting](https://mpv.io/manual/stable/#lua-scripting)：属性、事件、消息和 OSD。
- [mpv 输入接口](https://mpv.io/manual/stable/#mp-input-functions)：窗口内文本输入和列表选择，具体最低版本待验证。
- [mpv Windows 配置目录](https://mpv.io/manual/stable/#files-on-windows)：整合包安装路径选择。
- [uosc 扩展接口](https://github.com/tomasklaen/uosc/wiki) 与 [Menu API](https://github.com/tomasklaen/uosc/wiki/Menu-API)：版本探测、按钮注册、菜单创建和更新。

## Syncplay 协议参考

- [Syncplay 项目](https://github.com/Syncplay/syncplay)
- [客户端指南](https://syncplay.pl/guide/client/)
- [协议介绍](https://syncplay.pl/about/protocol/)：网页仍标注旧协议版本，不能替代当前实现。
- [protocols.py](https://github.com/Syncplay/syncplay/blob/master/syncplay/protocols.py)：消息格式与握手。
- [client.py](https://github.com/Syncplay/syncplay/blob/master/syncplay/client.py)：同步行为、成员及媒体处理。
- [server.py](https://github.com/Syncplay/syncplay/blob/master/syncplay/server.py)：服务端状态与权限规则。
- [TLS support](https://github.com/Syncplay/syncplay/wiki/TLS-support)：STARTTLS 协商与兼容行为。
- [mpv 适配器](https://github.com/Syncplay/syncplay/blob/master/syncplay/players/mpv.py) 和 [现有 Lua 界面](https://github.com/Syncplay/syncplay/blob/master/syncplay/resources/syncplayintf.lua)：了解现有外部客户端与播放器之间的分工；Lua 文件本身不是完整 Syncplay 客户端。

本次协议互通固定到 [Syncplay v1.7.6](https://github.com/Syncplay/syncplay/tree/v1.7.6)，提交 `993232ab095bb810593459bc705b3e6fc64ad161`；实际运行与下载校验记录见 [验证记录](validation.md)。参考其他项目不代表可以忽略其许可；后续复用组件继续逐项记录来源与许可。
