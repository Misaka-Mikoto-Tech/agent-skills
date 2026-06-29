# agent-skills

A personal collection of reusable AI agent skills and MCP-related utilities.

这个仓库用于收集我日常使用中沉淀下来的 agent skills：包括网页读取、命令行调用规范、自动化流程、工具集成经验等。内容以可直接复制使用的 `SKILL.md` 为主，后续也可能加入 MCP server 配置和示例。

## Install

复制需要的 skill 到你的 agent 技能目录即可。

### Codex

```powershell
$repo = (Get-Location).Path
$target = "$env:USERPROFILE\.codex\skills"

New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item -LiteralPath "$repo\skills\bilibili-page-reader" -Destination $target -Recurse -Force
Copy-Item -LiteralPath "$repo\skills\powershell-safe-invocation" -Destination $target -Recurse -Force
```

### Other agents

如果你的 agent 使用其他技能目录，比如 `~/.agents/skills`，把 `$target` 改成对应路径即可。

## Available Skills

| Skill | Description |
| --- | --- |
| [`bilibili-page-reader`](skills/bilibili-page-reader/) | Read Bilibili video pages, including official subtitles, danmaku summaries, comments, and ASR fallback via FunASR when no subtitles are available. |
| [`powershell-safe-invocation`](skills/powershell-safe-invocation/) | Safe PowerShell invocation patterns for Windows agents, including native command arguments, paths, quoting, encoding, and process launching. |

## Repository Layout

```text
skills/   Reusable agent skills
mcp/      Reserved for future MCP servers, configs, and examples
```

Each skill lives in its own directory and uses `SKILL.md` as the entry point. Some skills may include helper scripts, examples, or agent-specific metadata.

## License

[MIT](LICENSE)
