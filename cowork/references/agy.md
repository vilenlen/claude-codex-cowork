# agy worker（Antigravity CLI）

## 启动与恢复

- `scripts/dispatch.sh <name> <dir> --worker agy [-m <模型>] [--effort low|medium|high|xhigh] [--resume <conversationId>]`。模型 ID 用 `agy models` 查看（如 `gemini-4-neon-high`、`claude-sonnet-5-5-low`）；省略 `-m` 时沿用 agy 自己 `/model` 保存的模型。不支持 `--search`。
- 脚本由 zsh 加载 `${ZDOTDIR:-$HOME}/.zshrc` 后执行 `agy --add-dir <launch> ...`，遵循用户 `agy` alias。**agy 始终带 `--dangerously-skip-permissions`**：alias／function 已直接写入该旗标时不重复传，否则由 `worker-start.zsh` 补上；新建和恢复都适用。
- `--resume` 转为 `agy --conversation <ID>`，恢复时保留原模型和 effort。
- 首次进入未受信任的目录，agy 会弹出「Do you trust the contents of this project?」。用 `capture.sh` 确认后再决定是否在该窗口按 Enter 信任；输入框底部显示 `? for shortcuts` 且无弹窗时才 `send.sh`。iTerm2／Terminal.app／tmux 下前台进程识别为 `agy`；Orca 依赖其 `agentIdentity`，未识别为 `agy` 时 `send.sh` 会拒绝。

## 等待与结果

- dispatch 在本次 `${TMPDIR:-/tmp}/cowork/launch.*` 下写 `.agents/hooks.json`，并以 `--add-dir` 加入工作区，agy 由此加载会话级 hooks，不修改用户配置。hooks 记录 SessionStart、PreInvocation、PostToolUse、Stop 到同目录 `events.jsonl`，`wait.py` 复用 Claude 的事件判定。
- Stop 的 `terminationReason` 为 `ERROR`／`USER_CANCELED` 或带 `error` 时返回 `aborted`，否则返回 `completed`，最终答复取自 transcript 的最后一条模型回复。
- agy 没有可记录的提问事件，不会返回 `needs_input`。工作中底部显示 `esc to cancel`；事件超过两分钟未更新且不在工作时返回 `stalled`，读屏幕尾部判断是否有弹窗（如 artifact 审阅、信任提示），按代答原则处理后再挂 `wait.py`。
- `SessionStart` 事件中的 `session_id` 即 conversationId，`transcript_path` 为 `~/.gemini/antigravity-cli/brain/<ID>/.system_generated/logs/transcript_full.jsonl`。回收前核对 transcript 存在，交接文件写入恢复命令 `scripts/dispatch.sh <name> <dir> --worker agy -m <model> --resume <ID>`。

接口依据：`agy --help`、`~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md`。
