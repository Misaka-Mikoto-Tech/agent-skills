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

## 2. Why Nested Command Strings Fail

A generated command can pass through several parsers:

```text
agent output
  -> JSON or host escaping
  -> process launcher
  -> cmd.exe or another wrapper
  -> pwsh -Command
  -> PowerShell parser
  -> native program parser
  -> optional target shell or generated-language parser
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

Avoid naming native argument arrays `$args` or `$Args` in reusable code. `$args` is an automatic variable inside functions, scripts, and script blocks. Use names such as `$argList`, `$nativeArgs`, or `$processArgs` instead.

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

Use braces before `:` in remote-style paths:

```powershell
$hostName = '<remote-host>'
scp .\file.txt "${hostName}:/tmp/file.txt"
```

Avoid:

```powershell
scp .\file.txt "$hostName:/tmp/file.txt"
```

PowerShell may parse `$hostName:` as scoped variable syntax.

Avoid PowerShell automatic variable names for parameters, local variables, and temporary script state. Variable names are case-insensitive, so `$Args` and `$args` refer to the same name:

```powershell
# Avoid names such as $args, $input, $PID, $HOME, $PWD, $PSHOME, and $LASTEXITCODE.
$remoteProcessId = 1234
$argList = @('-s', '<serial>', 'getvar', 'current-slot')
```

Avoid using `$Args` as a function parameter name for native command arguments:

```powershell
# Avoid
function Invoke-Native($Exe, [string[]]$Args) {
    & $Exe @Args
}

# Prefer
function Invoke-Native($Exe, [string[]]$ArgList) {
    & $Exe @ArgList
}
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

The closing terminator must appear alone at the start of a line.

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
$process = Start-Process `
    -FilePath $exe `
    -ArgumentList '--mode test' `
    -Wait `
    -PassThru

if ($process.ExitCode -ne 0) {
    throw "Process failed with exit code $($process.ExitCode)"
}
```

Be aware that `-ArgumentList` is joined into one command-line string.

`ProcessStartInfo.ArgumentList` is available in PowerShell 7 / modern .NET. Windows PowerShell 5.1 commonly exposes only `ProcessStartInfo.Arguments`, which is a single command-line string. Prefer running the script with `pwsh.exe` when exact argument boundaries, timeout handling, and separate stdout/stderr capture are all required.

Do not replace structured argument passing with a simple join unless every argument is fixed and known not to contain spaces, quotes, backslashes at the end, or empty strings.

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

Use `ProcessStartInfo` when stdout and stderr must be captured separately. Under PowerShell 7, use `ArgumentList` for exact argument boundaries:

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

For compiler invocations, avoid `.cmd` or `.bat` wrappers when arguments contain quote-sensitive macro values, attributes, or linker flags.

Prefer:

- the real compiler executable
- a response file
- a source-level default or configuration header

Risky through another shell layer:

```powershell
'-DMY_API=__attribute__((visibility("default")))'
```

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


## 18. Cross-Shell Remote Invocation

### Problem

Some native tools execute shell code somewhere else. Examples include `ssh`, `docker exec`, `kubectl exec`, `adb shell`, and cloud CLI remote-command features.

Treat these invocations as the same class of problem: PowerShell is one parser, the launcher tool is another boundary, and the target shell is another parser.

A typical chain is:

```text
PowerShell
-> native argument passing
-> launcher tool
-> target shell
-> optional nested parser
```

The examples below use `ssh` because it is the most common target-shell launcher. The same pattern applies to other tools that run shell source in another environment.

### Remote shell variables

Risky:

```powershell
ssh '<remote-host>' "bash -lc 'echo $PWD; echo $LD_LIBRARY_PATH'"
```

PowerShell sees the outer double-quoted string first. The single quotes inside that string do not protect `$PWD` from PowerShell parsing.

Safer:

```powershell
$remoteHost = '<remote-host>'

$script = @'
set -euo pipefail

echo "$PWD"
echo "${LD_LIBRARY_PATH:-}"
'@

($script -replace "`r", '') | ssh $remoteHost bash
```

### Passing local values

For simple values, pass them as arguments to the target script instead of interpolating them into the script source:

```powershell
$remoteHost = '<remote-host>'
$remoteRoot = '/opt/project'
$jobName = 'smoke-test'

$script = @'
set -euo pipefail

remote_root="$1"
job_name="$2"

cd "$remote_root"
printf 'job=%s\n' "$job_name"
'@

($script -replace "`r", '') |
    ssh $remoteHost bash -s -- $remoteRoot $jobName
```

For values that may contain spaces, quotes, or untrusted content, prefer a temporary file, JSON payload, or another structured data channel instead of embedding those values into a remote command line.

### Remote paths with colons

Use braces before `:`:

```powershell
$hostName = '<remote-host>'
scp .\file.txt "${hostName}:/tmp/file.txt"
```

Avoid:

```powershell
scp .\file.txt "$hostName:/tmp/file.txt"
```

PowerShell may parse `$hostName:` as scoped variable syntax.

### Nested shell commands

For commands that contain semicolon-separated environment assignments, redirection, pipelines, or multiple exports, write a short script for the innermost shell and run that script.

This rule applies to any launcher that executes another shell. The specific launcher is incidental; the important part is to keep target-shell syntax out of PowerShell double-quoted command strings.

### Exit status

Do not hide target failures with a trailing success command:

```powershell
# Avoid when failure matters
ssh '<remote-host>' 'run-tests; true'
```

Return or print the real exit status instead.

## 19. Generated Scripts And Cross-Language Patches

When PowerShell sends a script that itself generates or patches Bash, Python, CMake, JSON, or C/C++ source, treat the generated target language as another parser layer.

Rules:

- Do not patch shell scripts by matching a multiline string that contains trailing `\` line continuations.
- Prefer line-based insertion, structured parsing, or a template file over hand-escaped multiline replacements.
- When Python must generate shell text, build output as a list of lines and join with `'\n'`.
- Use raw triple-quoted strings only for large literal blocks, and avoid mixing raw strings with dynamic shell fragments.
- After modifying generated shell scripts, run `bash -n` and a targeted content check before executing them.
- After modifying generated Python, run `python -m py_compile` when applicable.
- Keep `$VAR` intended for the generated shell inside a literal script body or write it as data, not as a PowerShell-expanded value.

Prefer line-based insertion:

```powershell
$script = @'
set -euo pipefail

python3 - <<'PY'
from pathlib import Path

p = Path('run-tool.sh')
lines = p.read_text().splitlines()

out = []
inserted = False

for line in lines:
    out.append(line)
    if line.lstrip().startswith('--mode ') and line.rstrip().endswith('\\'):
        out.append('        --limit "$LIMIT" \\')
        inserted = True

if not inserted:
    raise SystemExit('insertion point not found')

p.write_text('\n'.join(out) + '\n')
PY

bash -n run-tool.sh
grep -n -- '--limit' run-tool.sh
'@

$remoteHost = '<remote-host>'
$script | ssh $remoteHost 'tr -d ''\r'' | bash -s'
```
