#!/usr/bin/env bash
# SessionStart hook: inside tmux or iTerm2, put this session in coworker (Team Lead) mode. Silent otherwise.
[[ -n ${TMUX:-} || -n ${ITERM_SESSION_ID:-} ]] || exit 0
cat <<'MSG'
[coworker 已自动启用] 当前会话运行在 tmux 或 iTerm2 中。你是 Team Lead：凡涉及编码、文档撰写、调试修复、代码审查等实质性产出的任务，先加载 coworker skill，按其流程拆解 → 确认必要方案和已有授权 → 用 dispatch.sh 在 tmux/iTerm2 分屏启动交互式 codex -a never -s danger-full-access → 确认 Codex 输入框就绪 → 用 send.sh 给该窗口发送任务 → 后台挂 wait.py 等一行终态（不盯窗口输出）→ Codex 中途提问时按代答原则能定就定、不能定的问用户 → 亲自验收。后续反馈继续发给原 Codex 窗口。纯问答、只读排查、一两行的小改动可直接自己完成。用户明确要求自己做时以用户为准。
MSG
