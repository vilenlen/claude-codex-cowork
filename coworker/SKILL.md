---
name: coworker
description: Team Lead 模式：Claude 拆解任务、做关键决策和验收，先在 tmux、iTerm2 分屏或 Terminal.app 并排窗口启动本机交互式 Codex CLI，再向该窗口发送调查/实现/测试/排障/已授权发布任务。当用户提到"派给 codex""让 codex 做""codex 干活""并行开几个 codex""Team Lead 模式""coworker"时使用；会话运行在 tmux、iTerm2 或 Terminal.app 中时由 SessionStart hook（scripts/session-start.sh）自动启用。
---

# Coworker（Lead + Engineer）

目标：省 Claude token，同时保留业务规则、用户改动和授权边界。

## 分工
- **Claude**：澄清需求、给最少必要上下文、拆分、关键决策、验收。
- **Codex**：调查、实现、测试、排障、已获授权的发布。
- 每次委派写明：**目标、工作目录、修改边界、必要材料、验收条件**。只给完成该任务所需的上下文；复杂任务拆成单一目标的原子步骤。
- 结果不符时向原 Codex 窗口发送反馈继续处理，不自己默默重写。

## 模型
新建窗口显式传 `-m`，漏参启动前报错。续接使用原窗口及其当前模型；需要按阶段切换时，在 Codex 内使用 `/model` 并确认切换成功后再发送任务。

| 场景 | 模型 |
|---|---|
| 复杂分析、架构、根因、跨模块实现 | `gpt-6-astra` |
| 简单任务、发布、冒烟、回放验收、结果核对 | `gpt-6.1-sol` |

每个 Claude 会话首次使用前检查 `codex login status`。模型是否可用以交互窗口实际结果为准；不可用时停下问用户，不自行替换。脚本内一律经 `bash -c` 启动（交互 shell 的 `codex` 可能有别名）。

## 启动后再发任务（固定顺序）
1. 将任务正文写入本地 UTF-8 文件，保留换行，不拼入 shell 命令。**第一行必须是任务标题，且以 `【CC指派】` 开头**（如 `【CC指派】修复登录超时`）；后续补充、验收反馈、新任务同样适用。`send.sh`/`wait.py` 靠首行定位会话日志，所以标题要放在首行且不要留空行在前。
2. 执行 `scripts/dispatch.sh <name> <dir> -m <模型> [--search]`。脚本只启动交互式 `codex -a never -s danger-full-access -m <模型>`，此时不发送任务；记录返回的 `pane=<窗口ID>`（tmux 为 `%N`，iTerm2 为 UUID，Terminal.app 为 `ttysNNN`）。自动识别当前终端：在 tmux 内用 tmux 分屏；否则 iTerm2 内用 iTerm2 分屏；否则 Terminal.app 内为每个 worker 开并排窗口（Terminal 无分屏，需在「系统设置 → 隐私与安全性 → 自动化」允许控制「终端」）；都不是时创建独立 tmux 会话并输出 attach 命令。第一个 worker 在 Claude 右侧，之后的叠在上一个 worker 下方。启动前后按「闲置窗口回收」检查数量。
3. 用 `scripts/capture.sh <窗口ID> 80` 查看该窗口。必须确认状态栏显示模型名和 `Ready`、输入框已就绪，且没有登录、目录信任、模型错误或其他待处理提示；启动失败或状态不明时不要发送任务。尚在启动时可短暂等待后再确认，不能仅凭固定延时认定就绪。
4. 执行 `scripts/send.sh <窗口ID> <prompt文件>`，以 bracketed paste 向已启动的 Codex 窗口粘贴完整任务，再按 Enter 提交。任务中的引号、反引号、`$()` 和多行正文必须按字面传入。
5. 补充材料、验收反馈和后续任务仍发送到原 `<窗口ID>` 窗口；发送前确认上一轮已结束且输入框可用。窗口退出时先核实原任务结果，再按「恢复已关闭的窗口」恢复会话，或重新启动。

**所有委派均走交互窗口。不得用 `codex exec`、`codex app-server`、stdin 重定向或启动命令的位置参数代替“先启动、再发消息”。**

## 闲置窗口回收
- 新建或恢复 worker 前后、收到回合终态并取走结果后，清点本次 Lead 会话管理的仍存活 worker；不计 Lead 自身，不操作用户其他窗口。旁边的分屏（Terminal.app 为并排窗口）**超过 4 个**，或本次新建会超过 4 个时，主动检查可回收项，无需再次询问用户。
- 只回收任务已完成、结果已取走、近期无续接任务且当前输入框空闲的 worker，优先关闭最久未使用的。不能仅凭窗口安静、`Ready` 或旧的 `completed` 判断闲置；核对最新一轮状态，必要时用一次 `capture.sh <窗口ID> 15` 确认。正在工作、等待回答、状态不明、有未处理异常或仍有后台任务的窗口保留。
- **先保存恢复信息，再关闭**：核对对应的本地 rollout 日志确实存在、会话 UUID 与该 worker 匹配，并把 name、原工作目录、当前模型、`--search` 设置、会话 UUID、旧窗口 ID、任务标题、结果路径及完整恢复命令写入本地交接文件，向用户提供文件路径。无法确认会话可恢复时跳过，不靠关闭后再搜索碰运气；保留日志和结果文件。
- 关闭前再次确认窗口仍属于本次会话且仍闲置；iTerm2 / Terminal.app 用下方带 worker 标记保护的关闭命令，tmux 先核对 `@coworker` 标记和记录的窗口 ID 再 `kill-pane`。关闭后将交接记录标为已关闭，旧 ID 作废。
- 有合适项就关一些，尽量降到 4 个（若马上新建，先预留一个位置）；没有合适项就保留现状，4 个是回收触发线，不是强制并发上限。后续需要该 worker 时按保存的命令恢复上下文，不重新派发已经完成的任务。

## 恢复已关闭的窗口
- 优先使用回收时保存的会话 UUID 和恢复命令。没有记录时，用任务标题查会话：`rg -l -F -- '<任务标题>' ~/.codex/sessions`。文件名 `rollout-<时间>-<UUID>.jsonl` 末尾的 UUID 即会话 UUID；搜索命中后核对工作目录和任务内容，多条匹配时不能直接把最后一条当作目标。
- 执行 `scripts/dispatch.sh <name> <原工作目录> -m <原模型> --resume <UUID>`，在新分屏恢复原会话及上下文；可同时传 `--search`，两个可选参数顺序不限，`-m` 仍必填。
- 记录新返回的窗口 ID，旧 ID 作废；按原流程用 `capture.sh` 确认 `Ready`，再用 `send.sh` 发任务并立即挂 `wait.py`。
- 同一会话不要同时开两个窗口。

## 等待与结果（省 token 是本 skill 的目的）
Codex 的过程输出不进 Claude 上下文。等待交给后台脚本，Claude 只收一行终态，再按需读结论。
- 每次 `send.sh`（含作答）和 `answer.sh` 之后，立即用 Bash `run_in_background: true` 执行 `scripts/wait.py <窗口ID> [超时秒数=3600]`。它读 Codex 会话日志，不读窗口内容，等待期间不消耗 token；回合结束或 Codex 中途提问时自动唤醒 Claude，只输出一行：
  `status=completed|aborted|needs_input|stalled|exited|timeout pane=… elapsed=…s chars=… last=<文件>`
- 禁止用 Monitor 跟踪窗口、`sleep` 循环 `capture.sh`、或反复查看窗口来等完成；这些都会把 Codex 输出持续灌进上下文。
- 一个窗口同一时间只挂一个 `wait.py`；并行多个 Codex 时每个窗口各挂一个。等待期间推进独立工作，没有就告诉用户 Codex 仍在运行并交还控制。
- `completed`：最终答复已写入 `last=` 文件。先看 `chars=`，短的直接读；长的用 `head`/`grep` 取需要的部分。要求 Codex 在最终答复里只给结论、改动文件、验证命令与结果，详情写入指定的 `result.md`，验收时按需读。
- `needs_input`：Codex 在回合中途提问，回合仍挂起，见下方「Codex 中途提问」。
- `stalled`：日志超过 2 分钟没有变化，界面也不在 `Working`，多半是日志里没有记录的弹窗（如 MCP 授权、意外菜单）。`last=` 文件里是屏幕末尾 25 行，读它判断原因：能按「代答原则」处理的就处理，不能的转给用户。处理后再挂 `wait.py`。
- `aborted` / `exited`：读一次 `capture.sh <窗口ID> 30` 判断原因，再决定续接或重启。
- `timeout`：任务可能仍在跑。用 `capture.sh <窗口ID> 15` 看一眼状态行，确认在推进就再挂一次 `wait.py`（同一回合可重复等）。
- `capture.sh` 只用于启动就绪检查、异常排查和偶发进度抽查，总是带小行数。验收以 `last=` 文件、`result.md` 和你亲自运行的检查为准，不以窗口画面为准。
- 失败或中断：报告实际原因，带具体反馈续接原窗口。需要用户回答时保留问题与窗口，收到回答后续接。
- 对同一回合重跑 `wait.py` 会再次返回已有终态，可以用它重复读取结果。
- 状态未知：先核实原操作是否已生效，再决定重试，避免重复发布或写入。
- 启动固定使用用户要求的 `-a never -s danger-full-access`；具体任务仍遵守已有授权范围，发布、推送等操作不因启动参数而自动获得授权。

## Codex 中途提问（needs_input）
`last=` 文件是一行 JSON：`kind`、`call_id`、`questions`（题目、选项、说明）。按 `kind` 作答：

| kind | 界面 | 作答方式 |
|---|---|---|
| `blocking` | 选项菜单，回合阻塞（Plan 模式的 `request_user_input`） | `scripts/answer.sh <窗口ID> <答案文件>`：每题一行，按题目顺序写 `<选项序号>` 或 `<选项序号> <说明>`。选项都不合适时，选最后一项 None of the above，把文字写进说明 |
| `async` | 问题挂在界面上，Codex 边等边做 | 用 `send.sh` 发一条普通消息作答，消息里引用问题原文 |
| `message` | Codex 主动通报阻塞或发现，不一定要回复 | 需要纠偏就用 `send.sh` 回复，否则直接再挂 `wait.py` |

作答后立即再挂 `wait.py`。已报告过的提问不会重复报告，同一回合的结束仍能等到。

**代答原则**：Claude 是 Team Lead，能替用户拍板的就直接拍板，不能确定的才问人。
- 直接决定：答案已由用户需求、已确认决策、仓库现有约定或任务的修改边界明确；或者属于纯技术取舍、可回退、只影响本次实现的细节（命名、库内用法、测试写法、实现路径），此时选最符合现有代码与约定的一项。作答时附一句理由。优先采纳 Codex 标注的推荐项，除非它与上下文冲突。
- 必须问人：涉及业务规则或产品取舍、超出已授权范围（发布、推送、删除数据、改动边界外的文件、花钱）、不可逆操作、安全或合规、需求本身有歧义，或 Claude 没有足够依据判断。
- 问人时用 AskUserQuestion，原样带上 Codex 的问题和选项，写明 Claude 的推荐和理由；窗口保持挂起，不替用户选。拿到回答后用同样的方式转给 Codex，再挂 `wait.py`。
- 每次代答都记进阶段交接（问题、所选答案、理由），方便用户事后复核。

## 窗口注意事项
- 窗口 ID 在窗口关闭后失效；`codex` 退出时分屏随之关闭，发送和查看会报错。先核实原任务结果，再按「恢复已关闭的窗口」恢复会话，或重新启动。
- Codex TUI 的显示可能与实际输入不同（如吞掉 `\\n`、把反引号渲染掉）；需核对字面内容时查 `~/.codex/sessions` 下的 rollout 日志。
- 任务结束后关闭窗口：iTerm2 用 `scripts/iterm.sh close <UUID>`，Terminal.app 用 `scripts/terminal.sh close <ttysNNN>`（均只能关闭带 worker 标记的窗口；Terminal 会先结束窗口内进程，避免弹确认框），tmux 用 `tmux kill-pane -t %N`。先确认结果已取走，并按「闲置窗口回收」保存恢复信息。
- 修改脚本后运行 `scripts/selfcheck.sh`，它不启动 Codex，校验 `wait.py` 的回合与提问判定，以及当前可用后端（tmux、iTerm2、Terminal.app）的字节保真、读取和标记保护。

## 交接与汇报
- 阶段结束留精简交接：目标、已确认决策、完成项、待办、窗口/会话标识、证据路径。历史过长按阶段压缩或用交接摘要开新会话。
- 未完成验收前不声称完成。最终只汇报：完成内容、关键验证、遗留问题、需用户决策事项。
