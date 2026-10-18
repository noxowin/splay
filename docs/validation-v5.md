# v0.1.0-preview.5 验证记录

记录日期：2026-10-17。Windows x64 开发预览；下面区分真实互通、模拟协议界面与未验证范围。

## 环境

- Windows 原生 Python 3.12、MinGW-Builds GCC 14.2.0 / UCRT；测试使用本次编译的插件。
- 参考播放器 `mpv v0.41.0-dev-g41f6a6450`、uosc 5.13.0，未修改的 Syncplay 1.7.6 服务端与官方客户端。
- 独立配置、合成视频、临时测试账号和密码。没有复制或修改用户私人配置；浏览器调用链按本轮范围排除。
- 密码记忆联调在正常 Windows 用户环境执行，以验证真实 DPAPI；不以沙箱权限错误替代加密成功。

## 本轮结果

| 范围 | 覆盖与结果 |
| --- | --- |
| 自动重连 | 原生策略测试及实际 mpv 联调通过：默认不连接、2/5/10/30/30 秒重试、完整五次耗尽、手动断开/禁用取消、切换连接隔离、错误密码及 TLS 证书失败不重试或降级 |
| 官方服务端重启 | 带密码的官方服务端重启后恢复实际受控房间；准备与操作员权限重置，当前媒体、位置、暂停及 1.25x 参数保留 |
| 延迟核心 | 默认关闭、有效心跳采样、服务器处理时间扣除、平滑 RTT、非法/重复数据、30 秒过期、换房/重连清理、关闭撤回及无媒体行为通过 |
| 延迟官方互通 | 两个真实 splay 与官方客户端共存：获取各自 RTT、周期分享、官方成员标为未上报；官方文件变更提示次数不增长，成员/准备/跳转继续正常，关闭及无媒体撤回通过 |
| 连接历史 | 命名/删除组合、字段建议清理、清空历史、旧格式读取、无效输入保留原文件，以及多实例并发修改测试通过 |
| HTTP 完整回归 | 官方客户端与真实 mpv：不同鉴权测试地址、错误密码、延迟加入、播放/暂停/跳转、连续暂停切换、聊天、受控房权限、手动重连、30 秒暂停心跳、停止/重新加载、服务器丢失后本地播放均通过 |
| 延迟界面 | 真实 mpv 窗口、模拟状态：默认隐藏、自己与成员数值、未上报、测量中、过期和无效数据回退通过；此项不是网络测量验证 |
| 遮罩密码与记忆 | 真实 Windows 输入框及三个新 mpv 进程通过：Unicode、Enter/Esc/关闭、替换与退出、过长输入拒绝；DPAPI 保存后立即连接、重启免填、换房复用、端口隔离、临时密码复用、删除、受控房创建/认证及错误后重开；未将明文或 MD5 写入配置/历史/日志 |
| 主界面 | 原生/uosc 入口与表单回归通过；输入提交后等待旧输入关闭再进入下一页，避免上一页关闭事件取消新表单；过期回复、取消、历史管理和延迟开关通过 |
| 布局与鼠标 | 原生/uosc 真实窗口、模拟协议均通过：七项菜单完整显示和末项点击、消息过期、准备颜色、文件与共享列表、暂停常显/播放闲置隐藏、聊天入口、进度条操作、窗口缩放及外部 controls 保留 |

安装包按独立白名单逐字节校验四个运行文件、许可证及说明文档，同时检查 x64 DLL、第三方来源哈希和 ZIP SHA-256；再将 ZIP 解压到隔离配置，使用实际 mpv 自动加载四文件、打开原生面板并退出。发布仅在这些检查通过后进行。

上一版覆盖的共享列表和显示行为见 [preview.4 验证存档](https://github.com/noxowin/splay/blob/v0.1.0-preview.4/docs/validation-v4.md)，不将历史结果重复计为本轮执行。

## 复现入口

先按 [贡献指南](https://github.com/noxowin/splay/blob/v0.1.0-preview.5/CONTRIBUTING.md) 准备编译器、mpv/uosc 与官方测试依赖。下面从仓库根目录运行；可配置路径的脚本用 `--help` 查看 `--mpv`、`--uosc` 等参数，其余使用指南中的约定位置。本地测试文件只写入忽略目录 `.local`。

```powershell
python tools/build.py build
python tools/check.py core
python tools/check.py reconnect
python tools/check.py latency
python tools/check.py history
python tools/check.py credentials
python tools/check.py net
python tools/check.py tls-rejection
python tools/check.py ui
python tests/integration/secret_input_native.py
python tests/integration/credential_ui_path.py
python tests/integration/reconnect_path.py --exhaustion
python tests/integration/reconnect_official.py
python tests/integration/latency_interop.py
python tests/integration/interop.py --http
python tests/ui/latency_overlay.py
python tests/ui/overlay_review.py --mode all
python tools/package.py --output dist/v0.1.0-preview.5/splay-windows-x64-preview5.zip
python tools/verify_release.py --archive dist/v0.1.0-preview.5/splay-windows-x64-preview5.zip --require-license
python tests/ui/package_smoke.py --archive dist/v0.1.0-preview.5/splay-windows-x64-preview5.zip
```

## 边界与限制

- 延迟是客户端至服务器的往返估计，不是用户之间的直连延迟。官方协议不提供其他成员的 RTT；对方须使用支持该功能的 splay 并开启共享，数值属于自报。
- 延迟分享附在现有文件元数据上，约每 10 秒一次；未载入媒体时不伪造文件。界面只显示本房间，服务端的房间隔离策略决定元数据可见范围。
- 自动重连仅重试临时网络故障，不恢复操作员认证、准备状态或本机列表跟随。五次失败后需主动再连接。
- 浏览器启动/鉴权链、完整整合包、mpv.net、最低兼容版本、直播和带广告时间轴不在本轮覆盖范围。
- DPAPI 记忆限当前 Windows 用户；未用第二个账号验证拒绝，跨设备或账号迁移不作保证。遮罩输入不保护同用户恶意进程，显式自动化 API 的调用方仍需避免记录密码。
- 本机文件默认隐藏上报，共享列表需明确添加或导入；陌生 URL 需确认。本机绑定及最多 300 条消息仅进程内保存。
- 尚未实现全员准备自动开播、媒体传输、资源解析或已观看标记。
