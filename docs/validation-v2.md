# 第二轮开发预览验证记录

> 以下为功能验证时的记录。随后仓库获授权以 GPL-3.0-only 公开，公开预发布的包、源码与校验对应见 [发布说明](https://github.com/noxowin/splay/blob/main/docs/releases.md)；公开并不扩大兼容性承诺。

验证日期：2026-10-14。新增连接历史、聊天、状态文字和底部鼠标按钮；第一轮网络/TLS 和同步验证见 [存档](validation.md)。本轮没有修改网络传输与证书校验实现，不把之前的 TLS 测试描述成本轮重跑。

## 环境

| 项目 | 实际环境 |
| --- | --- |
| 构建 | Windows x64，MinGW-w64 GCC 14.2.0，C++17 |
| 参考播放器 | mpv `v0.41.0-dev-g41f6a6450`，uosc 5.13.0 |
| 用户播放器 | `D:/mpv/mcv/mpv.exe`，报告 `v0.41.0-560-g05b327c72`；uosc 5.12.0 |
| 互通基线 | 未修改的官方 Syncplay 1.7.6 服务端和客户端，提交 `993232ab095bb810593459bc705b3e6fc64ad161` |
| 媒体 | 自行生成的 180 秒测试图；HTTP 联调使用本机回环服务与合成参数 |

用户播放器的测试全部使用隔离配置，只加载所需 splay/uosc 脚本，没有改写用户的配置、历史或已安装插件。这验证了其播放器二进制和指定 uosc 的兼容性，不能代表整合包全部脚本、配置和真实浏览器调用链已经验收。

## 已实际通过

| 检查 | 结果与边界 |
| --- | --- |
| 核心与构建 | 单元测试和最终 DLL 构建通过；新增聊天能力、Unicode 码点限长、禁用/离线错误、操作者事件、心跳去重、受控房被拒绝操作不产生活动事件 |
| 原生历史 | 中文路径、独立进程恢复、30 个并发保存进程的合并、组合和字段去重、密码/URL 字段白名单、只保存最后值、损坏文件和只读写入失败保留原文件 |
| 真实重启 | 用户 mpv 自动加载三个运行文件，连续两个进程恢复历史；历史覆盖旧示例配置，完整组合保留，不自动连接 |
| 表单与菜单 | 参考及用户宿主的原生/uosc 入口通过；生产 Lua 表单测试覆盖组合只填表、密码清除、房间修改不立即切房、手动输入、聊天上限、房间/断开清空、最多 100 条、启动历史迟到和停用历史 |
| 显示与鼠标 | 两个宿主各自的原生/uosc 共四种组合通过；准备/聊天/面板按钮、菜单让出区域、隐藏和区域外左键、原生/uosc 进度条点击、TTL、切房、断线、缩小窗口和开关均检查 |
| 显示内容 | 截图审查中文、普通表情、组合表情、百分号、反斜杠、ASS 标签和 NUL 后续文本；标签保持文本，不移动文字或执行样式。表情具体外观由宿主字体决定 |
| 官方互通 | 完整 HTTP 联调通过，包含第一轮同步/权限/重连/媒体脱敏项目，新增官方客户端与插件双向中文聊天、150 码点限长、双向房间隔离、禁聊天仍保持连接、30 秒心跳不刷活动事件 |
| 三文件全链路 | 用户 mpv 的两个真实 splay 实例连接未修改官方服务端，真实 `mp.input` 输入中文/表情并双向收到屏幕消息；状态、准备、播放活动、切房清理、保存历史及默认 Shift+s 均通过。此项的两端是 splay；与官方客户端的互通由上一项单独覆盖 |
| 最终安装包 | 解压新版 ZIP 至独立配置，在参考与用户 mpv 上均自动加载三个运行文件；核心回传状态、屏幕显示初始化、原生面板打开及正常退出均通过 |

鼠标测试通过 mpv 的 `mouse`、`keydown`、`keyup` 走实际输入区域分发，不是直接调用按钮函数；没有声称操作了物理鼠标。屏幕布局人工查看了真实 mpv 截图。原生 UI/uosc 独立界面测试使用模拟核心；三文件全链路和最终包检查使用真实核心，不混淆两者。

本轮发现并修复：历史加载先于 DLL 初始化导致消息丢失、历史回复迟到覆盖早期输入、早期保存重置未编辑字段、不同房间聊天混入、受控房拒绝动作误记为活动、NUL 使 Lua 文本尾部截断，以及连接提示和状态文字重复叠加。

## 证据与复现

本机保留的结果及截图不进入 Git，避免提交瞬态配置与大量二进制：

- 最终官方 HTTP 互通：`.local/integration/20261014-061521-0762ad/result.json`，`passed`。
- 最终三文件全链路：`.local/ui-path/run-eca26f14/result.json`，`passed`；同目录含真实聊天/准备/播放提示和 Shift+s 面板截图。
- 用户宿主显示检查：`.local/v2-overlay-user/`；参考宿主：`.local/v2-overlay-reference/`，各含原生/uosc 截图和日志。
- 重启恢复：`.local/ui-history-restart/run-1.log`、`run-2.log`。

最终 DLL SHA-256：

```text
95a4ebd71b8413707b6ef75992ac9a3543b01027512cf31ca7395d1dfd822991
```

测试依赖、上游下载来源、媒体准备方式同 [第一轮记录](validation.md)。复现命令：

```powershell
python tools/build.py build
python tools/check.py core
python tools/check.py history
python tests/ui/smoke.py
python tests/ui/history_restart.py --mpv D:/mpv/mcv/mpv.exe
python tests/ui/overlay_review.py
python tests/ui/overlay_review.py --mpv D:/mpv/mcv/mpv.exe --uosc D:/mpv/mcv/portable_config/scripts/uosc --output .local/v2-overlay-user
.venv/Scripts/python.exe tests/integration/interop.py --http
python tests/integration/ui_path.py --mpv D:/mpv/mcv/mpv.exe
python tools/package.py
python tests/ui/package_smoke.py
python tests/ui/package_smoke.py --mpv D:/mpv/mcv/mpv.exe
```

`ui_path.py` 会启动本机回环官方服务端、两个播放器并在结束时回收自己的进程；无外部房间操作。`overlay_review.py` 不联网。打包使用明确白名单，不包含播放器、官方客户端、测试日志、用户历史或凭据。包校验值在相邻的 `.zip.sha256` 中。

## 限制

- 仍为 Windows x64 私有开发预览版；最低 mpv 版本、其他系统、mpv.net、完整整合包和浏览器调用尚未全面验证。
- 状态显示提供准备状态、近期播放操作和聊天，不复制官方客户端全部提示类型。准备状态不触发全员自动开播。
- 同步继续限定 1x；弱网、长时间运行、复杂缓冲和不同剪辑时间轴仍需进一步测试。没有新增毫秒级精度承诺。
- 聊天保留本连接当前房间最近 100 条，不存盘；密码不持久化，输入仍在屏幕可见且可能留在当前进程输入历史。
- 特殊控制条的高度可能需要调整 `button_bottom`；组合表情是否呈现彩色、合并字形取决于 Windows 字体，不是跨宿主像素一致保证。
- 官方更新不会自动进入本插件；具体影响和本次主分支审计见 [上游兼容说明](upstream-compatibility.md)。
