# v0.1.0-preview.6 验证记录

记录日期：2026-10-19。Windows x64 开发预览；真实协议互通与模拟状态界面检查分开记录。

## 环境与范围

- Windows 原生 Python 3.12、MinGW-Builds GCC 14.2.0 / UCRT。
- mpv `v0.41.0-dev-g41f6a6450`、uosc 5.13.0，未修改的 Syncplay 1.7.6 客户端和服务端。
- 全部使用隔离配置、合成视频、临时房间与测试密码；未读取或修改私人播放器配置。浏览器调用链按本轮范围排除。

## 本轮结果

下表检查已通过；界面用例使用实际 mpv 窗口与模拟协议状态，官方互通用例使用真实本地服务端与官方客户端。

| 范围 | 本轮覆盖 |
| --- | --- |
| 自动开播核心 | 默认关闭、完整成员快照、人数/准备/媒体/权限门槛、到期复核、取消与重新准备、防止同阶段重复启动；成功后的服务器 echo 保留成功状态，手动暂停仍阻止重播 |
| 官方自动开播互通 | 两台真实 mpv 与官方客户端：倒计时实际开播、时钟前进、取消、准备撤回/重新准备、成员离开、官方先播放、本机跳转/换片/停止、换房和断线重置、受控房权限与认证、服务器重启后重连 |
| 同片检查 | 双方时长、正负差值、2.5 秒边界、名称相同/不同/隐藏、未知与非法时长、网络标题回退、媒体生命周期；结果仅显示，不上传本机标题或控制播放 |
| 菜单与显示 | 原生/uosc 入口与表单、加入/创建流程、连接摘要、可滚动成员详情、按钮菜单宽度与溢出入口；延迟同行、文件两行、倒计时与取消、消息不按秒刷屏、鼠标闲置与暂停显示 |
| 连接组合与密码 | 真实 Windows 遮罩输入和当前用户 DPAPI；保存/选择删除组合不影响密码或当前媒体，重启复用、端口隔离、取消输入、快速保存连接、错误与删除重启路径 |
| 播放与聊天回归 | 官方客户端完整 HTTP 联调：晚加入、不同调用地址、错误密码、双向播放/暂停/跳转/聊天、受控权限、手动重连、30 秒暂停心跳、停止重载、服务器丢失后本地播放 |
| 共享播放列表回归 | 安装四个运行文件，原生/uosc 入口、实际服务器与本地合成媒体；显式跟随、选集、EOF 下一项与当前媒体保留 |

最终包按独立白名单逐字节校验四个运行文件、许可证与文档，x64 DLL、第三方来源哈希和 ZIP SHA-256 检查通过；从 ZIP 解压至隔离配置后，四个文件自动加载、原生面板打开和正常退出均通过。

未修改模块的详细历史覆盖见 [preview.5 验证存档](https://github.com/noxowin/splay/blob/v0.1.0-preview.5/docs/validation-v5.md)，不将旧版测试重复计为本轮执行。

## 复现入口

先按 [贡献指南](https://github.com/noxowin/splay/blob/v0.1.0-preview.6/CONTRIBUTING.md) 准备编译器、mpv/uosc、官方源码与测试依赖。可配置路径的脚本用 `--help` 查看参数；测试输出写入忽略目录 `.local`。

```powershell
python tools/build.py build
python tools/check.py core
python tools/check.py autostart
python tests/integration/autostart_interop.py
python tests/integration/interop.py --http
python tests/integration/credential_ui_path.py
python tests/integration/playlist_ui_path.py
python tests/ui/smoke.py
python tests/ui/latency_overlay.py
python tests/ui/overlay_review.py --mode all
python tools/package.py --output dist/v0.1.0-preview.6/splay-windows-x64-preview6.zip
python tools/verify_release.py --archive dist/v0.1.0-preview.6/splay-windows-x64-preview6.zip --require-license
python tests/ui/package_smoke.py --archive dist/v0.1.0-preview.6/splay-windows-x64-preview6.zip
```

## 限制

- 自动开播由开启该选项的本机发起，建议同房仅一人开启；没有跨客户端主机选举或全局唯一计时器。换房、断开、重连后需重新开启。
- 同片检查只比较名称与时长，不能证明内容、剪辑或音轨一致；默认隐藏名称时通常只能比较时长。未知信息不判定相同，也不强制阻止播放。
- 网络流不能保证获取影视标题，不抓取网站或解析资源。媒体传输、已观看标记尚未实现。
- 延迟是到服务器的往返估计，不是用户间直连延迟；其他成员需使用支持上报的 splay，官方客户端未上报，且数据属于自报。
- DPAPI 记忆限当前 Windows 用户，未用第二个账号测试；不保证跨账号或设备迁移。共享列表不传输视频，本机跟随默认关闭，陌生 URL 逐项确认。
- 浏览器启动/鉴权链、完整整合包、mpv.net、最低兼容版本、直播和广告时间轴不在本轮覆盖范围。
