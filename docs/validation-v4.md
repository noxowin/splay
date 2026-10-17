# v0.1.0-preview.4 验证记录

记录日期：2026-10-15。对应 `v0.1.0-preview.4`，Windows x64 开发预览；不代表稳定或所有整合包均兼容。

## 环境与方法

- Windows 原生 Python 3.12、MinGW-Builds GCC 14.2.0 / UCRT / win32 threads，原生插件重新编译。
- 用户宿主 `mpv v0.41.0-560-g05b327c72` 与 uosc 5.12.0；参考宿主 `v0.41.0-dev-g41f6a6450` 与 uosc 5.13.0。
- 未修改的 Syncplay 1.7.6 服务端与官方客户端；固定源码位于开发环境 `.local/upstream/syncplay-1.7.6`，不打包进产品。
- 所有播放器使用独立配置和合成视频。用户整合包的 uosc 配置只读取或复制到隔离目录，未覆盖原文件，未操作用户已打开的播放器。
- 真正互通测试运行原生 DLL，界面测试分为模拟协议的布局检查和安装四个真实运行文件的联调，分别标明。
- Windows DPAPI 测试必须在具有当前用户密钥访问权限的环境执行；隔离沙箱无法加密时，不将其当成功或改成明文保存。

## 已执行结果

| 范围 | 结果与覆盖 |
| --- | --- |
| 同步核心 | 原生测试通过：主动播放准备、远端应用不准备、受控权限、成员文件过滤、事件去重、列表能力/边界/异常及房间重置 |
| 网络传输 | 测试通过：接收 128 KiB 以内合法多字节列表，拒绝超限输入；已有传输行为回归 |
| 加密凭据 | 原生测试通过：当前用户加解密、跨进程重读、Unicode、host/port 区分、更新/删除、篡改/损坏保留、只读错误及 30 进程并发保存 |
| 密码真实界面 | 两个不同密码的官方服务端、三次 mpv 进程：填写/保存后立即连接、重启免填、换房复用、端口隔离、延迟状态及过期回复、关闭记忆、删除后重启；配置/历史/凭据无明文或 MD5 密码 |
| 共享列表官方互通 | 与官方客户端双向修改/选项、Hello 前快照、250 项/10000 ASCII 字符边界、过大 Unicode 明确拒绝且连接保持、受控权限、房间隔离和重连、异常索引后恢复 |
| 自动准备真实联调 | 远端操作员播放不令普通成员准备；普通成员主动取消暂停自动准备但不越权改变全房播放；再次暂停不自动撤销准备 |
| 四运行文件列表联调 | 双实际 mpv、未改官方服务端；真实原生键盘和 uosc 多级菜单，显式导入只发 basename，初始列表不改媒体/队列，确认后选集、跟随开关、真实 EOF 下一项、无效路径阻止和单 URL 确认 |
| 列表专属 Lua 测试 | 首次状态、未知 URL、已知 URL、文件绑定、控制权限、过期房间/列表回复、文件消失、EOF path 为空、一次推进、旧菜单关闭回调及换房/重连前旧页面动作保护 |
| 布局与鼠标 | native/uosc 两套真实窗口、模拟协议：短时消息过期/去重/数量上限，准备颜色/文件/列表，暂停常显、播放鼠标闲置隐藏、cursor 策略不变，按钮/聊天点击、菜单边界、进度条、窗口缩放、外部 controls 保留；6 类 HTTP(S) 认证信息遮蔽 |
| 历史三次重启 | 实际用户 mpv 通过：历史覆盖默认值、空房间草稿保存、完整组合保留、不自动连接；启用时 Shift+h 打开消息，默认关闭/禁用后恢复宿主快捷键 |
| 主界面表单 | native/uosc smoke、表单回归通过；菜单分层、服务器/端口同排、消息记录、本房成员事件过滤与未知准备状态、密码请求关联与错误处理 |
| 真实聊天/开关 | 两实际 mpv + 官方服务端，原生独立按钮和复制用户 uosc 布局均通过：默认关闭、启用不换片、连接后聊天图标、Enter/发送/Esc、准备/播放提示、换房清理短消息、禁用保持媒体并恢复 Enter |
| 最终安装包 | 21 个白名单文件逐字节匹配、8 个第三方来源哈希、x64 DLL 与许可证校验通过；实际用户 mpv 自动加载 DLL + 3 Lua，默认关闭、原生面板打开并干净退出 |
| 官方 HTTP 完整回归 | 已加载不同鉴权测试地址、错误密码、延迟加入、播放/暂停/跳转、连续六次暂停切换、中文/表情/控制字符聊天、受控房普通/操作员、手动重连、30 秒暂停心跳、停止/重新加载、服务端丢失及继续本地播放均通过 |

真实 uosc 按钮无公开独立矩形接口：完整主界面联调通过其配置的按钮命令进入，再用鼠标点击生产弹出菜单；独立图标使用实际 mpv 鼠标输入点击。共享列表另用真实 uosc 菜单回调与实际原生键盘选项验证。没有把协议模拟测试描述为服务端互通。

## 可复现入口

仓库根目录执行，按本机位置指定播放器、uosc、编译器与官方测试依赖：

```powershell
python tools/build.py build --compiler 'C:\path\to\g++.exe'
python tools/check.py core --compiler 'C:\path\to\g++.exe'
python tools/check.py net --compiler 'C:\path\to\g++.exe'
python tools/check.py history --compiler 'C:\path\to\g++.exe'
python tools/check.py credentials --compiler 'C:\path\to\g++.exe'
python tools/check.py ui
python tests/ui/review.py --mpv 'C:\path\to\mpv.exe'
python tests/ui/overlay_review.py --mode all --mpv 'C:\path\to\mpv.exe' --uosc 'C:\path\to\uosc'
python tests/ui/history_restart.py --mpv 'C:\path\to\mpv.exe'
python tests/integration/credential_ui_path.py --mpv 'C:\path\to\mpv.exe'
python tests/integration/playlist_interop.py --mpv 'C:\path\to\mpv.exe'
python tests/integration/playlist_ui_path.py --mpv 'C:\path\to\mpv.exe' --uosc 'C:\path\to\uosc'
python tests/integration/ui_path.py --mpv 'C:\path\to\mpv.exe'
python tests/integration/ui_path.py --mpv 'C:\path\to\mpv.exe' --uosc 'C:\path\to\uosc' --uosc-config 'C:\path\to\uosc.conf'
python tests/integration/interop.py --mpv 'C:\path\to\mpv.exe' --http
python tools/package.py --output dist/v0.1.0-preview.4/splay-windows-x64-preview4.zip
python tools/verify_release.py --archive dist/v0.1.0-preview.4/splay-windows-x64-preview4.zip --require-license
python tests/ui/package_smoke.py --archive dist/v0.1.0-preview.4/splay-windows-x64-preview4.zip --mpv 'C:\path\to\mpv.exe'
```

`tests/ui/playlist_forms.lua` 使用真实 mpv Lua/JSON 和模拟 mpv 状态运行生产列表适配，可通过 `--script=tests/ui/playlist_forms.lua --script-opts=playlist_forms-source=scripts/splay_playlist.lua --no-config --idle=yes --vo=null --ao=null` 执行。

## 已知限制

- 未完整加载用户整合包的所有脚本，未测试真实浏览器启动/鉴权链、mpv.net、旧版本最低兼容性、直播或带广告时间轴。
- 右栏根据鼠标活动与现有 cursor 选项推断显隐；所测宿主没有可直接观察的 cursor-hidden 属性。其他脚本主动修改光标或特殊控制条需另验。
- 本机文件默认隐藏上报，对方隐藏文件时右栏无法还原真实名称；共享列表需明确添加/导入。本机文件绑定仅当前进程有效。
- 官方 1.7.6 的 Twisted 解析器有 16 KiB 单行限制，完整 Unicode 列表可能先触及该限制；发送前按官方返回编码和实际用户名检查，不仅检查字符数。
- 未用第二个 Windows 账号验证 DPAPI 跨账号拒绝；当前用户往返、端点熵绑定和篡改拒绝已测。跨设备/账号迁移不作为功能保证。
- 消息历史只保留进程内 300 条；不保存聊天文件。列表持久性依赖服务端，跟随换房/重启关闭。
- 密码输入仍可在屏幕和 mpv 当前进程输入历史中出现；DPAPI 保护落盘凭据，不保护正在运行的同用户恶意进程或外部调试日志。
- 未实现全员准备自动开播、自动重连、媒体传输、资源解析或已观看标记。
