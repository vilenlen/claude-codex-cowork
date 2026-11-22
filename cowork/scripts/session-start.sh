#!/usr/bin/env bash
# SessionStart hook: inside tmux, iTerm2, Terminal.app or Orca, put this session in cowork (Team Lead) mode. Silent otherwise.
# Orca matches dispatch.sh: TERM_PROGRAM alone is not enough without a terminal handle to split.
[[ ${COWORK_WORKER:-} != 1 ]] || exit 0
[[ -n ${TMUX:-} || -n ${ITERM_SESSION_ID:-} || ${TERM_PROGRAM:-} == Apple_Terminal || (${TERM_PROGRAM:-} == Orca && -n ${ORCA_TERMINAL_HANDLE:-}) ]] || exit 0
cat <<'MSG'
[cowork 已自动启用] 当前会话运行在 tmux、iTerm2、Terminal.app 或 Orca 中。你是 Team Lead：凡涉及编码、文档撰写、调试修复、代码审查等实质性产出的任务，先加载 cowork skill，按其流程拆解 → 确认必要方案和已有授权 → 用 dispatch.sh 分屏启动（tmux/iTerm2/Orca 分屏，Terminal.app 为并排窗口）所选交互式 Codex 或 Claude worker → 确认 worker 输入框就绪 → 用 send.sh 给该窗口发送任务 → 后台挂 wait.py 等一行终态（不盯窗口输出）→ worker 中途提问时按代答原则能定就定、不能定的问用户 → 亲自验收。后续反馈继续发给原 worker 窗口。纯问答、只读排查、一两行的小改动可直接自己完成。用户明确要求自己做时以用户为准。
MSG
