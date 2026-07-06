# PowerShell Safe Invocation Reference

This file contains detailed guidance and uncommon cases for the accompanying `SKILL.md`. Read only the relevant section when needed.

## 1. PowerShell Version And Native Argument Mode

PowerShell 7 and Windows PowerShell 5.1 can be installed side by side:

```text
pwsh.exe       -> PowerShell 7
powershell.exe -> Windows PowerShell 5.1
```

Verify the current process:

```powershell
$PSVersionTable
$PSNativeCommandArgumentPassing
```

PowerShell 7.3 and later use improved native argument passing. On Windows, the normal default is commonly:

```text
Windows
```

Do not change it to `Legacy` without a demonstrated compatibility requirement.

A command that reports PowerShell 7 once does not prove every later agent invocation uses `pwsh.exe`. Wrappers may invoke different shells.

PowerShell 5.1 and PowerShell 7 can expose the same command with different parameter sets. Check syntax in the active shell before relying on a specific parameter:

```powershell
Get-Command Format-Hex -Syntax
Get-Command Get-FileHash -Syntax
```

For example, `Format-Hex -Count` is available in PowerShell 7 but not in Windows PowerShell 5.1. In 5.1, limit the pipeline instead:

```powershell
Format-Hex -LiteralPath 'C:\Data\buffer.bin' | Select-Object -First 2
```

If a normally available command is not discovered, inspect module search state before assuming it is absent:

```powershell
$env:PSModulePath -split [IO.Path]::PathSeparator
Get-Module -ListAvailable Microsoft.PowerShell.Utility
```

## 2. Why Nested Command Strings Fail

A generated command can pass through several parsers:

```text
agent output
  -> JSON or host escaping
  -> process launcher
  -> cmd.exe or another wrapper
  -> pwsh -Command
  -> PowerShell parser
  -> target program parser
```

Each layer can reinterpret:

- quotes
- backslashes
- dollar signs
- backticks
- pipes
- redirection
- parentheses
- JSON
- regular expressions
- Unicode text

Avoid:

```text
cmd.exe /c pwsh.exe -Command "$json = '{\"name\":\"test\"}'; ..."
```

Prefer a `.ps1` file:

```powershell
$data = [ordered]@{
    name = 'test'
}

$data |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $outputPath -Encoding utf8
```

Run it with:

```text
pwsh.exe -NoLogo -NoProfile -NonInteractive -File script.ps1
```

If an outer PowerShell process invokes another PowerShell process with `-Command`, the outer process expands `$variables` before the child process sees the script. This breaks inner snippets such as `$p = '...'` unless the outer command string is single-quoted:

```powershell
pwsh.exe -NoLogo -NoProfile -Command '$p = "C:\Data Folder\input.txt"; Test-Path -LiteralPath $p'
```

Use a script file instead when both the outer and inner command need variables, paths, JSON, or pipelines.

## 3. Native Argument Arrays

Correct:

```powershell
$exe = 'C:\Program Files\App\tool.exe'

$argList = @(
    '--input'
    'C:\Data Folder\input.json'
    '--name'
    'value with spaces'
    '--empty'
    ''
)

& $exe @argList
$exitCode = $LASTEXITCODE
```

Do not use `$args` as your own variable name. It is a PowerShell automatic variable populated with unbound function or script arguments, so reusing it makes examples fragile when copied into functions, scripts, or nested invocations.

The following are distinct:

- omitted argument
- empty string `''`
- `$null`

Do not silently remove empty arguments.

Inspect arguments during debugging:

```powershell
$argList | ForEach-Object {
    '[{0}] Length={1}' -f $_, $_.Length
}
```

Capture `$LASTEXITCODE` before another native program can overwrite it:

```powershell
& $exe @argList
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    throw "$exe failed with exit code $exitCode"
}
```

Some tools define special nonzero success codes. For example, do not apply a generic `-ne 0` rule to a tool until its exit-code contract is known.

## 4. Cmdlet Splatting And Error Handling

Use a hashtable for cmdlet parameters:

```powershell
$params = @{
    LiteralPath = $source
    Destination = $destination
    Force       = $true
    ErrorAction = 'Stop'
}

Copy-Item @params
```

Use terminating errors when failure must stop execution:

```powershell
$ErrorActionPreference = 'Stop'

try {
    Copy-Item -LiteralPath $source -Destination $destination -ErrorAction Stop
}
catch {
    throw "Copy failed: $($_.Exception.Message)"
}
```

`$LASTEXITCODE` is for native commands and script exit codes, not normal cmdlet success.

### Parameter values that are expressions

PowerShell command arguments are parsed in argument mode. A range or arithmetic expression after a parameter name may be treated as a literal argument instead of the expression you intended.

Avoid:

```powershell
Get-Content -LiteralPath $path | Select-Object -Index 100..120
```

Use parentheses or assign first:

```powershell
Get-Content -LiteralPath $path | Select-Object -Index (100..120)

$lineRange = 100..120
Get-Content -LiteralPath $path | Select-Object -Index $lineRange
```

The same habit helps with arithmetic and other computed values:

```powershell
Get-ChildItem -LiteralPath $root | Select-Object -First ($count + 1)
```

### Statement output and pipelines

PowerShell statements such as `foreach (...) { ... }` are not pipeline expressions. A pipe immediately after the closing brace can be parsed as an empty pipeline element.

Avoid:

```powershell
foreach ($file in $files) {
    [pscustomobject]@{ File = $file }
} | Format-Table -AutoSize
```

Use a variable when the loop is naturally statement-shaped:

```powershell
$rows = foreach ($file in $files) {
    [pscustomobject]@{ File = $file }
}

$rows | Format-Table -AutoSize
```

Or use `ForEach-Object` when the input is already a pipeline:

```powershell
$files |
    ForEach-Object {
        [pscustomobject]@{ File = $_ }
    } |
    Format-Table -AutoSize
```

## 5. String And Escape Rules

Literal path:

```powershell
$path = 'C:\Program Files\App\data.json'
```

Expansion required:

```powershell
$message = "Output path: $path"
```

Do not use Bash-style escaping:

```powershell
# Wrong
"\"quoted\""
```

Use:

```powershell
'"quoted"'
```

or, only when necessary:

```powershell
"`"quoted`""
```

Use braces when text immediately follows a variable name:

```powershell
"${name}_suffix"
```

Use a subexpression for properties:

```powershell
"Exit code: $($process.ExitCode)"
```

## 6. Avoid Backtick Continuation

Avoid:

```powershell
& $exe `
    '--input' `
    $inputPath `
    '--output' `
    $outputPath
```

A trailing space after a backtick can silently break continuation.

Prefer:

```powershell
$argList = @(
    '--input'
    $inputPath
    '--output'
    $outputPath
)

& $exe @argList
```

Natural line breaks are also safe after pipes, commas, operators, and opening delimiters.

## 7. Here-Strings And JSON

Literal multiline text:

```powershell
$text = @'
{
  "name": "$literal"
}
'@
```

Expanded multiline text:

```powershell
$text = @"
Name: $name
"@
```

The opening `@'` or `@"` must be the last tokens on its line, and the closing terminator must appear alone at the start of a line.

Do not use Bash heredocs in PowerShell:

```powershell
# Wrong in PowerShell
python - <<'PY'
```

Use a temporary `.py` file or a PowerShell here-string piped to the program instead.

```powershell
@'
print("hello from stdin")
'@ | python -
```

For JSON, prefer serialization:

```powershell
$data = [ordered]@{
    name = $name
    path = $path
    flags = @('a', 'b')
}

$data |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $jsonPath -Encoding utf8
```

Do not manually escape JSON unless unavoidable.

## 8. Start-Process

Use `Start-Process` only when you need:

- elevation
- new or hidden window behavior
- detached/background launch
- shell association behavior
- an explicit process object under its semantics

Simple example:

```powershell
$startParams = @{
    FilePath     = $exe
    ArgumentList = '--mode test'
    Wait         = $true
    PassThru     = $true
}

$process = Start-Process @startParams

if ($process.ExitCode -ne 0) {
    throw "Process failed with exit code $($process.ExitCode)"
}
```

Be aware that `-ArgumentList` is joined into one command-line string.

For exact argument boundaries, use `ProcessStartInfo.ArgumentList`:

```powershell
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $exe
$psi.UseShellExecute = $false

$psi.ArgumentList.Add('--input')
$psi.ArgumentList.Add('C:\Path With Spaces\input.json')
$psi.ArgumentList.Add('--empty')
$psi.ArgumentList.Add('')

$process = [System.Diagnostics.Process]::Start($psi)
$process.WaitForExit()

if ($process.ExitCode -ne 0) {
    throw "Process failed with exit code $($process.ExitCode)"
}
```

## 9. Capturing stdout And stderr

Use `ProcessStartInfo` when stdout and stderr must be captured separately:

```powershell
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $exe
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true

foreach ($arg in $argList) {
    $psi.ArgumentList.Add($arg)
}

$process = [System.Diagnostics.Process]::Start($psi)
$stdout = $process.StandardOutput.ReadToEnd()
$stderr = $process.StandardError.ReadToEnd()
$process.WaitForExit()

if ($process.ExitCode -ne 0) {
    throw "Command failed with exit code $($process.ExitCode): $stderr"
}
```

Do not pipe binary output through text cmdlets.

## 10. cmd.exe And Batch Files

Avoid:

```powershell
cmd.exe /c "`"$exe`" --input `"$path`""
```

Use:

```powershell
& $exe '--input' $path
```

Use `cmd.exe /c` only when cmd-specific behavior is necessary, such as:

- a cmd built-in
- required `.cmd` or `.bat` semantics
- cmd-specific expansion or redirection

PowerShell 7 already supports:

```powershell
command1 && command2
command1 || command2
```

`.cmd`, `.bat`, and `cmd.exe` add another parser and can trigger legacy argument behavior.

## 11. Invoke-Expression

Avoid:

```powershell
Invoke-Expression "$exe --input '$path'"
```

Prefer:

```powershell
& $exe '--input' $path
```

Use `Invoke-Expression` only when trusted text intentionally contains PowerShell source code and no structured alternative exists.

Never use it with untrusted or loosely generated input.

## 12. File And Path Safety

Use `-LiteralPath` for real paths:

```powershell
Get-Item -LiteralPath $path
Copy-Item -LiteralPath $source -Destination $destination
Remove-Item -LiteralPath $path
```

Use `-Path` only when wildcard expansion is intentional.

For path construction:

```powershell
$path = Join-Path -Path $root -ChildPath 'subdir\file.txt'
```

or:

```powershell
$path = [System.IO.Path]::Combine($root, 'subdir', 'file.txt')
```

Use `Resolve-Path -LiteralPath` for existing paths.

Use `[System.IO.Path]::GetFullPath()` for normalization when a target may not exist yet.

### Mapped drives and automation accounts

Mapped drives such as `X:\` are scoped to a user logon session. A path can work in an interactive desktop PowerShell and fail in an automation, service, elevated process, sandbox, or scheduled task running as another identity.

When a mapped-drive path unexpectedly fails:

```powershell
whoami
Get-PSDrive -Name X -ErrorAction SilentlyContinue
Test-Path -LiteralPath 'X:\Expected\file.rdc'
```

If the drive is missing, either use a UNC path that is verified under the same account or create the mapping in that same process/session. Do not assume the interactive user's mapped drives exist for another identity.

If the automation cannot see the mapped drive and cannot discover its `DisplayRoot`, ask the user for the real UNC path instead of guessing. When the task must use the user's existing drive mappings or network credentials, ask the user to run the task in a current-user or full-access mode if the host platform provides one. After switching modes, re-check `whoami`, `Get-PSDrive`, and `Test-Path` before proceeding.

### Recursive mutation validation

```powershell
$root = (Resolve-Path -LiteralPath 'C:\ExpectedRoot').Path
$target = (Resolve-Path -LiteralPath $candidate).Path

$rootPrefix = $root.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar

if (-not $target.StartsWith(
    $rootPrefix,
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "Refusing to modify path outside expected root: $target"
}

Remove-Item -LiteralPath $target -Recurse -Force
```

A simple check such as:

```powershell
$target.StartsWith($root)
```

is insufficient because `C:\WorkBackup` is not a child of `C:\Work`.

Also reject:

- empty paths
- filesystem roots
- the intended root itself, unless explicitly allowed
- unresolved or unexpected targets

Keep deletion and moving in one shell rather than enumerating paths in PowerShell and passing them to another shell.

## 13. Encoding And Binary Files

When another tool consumes a text file, specify encoding:

```powershell
Set-Content -LiteralPath $path -Value $text -Encoding utf8
```

For binary data, use byte APIs:

```powershell
[System.IO.File]::WriteAllBytes($path, $bytes)
```

Do not use text cmdlets for binary content.

## 14. Stop-Parsing Token

Avoid `--%` by default.

It is Windows-specific and disables normal PowerShell parsing for the rest of the command.

Do not use it when remaining arguments require:

- PowerShell variables
- expressions
- pipelines
- redirection
- dynamic values

Use it only for a fixed literal native command that cannot be expressed reliably with an argument array.

## 15. Environment Variables

Read:

```powershell
$env:NAME
```

Set for the current process and its children:

```powershell
$env:NAME = 'value'
```

Do not use `%NAME%` inside PowerShell.

Changes made by a child process do not propagate back to its parent PowerShell process.

## 16. Diagnostic Checklist

Common symptoms:

| Symptom | Likely cause | First check |
| --- | --- | --- |
| `$p` or `$env:NAME` disappears in an inner `-Command` | Outer PowerShell expanded the variable first | Use an outer single-quoted command or a `.ps1` file |
| `python - <<'PY'` fails with parser errors | Bash heredoc syntax was used in PowerShell | Use a temporary script or PowerShell here-string |
| `-Index 100..120` fails to bind or behaves literally | Parameter value expression was not grouped | Use `-Index (100..120)` or assign the range first |
| `foreach (...) { ... } | ...` reports an empty pipe element | Statement syntax was piped directly | Assign the loop output first or use `ForEach-Object` |
| `X:\...` works interactively but not in automation | Mapped drive is not visible to this user/session | `whoami`, `Get-PSDrive`, ask for UNC or switch execution mode |
| A known cmdlet is missing | Module path or active shell differs from expectation | `$PSVersionTable`, `$env:PSModulePath`, `Get-Module -ListAvailable` |
| A cmdlet parameter is rejected | PowerShell 5.1/7 parameter-set difference | `Get-Command <cmdlet> -Syntax` |
| Native arguments with spaces/empty strings break | Arguments were flattened into one string | Use `& $exe @argList` or `ProcessStartInfo.ArgumentList` |

When argument corruption occurs:

```powershell
$PSVersionTable
$PSNativeCommandArgumentPassing
Get-Command pwsh
Get-Command powershell
Get-Command $exe -ErrorAction SilentlyContinue
```

Then simplify the invocation:

1. Remove `cmd.exe`.
2. Remove `-Command`.
3. Remove `Invoke-Expression`.
4. Remove manually nested quotes.
5. Put code in a minimal `.ps1` file.
6. Invoke the native executable directly with `& $exe @argList`.
7. Print each argument and its length.
8. Capture `$LASTEXITCODE` immediately.

## 17. Recommended Automation Entry Point

Preferred:

```text
pwsh.exe -NoLogo -NoProfile -NonInteractive -File script.ps1
```

Meanings:

- `-NoLogo`: no startup banner
- `-NoProfile`: no user or machine profile side effects
- `-NonInteractive`: prompts fail instead of hanging automation
- `-File`: avoids an additional command-string parsing layer

Do not add `-ExecutionPolicy Bypass` by habit. Add it only for a trusted script that is actually blocked and where policy permits the override.
