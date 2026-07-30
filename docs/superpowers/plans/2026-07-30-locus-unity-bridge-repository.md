# Locus Unity Bridge Repository Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the verified `locus-unity-bridge` skill to the repository and make `~/.agents/skills` the documented shared installation directory.

**Architecture:** The repository receives an exact copy of the four-file installed skill. README remains the installation-first entrypoint: one portable copy example, concise prerequisite notes, and the inventory table.

**Tech Stack:** Markdown, PowerShell 7, .NET named pipes, Git.

## Global Constraints

- Default installation target is `$env:USERPROFILE\.agents\skills`.
- Keep `$repo = (Get-Location).Path`; do not publish maintainer-machine paths.
- Copy the complete `locus-unity-bridge` skill without adding a runtime dependency on `E:\Source\Locus`.
- Keep README concise and reader-facing.
- Missing Locus packages are diagnosed, never installed automatically.
- Preserve LF normalization from `.gitattributes`.

---

### Task 1: Establish README and repository RED checks

**Files:**
- Inspect: `README.md`
- Inspect: `skills/locus-unity-bridge/`

**Interfaces:**
- Consumes: current repository state before integration.
- Produces: recorded failures for the missing shared target and missing skill.

- [ ] **Step 1: Run the shared-target assertion**

```powershell
$readme = Get-Content -LiteralPath 'README.md' -Raw
$expectedTarget = '$target = "$env:USERPROFILE\.agents\skills"'
if (-not $readme.Contains($expectedTarget)) {
    throw "README does not use the shared .agents target."
}
```

- [ ] **Step 2: Verify it fails for the expected reason**

Run the Step 1 block from `E:\AIProject\agent-skills`.

Expected: FAIL with `README does not use the shared .agents target.`

- [ ] **Step 3: Run the missing-skill assertion**

```powershell
if (-not (Test-Path -LiteralPath 'skills\locus-unity-bridge\SKILL.md' -PathType Leaf)) {
    throw "locus-unity-bridge is absent from the repository."
}
```

Expected: FAIL with `locus-unity-bridge is absent from the repository.`

### Task 2: Add the complete Locus skill

**Files:**
- Create: `skills/locus-unity-bridge/SKILL.md`
- Create: `skills/locus-unity-bridge/agents/openai.yaml`
- Create: `skills/locus-unity-bridge/scripts/locus-unity.ps1`
- Create: `skills/locus-unity-bridge/scripts/Test-LocusUnityBridge.ps1`

**Interfaces:**
- Consumes: verified source at `C:\Users\wangjin.jason\.agents\skills\locus-unity-bridge`.
- Produces: a self-contained repository skill with the same relative files and bytes.

- [ ] **Step 1: Copy the skill mechanically**

```powershell
$source = 'C:\Users\wangjin.jason\.agents\skills\locus-unity-bridge'
$destination = 'E:\AIProject\agent-skills\skills\locus-unity-bridge'
Copy-Item -LiteralPath $source -Destination $destination -Recurse
```

- [ ] **Step 2: Compare relative paths and SHA-256 hashes**

```powershell
$sourceFiles = Get-ChildItem -LiteralPath $source -File -Recurse
$destinationFiles = Get-ChildItem -LiteralPath $destination -File -Recurse

$sourceMap = @{}
foreach ($file in $sourceFiles) {
    $relative = $file.FullName.Substring($source.Length + 1)
    $sourceMap[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
}

$destinationMap = @{}
foreach ($file in $destinationFiles) {
    $relative = $file.FullName.Substring($destination.Length + 1)
    $destinationMap[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
}

if (Compare-Object $sourceMap.Keys $destinationMap.Keys) {
    throw 'Skill file sets differ.'
}
foreach ($relative in $sourceMap.Keys) {
    if ($sourceMap[$relative] -ne $destinationMap[$relative]) {
        throw "Skill hash differs: $relative"
    }
}
```

- [ ] **Step 3: Run the repository-copy tests**

```powershell
& pwsh.exe -NoLogo -NoProfile -NonInteractive -File `
    'skills\locus-unity-bridge\scripts\Test-LocusUnityBridge.ps1'
if ($LASTEXITCODE -ne 0) {
    throw "Locus skill tests failed with exit code $LASTEXITCODE"
}
```

Expected: `12 passed, 0 failed`.

- [ ] **Step 4: Commit the skill**

```powershell
git add -- skills/locus-unity-bridge
git diff --cached --check
git commit -m 'feat: add Locus Unity bridge skill'
```

### Task 3: Make README use the shared `.agents` directory

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the new `skills/locus-unity-bridge/` directory.
- Produces: portable shared installation instructions and a Locus inventory entry.

- [ ] **Step 1: Update the installation example**

Use `apply_patch` to make the example contain exactly:

```powershell
$repo = (Get-Location).Path
$target = "$env:USERPROFILE\.agents\skills"

New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item -LiteralPath "$repo\skills\bilibili-page-reader" -Destination $target -Recurse -Force
Copy-Item -LiteralPath "$repo\skills\powershell-safe-invocation" -Destination $target -Recurse -Force
Copy-Item -LiteralPath "$repo\skills\locus-unity-bridge" -Destination $target -Recurse -Force
```

- [ ] **Step 2: Update compatibility and prerequisites**

Use `apply_patch` to:

- describe `.agents/skills` as the shared default for compatible agents;
- tell unsupported agents to replace `$target`;
- add a short Locus section naming Windows, PowerShell 7, Unity, and the project package/bridge;
- state that `probe` diagnoses a missing package without installing it.

- [ ] **Step 3: Add the inventory row**

Add:

```markdown
| [`locus-unity-bridge`](skills/locus-unity-bridge/) | 通过 Locus 检测并控制真实 Unity Editor，支持项目/package/Bridge 诊断、C# 执行和脚本重新编译。 |
```

- [ ] **Step 4: Re-run the README assertions**

```powershell
$readme = Get-Content -LiteralPath 'README.md' -Raw
$required = @(
    '$target = "$env:USERPROFILE\.agents\skills"',
    'skills\locus-unity-bridge',
    '[`locus-unity-bridge`](skills/locus-unity-bridge/)',
    '不会自动安装'
)
foreach ($text in $required) {
    if (-not $readme.Contains($text)) {
        throw "README missing expected text: $text"
    }
}
if ($readme.Contains('$env:USERPROFILE\.codex\skills')) {
    throw 'README still defaults to .codex/skills.'
}
```

Expected: no output and exit code 0.

- [ ] **Step 5: Commit the README**

```powershell
git add -- README.md
git diff --cached --check
git commit -m 'docs: document shared agent skill installation'
```

### Task 4: Verify the integrated repository

**Files:**
- Verify: `README.md`
- Verify: `skills/locus-unity-bridge/**`

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces: final evidence for content, behavior, formatting, and repository state.

- [ ] **Step 1: Run the official skill validator**

```powershell
$validator = 'C:\Users\wangjin.jason\.codex\skills\.system\skill-creator\scripts\quick_validate.py'
uv.exe run --with pyyaml python $validator 'skills\locus-unity-bridge'
```

Expected: `Skill is valid!`

- [ ] **Step 2: Parse both PowerShell scripts**

```powershell
$scripts = Get-ChildItem -LiteralPath 'skills\locus-unity-bridge\scripts' -Filter '*.ps1' -File
foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $script.FullName,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    if ($errors.Count -ne 0) {
        throw "PowerShell parse errors in $($script.FullName): $($errors.Message -join '; ')"
    }
}
```

- [ ] **Step 3: Verify runtime independence and formatting**

```powershell
$hits = & rg.exe -n -F -- 'E:\Source\Locus' 'skills\locus-unity-bridge'
if ($LASTEXITCODE -eq 0) {
    throw "Runtime source dependency found: $hits"
}
if ($LASTEXITCODE -ne 1) {
    throw "rg failed with exit code $LASTEXITCODE"
}

git diff --check HEAD~2..HEAD
git ls-files --eol README.md skills/locus-unity-bridge
```

Expected: no whitespace errors; text files report `i/lf`.

- [ ] **Step 4: Run the full skill suite again**

```powershell
& pwsh.exe -NoLogo -NoProfile -NonInteractive -File `
    'skills\locus-unity-bridge\scripts\Test-LocusUnityBridge.ps1'
if ($LASTEXITCODE -ne 0) {
    throw "Locus skill tests failed with exit code $LASTEXITCODE"
}
```

Expected: `12 passed, 0 failed`.

- [ ] **Step 5: Inspect final history and status**

```powershell
git log -4 --oneline --decorate
git status --short --branch
```

Expected: the design, plan, skill, and README commits are present; worktree is clean.
