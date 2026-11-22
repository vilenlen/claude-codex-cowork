# Claude worker

## 启动与恢复

- 首次使用检查 `claude auth status`；显式选模型，如 `sonnet`、`opus` 或用户提供的模型 ID。不可用时报告实际错误，不自行换模型。
- `scripts/dispatch.sh <name> <dir> -m sonnet --worker claude [--effort low|medium|high|xhigh] [--resume UUID]`。可改为 `--worker claude-glink` 显式启动 claude-glink；两者共用 Claude 事件协议。模型路由由用户入口控制，保留其配置。不支持 `--search`，搜索使用 Claude 已配置的工具。
- 脚本由 zsh 加载 `${ZDOTDIR:-$HOME}/.zshrc` 后执行 `claude --model ... --settings ...`，遵循别名（例如 `claude-glink --dangerously-skip-permissions`）和环境设置；仅对子进程清除 `CLAUDECODE` 嵌套标记。`COWORK_WORKER=1` 使本技能的 SessionStart hook 保持静默，避免 worker 递归变成 Lead。
- 用 `capture.sh` 确认输入框、模型和目录，先处理登录、信任或其他弹窗，再用 `send.sh` 发送任务。Claude 界面无需出现 Codex 的 `Ready` 字样。iTerm2/Terminal.app 发送时要求前台进程识别为 `claude`，不以泛化的 `node` 进程作为就绪依据；Orca 分屏要求 `agentIdentity` 已识别为 `claude`（启动中为空，`send.sh` 会拒绝并提示稍候）。
- 每次启动创建独立的 `${TMPDIR:-/tmp}/cowork/launch.*` 目录，`<pane>.worker` 记录 worker 类型和该目录。保留目录直到结果和恢复信息取走。

## 等待与提问

`wait.py` 读取该目录的 `events.jsonl`。会话级 hooks 记录 SessionStart、UserPromptSubmit、Stop、StopFailure、工具执行及权限通知。Stop 返回 `completed` 和最终文本，StopFailure 返回 `aborted`。旧回合事件不会满足新发送的等待。hook 的 Stop 是回合停止信号；若其他自定义 Stop hook 阻止停止，仍需核实界面和验收证据，不能据此直接关闭窗口。

- `needs_input` 的 `kind=claude_menu` 表示 AskUserQuestion，`kind=claude_permission` 表示权限或外部交互请求。读取问题后按代答原则决策；用一次 `capture.sh` 查看菜单，再通过后端 `keys` 或 tmux `send-keys` 操作实际菜单。不使用仅适配 Codex 菜单的 `answer.sh`，也不把普通消息粘贴进选择菜单。回答后重新挂 `wait.py`。
- `stalled` 仅表示事件超过两分钟未更新，需要看返回的屏幕尾部判断；长工具调用也可能触发，不能据此断定失败。仍在运行则继续等待。用户或组织禁用 hooks 时，不会得到可靠完成事件，报告限制并检查界面，不伪造完成。
- `completed` 后仍按文件和测试结果验收。最终回答中的问题可在确认普通输入框可用后用 `send.sh` 回复。
- `SessionStart` 事件中有 `session_id`、`transcript_path` 和 `cwd`。回收前核对 transcript 确实存在，将 worker 类型、模型、UUID、工作目录、结果路径及恢复命令保存到交接文件：`scripts/dispatch.sh <name> <dir> -m <model> --worker claude --resume <UUID>`。恢复时保留原 `--worker claude` 或 `--worker claude-glink` 入口以及 effort 等设置，不要同一会话同时恢复到多个窗口。

接口依据：[Claude CLI](https://code.claude.com/docs/en/cli-reference)、[Hooks](https://code.claude.com/docs/en/hooks)。
