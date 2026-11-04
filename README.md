# claude-codex-cowork

让 **Claude Code 当 Team Lead，本机 Codex CLI 当工程师**。Claude 拆解任务、选择模型、协调进度和验收；Codex 在旁边的终端窗口里完成调查、编码、测试与排障。

Skill 名称是 **`coworker`**，在 Claude Code 中用 `/coworker` 调用。

## 能做什么

- **分屏协作**：支持 tmux、iTerm2 分屏和 Terminal.app 并排窗口，可同时安排多个 Codex 处理独立任务。
- **节省 Claude 上下文**：后台等待 Codex，只回传终态和必要结论，避免持续读入过程输出。
- **持续跟进**：Claude 处理有依据的技术提问，验收不通过就反馈给原窗口继续；业务决策或授权问题交给你。
- **回收与恢复**：超过 4 个 worker 窗口时检查闲置项，保存恢复信息后关闭暂时不用的窗口，需要时恢复原会话。运行中或等待回答的窗口保留。

## 安装

需要 macOS、已安装并登录的 Claude Code / Codex CLI，以及 `bash`、`python3`。在 tmux、iTerm2 或 Terminal.app 中运行 Claude Code；Terminal.app 需允许自动化控制「终端」。其他终端下会创建独立 tmux 会话，因此需要安装 tmux。

在仓库目录执行：

```bash
mkdir -p ~/.claude/skills
cp -R coworker ~/.claude/skills/
bash ~/.claude/skills/coworker/scripts/selfcheck.sh
```

<details>
<summary>可选：启动 Claude 会话时自动启用</summary>

将以下配置合并到 `~/.claude/settings.json`，保留已有设置。在 tmux、iTerm2 或 Terminal.app 中启动新会话时，hook 会自动启用 Team Lead 模式。

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "bash ~/.claude/skills/coworker/scripts/session-start.sh" }] }
    ]
  }
}
```

</details>

## 怎么用

在 Claude Code 中直接描述目标、修改范围和验收要求，例如：

```text
/coworker 修复登录超时，只改认证模块，跑通相关测试。你负责拆解和验收，让 Codex 实现。
```

也可以说「派给 Codex」「让 Codex 做」「并行开几个 Codex」。Claude 会负责启动窗口、确认就绪、发送任务、等待结果和验收，你不必手动执行脚本。

## 使用建议

- **让 Claude 按场景选模型**：可以说「由你按任务复杂度选择 Codex 模型，复杂分析用 gpt-6-astra，简单修改和验证用 gpt-6.1-sol」。也可以提供自己的模型分工；模型不可用时会询问你。
- **按任务阶段分工**：当前 Skill 默认复杂分析、架构、根因定位和跨模块实现用 `gpt-6-astra`；简单任务、已授权发布、冒烟和结果核对用 `gpt-6.1-sol`。这些是本 Skill 的默认配置。
- **只并行独立任务**：例如「一个 Codex 排查接口，一个补前端测试，你负责整合」，同时说明各自修改范围，减少互相覆盖。
- **把完成标准说清楚**：给出工作目录、允许修改的范围、要跑的检查，以及是否需要 commit / push。后续反馈可直接说「让刚才的 Codex 继续修复测试」。

Codex 默认以 `-a never -s danger-full-access` 启动，拥有完整文件系统访问权限，请在可信项目中使用。发布、推送等操作仍需你的授权。

完整流程、恢复命令与脚本说明见 [`coworker/SKILL.md`](coworker/SKILL.md)。
