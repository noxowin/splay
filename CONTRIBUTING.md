# 参与 splay 开发

欢迎提交可复现的问题和有明确范围的改进。先阅读 [安装说明](docs/install.md)、[已知限制](docs/validation-v2.md) 和 [架构](docs/architecture.md)。大改动建议先在 Issue 中说明使用场景、期望行为和验收方式。

## 提交问题

请提供 Windows/mpv/uosc/splay 版本、插件加载的配置目录类型、复现步骤、预期与实际结果。注明是否能够在只加载 splay 的独立配置中复现；不要为了排查删除自己的正常配置。

日志、截图和配置片段提交前移除密码、令牌、私人房间名、本地私人路径、媒体 URL 查询参数和请求头。安全漏洞请按 [SECURITY.md](SECURITY.md) 私下反馈。

## 构建与检查

开发环境需要 Windows x64、Python 3 与 MinGW-w64 GCC。参考环境使用 GCC 14.2.0；CI 使用 MSYS2 UCRT64 GCC，并记录实际版本。构建不下载播放器或官方客户端。

```powershell
python tools/verify_release.py --sources-only
python tools/build.py build --compiler 'C:\path\to\g++.exe'
python tools/check.py core --compiler 'C:\path\to\g++.exe'
python tools/check.py history --compiler 'C:\path\to\g++.exe'
python tools/package.py
python tools/verify_release.py --archive dist/splay-windows-x64-preview2.zip --require-license
```

GitHub Actions 在 push、pull request 和手动触发时执行上述构建、核心/历史测试与产物检查。Actions 下载项是开发构建，不自动成为 Release。工作流使用只读仓库权限，不向来自分支的测试注入发布凭据。

需要保留旧下载包时，可以用 `python tools/package.py --output dist/v0.1.0-preview.2/splay-windows-x64-preview2.zip` 输出到独立目录，再用校验器的 `--archive` 指定该文件。

修改 Lua 界面需要补充原生/uosc 的实际窗口检查；修改协议或同步逻辑需要使用未修改的官方客户端与服务端互通。运行方法、工具固定版本及本地目录安排见 [第一轮](docs/validation.md) 和 [第二轮验证记录](docs/validation-v2.md)。这些测试依赖外部播放器与官方测试工具，未放进默认 CI，也不能用核心单测代替。

## 修改边界

- 保留协议核心、mpv 适配与 Lua 显示的分层。界面文字作为数据处理，不拼接成命令或 ASS 标签。
- 默认断开，不自动连接所有播放器；加入同步不重新打开媒体、不改写调用方参数。
- 只安装 splay 自己的文件，不替换用户的 mpv、uosc 或其他插件配置。
- 不提交 `.local`、构建产物、运行历史、凭据或真实私有媒体地址。
- 更新第三方文件时保留原许可，并同步 `third_party/SOURCES.json` 的来源和原字节校验值。

PR 说明应描述触发问题、修改后的行为、真实执行的验证和仍未覆盖的范围。只运行与改动相关的检查；文档修改检查链接和差异即可，不伪造测试结果。

## 许可证

提交原创贡献表示你有权提交这些内容，并同意按本项目的 GPL-3.0-only 发布。引入第三方代码需说明来源及许可，不能仅凭参考链接复制代码；第三方文件继续保留原许可。无需转让版权。
