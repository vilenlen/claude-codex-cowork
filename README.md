# claude-codex-cowork

让 **Claude Code 当 Team Lead,本机 Codex CLI 当工程师**。Claude 负责澄清需求、拆解任务和验收;编码、调试、测试等重活交给 Codex,在 tmux / iTerm2 的分屏里并行运行。

目的是省 Claude token:Codex 的过程输出不进入 Claude 上下文,Claude 只收到一行终态,再按需读取结论。

## 仓库内容

```
coworker/
├── SKILL.md              # Claude Code skill:委派流程、模型选择、验收规则
└── scripts/
    ├── dispatch.sh       # 在分屏里启动交互式 Codex(只启动,不发任务)
    ├── send.sh           # 以 bracketed paste 向已就绪的窗口发送任务
    ├── wait.py           # 后台等待回合结束或中途提问,只输出一行终态
    ├── answer.sh         # 按键回答 Codex 的阻塞式提问菜单
    ├── capture.sh        # 查看窗口最后 N 行(就绪检查、异常排查)
    ├── iterm.sh          # iTerm2 后端:split / info / send / keys / capture / tty / close
    ├── session-start.sh  # SessionStart hook:在 tmux/iTerm2 中自动启用 Team Lead 模式
    └── selfcheck.sh      # 自检:不启动 Codex,校验后端字节保真与 wait.py 的回合/提问判定
```

## 前置条件

- macOS,Claude Code 与 Codex CLI(`codex`)已安装,并已登录(`codex login status`)
- 在 **tmux** 或 **iTerm2** 中运行 Claude Code;两者都不是时,脚本会创建独立 tmux 会话并输出 attach 命令
- `bash`、`python3`

## 安装

把 `coworker/` 放到 Claude Code 的 skills 目录:

```bash
cp -R coworker ~/.claude/skills/
```

可选:在 `~/.claude/settings.json` 里注册 SessionStart hook,让会话在 tmux/iTerm2 中自动进入 Team Lead 模式(其他环境下该脚本静默退出):

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "bash ~/.claude/skills/coworker/scripts/session-start.sh" }] }
    ]
  }
}
```

安装后运行自检确认环境可用:

```bash
bash ~/.claude/skills/coworker/scripts/selfcheck.sh
```

## 工作流程

在 Claude Code 里说"派给 codex""让 codex 做""并行开几个 codex"等,或启用 hook 后直接提编码类任务,Claude 会按固定顺序执行:

1. **拆解**:写明目标、工作目录、修改边界、必要材料、验收条件,任务正文存为本地文件。
2. **启动**:`dispatch.sh <name> <dir> -m <模型> [--search]`,启动交互式 `codex -a never -s danger-full-access`,返回 `pane=<窗口ID>`。
3. **确认就绪**:`capture.sh <窗口ID> 80`,确认状态栏显示模型名和 `Ready`,无登录、目录信任或模型错误提示。
4. **发送**:`send.sh <窗口ID> <prompt文件>`,引号、反引号、`$()`、多行均按字面传入。
5. **等待**:后台运行 `wait.py <窗口ID>`,它读取 Codex 会话日志,不读窗口内容。回合结束或 Codex 中途提问时输出一行:
   `status=completed|aborted|needs_input|stalled|exited|timeout pane=… elapsed=…s chars=… last=<文件>`
   - `needs_input`:Codex 中途提问,`last=` 文件是问题 JSON。能由已有上下文、已确认决策或仓库约定确定的,Claude 直接作答并说明理由;涉及业务取舍、授权范围、不可逆操作或依据不足的,转给用户选择。阻塞菜单用 `answer.sh <窗口ID> <答案文件>`(每题一行 `<序号> [说明]`),非阻塞提问用 `send.sh` 发消息作答,然后再挂 `wait.py`。
   - `stalled`:日志 2 分钟没有变化且界面不在 `Working`,多半是日志里没有记录的弹窗,`last=` 文件是屏幕末尾 25 行。
6. **验收**:Claude 读取 `last=` 文件并亲自运行检查。结果不符时向原窗口发送反馈,不自行重写。

所有委派都走交互窗口,不使用 `codex exec` 或 `codex app-server`。

## 模型选择

新建窗口必须显式传 `-m`。

| 场景 | 模型 |
|---|---|
| 复杂分析、架构、根因、跨模块实现 | `gpt-6-astra` |
| 简单任务、发布、冒烟、回放验收、结果核对 | `gpt-6.1-sol` |

模型是否可用以交互窗口的实际结果为准,不可用时停下询问,不自行替换。

## 安全说明

- Codex 以 `-a never -s danger-full-access` 启动,即无需审批、拥有完整文件系统访问。只在可信的项目目录中使用。
- 启动参数不等于授权:发布、推送等操作仍需用户明确授权。
- `iterm.sh close` 只能关闭带 worker 标记的窗口。
- 不要把密码、token 等凭据写进任务文件或提交到仓库。

## 常见问题

- **窗口 ID 失效**:窗口关闭后 ID 即失效,`codex` 退出时分屏随之关闭,此时先核实原任务结果再决定重启。
- **TUI 显示与实际输入不一致**:需核对字面内容时查看 `~/.codex/sessions` 下的 rollout 日志。
- **修改脚本后**:重新运行 `selfcheck.sh`。
- **关闭窗口**:iTerm2 用 `scripts/iterm.sh close <UUID>`,tmux 用 `tmux kill-pane -t %N`,先确认结果已取走。

详细规则见 [`coworker/SKILL.md`](coworker/SKILL.md)。
