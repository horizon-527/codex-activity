# Codex Activity

macOS 菜单栏里的代码符号、彩色状态灯与会话数字。双击 `Codex Activity.app` 启动，点击图标可以查看状态、进行中的会话名称或退出。没有通知、声音或 Dock 图标。当前不会配置登录自启。

- 数字：尚未结束的会话总数，包含等待新记录的会话；空闲隐藏数字。
- 绿色常亮：至少一个未结束的任务，最近 120 秒内有会话记录。
- 黄色：任务尚未结束，但超过 120 秒没有新记录；也可能是长时间思考、工具等待、上下文压缩。不能据此确定卡住。
- 紫色：没有检测到进行中的任务。
- 黄色且菜单提示无法读取：记录目录不存在或无法访问。

每两秒只读 `$CODEX_HOME/sessions`（默认 `~/.codex/sessions`）中的最近两天存档。读取开始、结束和取消事件，支持多个会话。启动时每个文件最多读取末尾 2MB，之后增量读取。另外通过只读 SQLite 连接读取 `state_*.sqlite` 中的会话名称，只在打开菜单时查询。名称不可用时显示会话短编号。没有读取授权凭据、修改 Codex 设置或发送数据。

这是本地活动指示器，不是任务健康保证。它只能覆盖当前用户本机的会话存档，不能显示其他机器或仅在云端执行的任务。记录格式属于 Codex 内部实现，应用升级后可能需要调整。如果日志未记录开始事件或任务不在读取范围内，可能漏检；如果结束事件缺失，会在无新活动后显示黄色。

## 构建与启动

需要 macOS 和 Xcode Command Line Tools（提供 Swift 编译器）。

```sh
git clone git@github.com:horizon-527/codex-activity.git
cd codex-activity
./build.command
open 'Codex Activity.app'
```

如果尚未安装编译工具，可运行 `xcode-select --install`。源码仓库不包含编译产物；构建脚本会创建完整的应用包并进行本地签名。应用退出后，可再次双击启动。

## 源码与验证

`main.swift` 是完整源码，不依赖第三方库。`build.command` 重建并签名应用。

应用可执行文件支持 `--self-test`（任务状态单元验证）和 `--check`（读取真实记录并输出状态）。已验证任务开始、完成、取消、轮次匹配、无新活动、不完整记录、多个会话计数及完成后计数减少。

官方会话存档路径说明：https://learn.chatgpt.com/docs/reference/troubleshooting
