# 第三轮验证：图标入口、默认关闭与聊天快捷键

日期：2026-10-14。版本：`v0.1.0-preview.3`，Windows x64 开发预览。

## 构建与环境

- 本机 MinGW-Builds GCC 14.2.0，C++17；Windows 原生 Python 3.12。
- 本轮重新编译的 DLL SHA-256：`024a926e4c1392d3723a1d2a5e78ba04d15fe4d02ef6d1b2509df5e20d35a062`。
- 参考 mpv：`v0.41.0-dev-g41f6a6450`。用户整合包的 mpv：`v0.41.0-560-g05b327c72`。
- uosc 5.12.0 和 5.13.0；本轮使用独立配置目录，仅复制控制条布局参数，不加载整合包的其他脚本。
- 未修改的官方 Syncplay 1.7.6 客户端与服务端；服务仅监听回环地址，使用合成测试视频与测试房间。

## 已完成的检查

- 同步核心测试通过。原生历史专项测试通过：空房间草稿的跨进程恢复、完整组合拒绝空房间、历史值不保存空房间、旧自定义值保留、秘密字段白名单、损坏/只读文件保护，以及并发保存合并。
- 新 DLL 与真实 Lua 在三个独立 mpv 进程中完成历史恢复：先恢复完整组合，再清空房间，第三次启动恢复空房间草稿并继续修改昵称。已有完整组合和房间历史保留；每次启动均为关闭、未连接。
- UI 原生/uosc 入口检查 2/2 通过，表单回归通过。覆盖默认关闭、启用、空房间阻止连接、历史迁移、条件式 Enter 绑定、菜单输入让行以及聊天会话切换保护。
- 主菜单可视检查 8/8 通过：原生与 uosc 分别检查关闭首页、开启首页、连接设置与设置页。首页最多六项，字段移入独立页面。
- 新 DLL 与官方客户端、服务端的 HTTP 媒体联调通过：双向播放/暂停/跳转、连续暂停切换、晚加入、成员准备、受控房间与认证、双向中文/特殊字符聊天、聊天长度和禁用协商、房间隔离、手动重连、30 秒暂停心跳、服务丢失后继续本地播放、媒体地址保护。

## 本轮界面与端到端验收

- 覆盖层实窗检查在原生 mpv 与用户 uosc 5.12.0 布局下通过。真实图标点击、菜单第一项开关、菜单项点击、Esc、菜单外点击、进度条跳转、其他菜单让行、窗口缩放、状态隐藏、聊天到期、NUL/ASS 文本转义及房间切换均有断言。
- uosc 自动插入仅增加一个 `button:splay`，其余原始控件顺序不变。晚于插件的运行时布局修改仍被保留；隐藏插件按钮时恢复该布局，不覆盖其他脚本选项。用户配置原文件的 SHA-256 在测试前后相同。
- 两个完整生产插件实例与官方服务器的端到端路径，在原生界面和用户 uosc 5.12.0 配置下分别通过：默认关闭、菜单启用、Enter 聊天、Enter 发送、Esc 取消、菜单点击进入聊天、双向中文/表情消息、准备和播放提示、房间切换与历史记录。
- 两个实例均从已连接状态关闭 splay 后，状态/聊天清空、同步断开，原有媒体及暂停值保持，Enter 恢复显式配置的全屏动作。测试未以模拟核心代替此路径。
- 对真实生产菜单和控制条截图进行目视检查，并补测鼠标位于时间轴时打开菜单，确认菜单下缘位于控制条上方。原生界面测试另修正了全屏切换后测试光标使用旧窗口尺寸的时序问题。

生产路径中的原生图标和全部菜单项由实际鼠标输入事件触发。uosc 完整生产路径通过该图标配置的消息打开菜单，再实际点击菜单项；uosc 图标本身的真实点击另由覆盖层实窗检查完成。后者使用模拟状态，不作为协议互通证据。

安装包检查通过：19 个白名单文件与打包输入一致，8 个第三方原始文件哈希匹配，DLL 为 Windows x64，许可证、声明与 ZIP 校验文件齐全。解压到隔离配置后，三个运行文件自动加载、原生菜单打开、默认关闭且不显示状态，退出时正常清理。

本地记录分别保存在 `.local/v3-overlay-final`、`.local/ui-path/run-fb62258a`（原生）、`.local/ui-path/run-05dad90b`（uosc）、`.local/ui-history-restart`、`.local/package-smoke` 和 `.local/integration/20261014-224127-b06d1b`；这些开发产物不提交到仓库。

## 可复查命令

```powershell
python tools/build.py build --compiler 'C:\Program Files\mingw64\bin\g++.exe'
python tools/check.py core
python tools/check.py history
python tests/ui/smoke.py --mpv 'D:\mpv\mcv\mpv.exe'
python tests/ui/review.py --mpv 'D:\mpv\mcv\mpv.exe'
python tests/ui/history_restart.py --mpv 'D:\mpv\mcv\mpv.exe'
python tests/ui/overlay_review.py --mpv 'D:\mpv\mcv\mpv.exe' --uosc 'D:\mpv\mcv\portable_config\scripts\uosc' --output .local/v3-overlay
python tests/integration/ui_path.py --mpv 'D:\mpv\mcv\mpv.exe'
python tests/integration/ui_path.py --mpv 'D:\mpv\mcv\mpv.exe' --uosc 'D:\mpv\mcv\portable_config\scripts\uosc' --uosc-config 'D:\mpv\mcv\portable_config\script-opts\uosc.conf'
python tests/integration/interop.py --http
python tools/package.py --output dist/v0.1.0-preview.3/splay-windows-x64-preview3.zip
python tools/verify_release.py --archive dist/v0.1.0-preview.3/splay-windows-x64-preview3.zip --require-license
python tests/ui/package_smoke.py --mpv 'D:\mpv\mcv\mpv.exe' --archive dist/v0.1.0-preview.3/splay-windows-x64-preview3.zip
```

播放器路径需换为自己的开发环境；不应向正在使用的配置目录安装测试夹具。测试使用 mpv 实际输入事件和截图，不代表物理鼠标自动化或完整浏览器调用链已经验证。

## 范围与限制

本轮未运行用户整合包的所有其他脚本，也未覆盖所有 uosc 自定义布局、mpv.net 或最低兼容版本。无法读取 uosc 控制条定义时采用独立图标，不猜测其他按钮的位置。

全员准备仍不自动触发播放；共享播放列表、自动获取媒体、自动重连、不同剪辑/广告时间轴、直播和平台鉴权不在本版范围内。同步、TLS 与媒体的其他约束仍见 [前轮记录](validation-v2.md) 和 [安装说明](install.md)。
