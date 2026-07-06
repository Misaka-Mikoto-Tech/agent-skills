---
name: powershell-safe-invocation
description: Use when writing or running PowerShell on Windows, especially native programs, quoted paths, escaping, pwsh, Start-Process, file operations, or shell troubleshooting.
---

# PowerShell Safe Invocation

## Shell

Use PowerShell 7 through `pwsh.exe` unless Windows PowerShell 5.1 is explicitly required.

When the active shell is uncertain, verify:

```powershell
$PSVersionTable.PSVersion
$PSNativeCommandArgumentPassing
```

Do not assume installing PowerShell 7 makes `powershell.exe` use PowerShell 7:

- `pwsh.exe` = PowerShell 7
- `powershell.exe` = Windows PowerShell 5.1

## Native Programs

Never construct one large command string when arguments can be passed separately.

Use:

```powershell
$exe = 'C:\Path With Spaces\tool.exe'
$argList = @(
    '--input'
    'C:\Data Folder\input.json'
    '--flag'
)

& $exe @argList

$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    throw "$exe failed with exit code $exitCode"
}
```

Rules:

- Treat every native argument as one array item.
- Invoke executable paths stored in variables with `&`.
- Capture `$LASTEXITCODE` immediately.
- Avoid using `$args` as your own argument array name; it is a PowerShell automatic variable. Use names like `$argList` or `$nativeArgs`.
- Do not use `Invoke-Expression`.
- Do not add a `cmd.exe /c` layer merely to launch an executable.
- Do not use Bash-style `\"` escaping in PowerShell.

## Cmdlets

Use hashtable splatting for PowerShell cmdlets:

```powershell
$params = @{
    LiteralPath = 'C:\Data[1]\input.txt'
    Destination = 'C:\Output'
    Force       = $true
    ErrorAction = 'Stop'
}

Copy-Item @params
```

Use `-LiteralPath` for real paths unless wildcard expansion is intentional.

Do not use `$LASTEXITCODE` to test a PowerShell cmdlet. Use terminating errors:

```powershell
$ErrorActionPreference = 'Stop'
```

Wrap expressions passed as parameter values in parentheses or assign them first: use `Select-Object -Index (100..120)`, not `-Index 100..120`.

Do not pipe directly from statement syntax such as `foreach (...) { ... } | ...`; assign the statement output first or use the pipeline cmdlet `ForEach-Object`.

## Complex Commands

Avoid deeply quoted commands such as:

```text
cmd.exe /c pwsh.exe -Command "..."
```

For multiline code, nested quotes, JSON, XML, regular expressions, pipelines, redirection, or non-ASCII paths:

1. Write a temporary `.ps1` file.
2. Execute it with:

```text
pwsh.exe -NoLogo -NoProfile -NonInteractive -File script.ps1
```

Prefer `-File` over `-Command` for anything beyond a short, simple expression.

Do not add `-ExecutionPolicy Bypass` unless execution policy is actually blocking a trusted script.

When you must pass a script through `-Command` from an outer PowerShell process, remember that the outer shell expands `$variables` first. Use an outer single-quoted script string when the inner script contains `$p`, `$env:...`, `$PSVersionTable`, or similar:

```powershell
pwsh.exe -NoLogo -NoProfile -Command '$p = "C:\Data Folder\input.txt"; Test-Path -LiteralPath $p'
```

If the command has to cross multiple interpreters or wrappers, stop and write a `.ps1` file instead of stacking more quoting.

## Strings And Multiline Code

- Use single quotes for literal strings and paths.
- Use double quotes only when PowerShell expansion is needed.
- Avoid backtick line continuation; use arrays, hashtables, splatting, parentheses, or script blocks.
- Do not use Bash heredocs such as `python - <<'PY'`; PowerShell parses `<` differently. Use a temporary script file or a PowerShell here-string piped to the program.
- For JSON, create objects and use `ConvertTo-Json`; do not hand-escape JSON.
- Use single-quoted here-strings for literal multiline text: put no characters after opening `@'`, and close with `'@` alone at the start of a line.
- Specify text encoding explicitly when another tool consumes the file.

## Start-Process

For normal foreground execution, use:

```powershell
& $exe @argList
```

Use `Start-Process` only for elevation, new/hidden windows, detached launch, or shell behavior.

`Start-Process -ArgumentList` joins values into a command-line string and is not a reliable structured-argument API. Prefer `ProcessStartInfo.ArgumentList` when exact argument boundaries matter.

When a separate process is required and arguments are complex, use:

```powershell
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $exe
$psi.UseShellExecute = $false

foreach ($arg in $argList) {
    $psi.ArgumentList.Add($arg)
}

$process = [System.Diagnostics.Process]::Start($psi)
$process.WaitForExit()

if ($process.ExitCode -ne 0) {
    throw "Process failed with exit code $($process.ExitCode)"
}
```

## File Operations

Before recursive delete, move, or overwrite:

- Resolve the absolute root and target paths.
- Verify the target is inside the intended root.
- Reject empty, root-level, or unexpected paths.
- Keep filesystem mutations in PowerShell instead of passing paths to another shell.

Mapped drives are per user/session. If `Test-Path X:\...` fails under an automation or sandbox account but works interactively, check the current identity with `whoami` and inspect `Get-PSDrive`. If the mapping is not visible, ask the user for the UNC path, establish the mapping for the same account, or switch the task to a current-user/full-access execution mode when the platform supports it.

## Version And Module Differences

PowerShell 5.1 and PowerShell 7 can expose the same command with different parameters or command types. Verify syntax in the active shell before relying on version-specific parameters:

```powershell
$PSVersionTable.PSVersion
Get-Command Format-Hex -Syntax
Get-Command Get-FileHash -Syntax
```

For example, `Format-Hex -Count` is available in PowerShell 7 but not in Windows PowerShell 5.1. In 5.1, use pipeline limiting instead:

```powershell
Format-Hex -LiteralPath 'C:\Data\buffer.bin' | Select-Object -First 2
```

If command discovery behaves strangely, inspect `$env:PSModulePath` and `Get-Module -ListAvailable <ModuleName>` before assuming the cmdlet is missing.

## Decision Order

Choose the simplest safe option:

1. PowerShell cmdlet.
2. `& $exe @argList`.
3. Temporary `.ps1` file with `pwsh.exe -File`.
4. `ProcessStartInfo.ArgumentList`.
5. `Start-Process` when its special behavior is required.
6. `cmd.exe /c` only when cmd semantics are required.
7. `Invoke-Expression` only as a tightly controlled last resort.

For uncommon cases and complete examples, read `reference.md`.
