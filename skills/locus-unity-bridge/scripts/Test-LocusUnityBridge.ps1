[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptUnderTest = Join-Path $PSScriptRoot 'locus-unity.ps1'

if (-not (Test-Path -LiteralPath $scriptUnderTest -PathType Leaf)) {
    throw "Missing script under test: $scriptUnderTest"
}

. $scriptUnderTest

$script:passed = 0
$script:failed = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Actual,

        [Parameter(Mandatory)]
        [AllowNull()]
        $Expected,

        [Parameter(Mandatory)]
        [string] $Because
    )

    if ($Actual -ne $Expected) {
        throw "$Because. Expected '$Expected', got '$Actual'."
    }
}

function Invoke-Test {
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [scriptblock] $Body
    )

    try {
        & $Body
        $script:passed++
        Write-Host "PASS $Name"
    }
    catch {
        $script:failed++
        Write-Host "FAIL $Name"
        Write-Host "  $($_.Exception.Message)"
    }
}

function New-TestUnityProject {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("locus-skill-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'Assets') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'ProjectSettings') -Force | Out-Null
    return $root
}

function Start-MockPipeServer {
    param(
        [Parameter(Mandatory)]
        [string] $PipeName,

        [Parameter(Mandatory)]
        [ValidateSet('event-then-ok', 'error')]
        [string] $Mode
    )

    return Start-Job -ArgumentList $PipeName, $Mode -ScriptBlock {
        param($PipeName, $Mode)

        $pipe = [System.IO.Pipes.NamedPipeServerStream]::new(
            $PipeName,
            [System.IO.Pipes.PipeDirection]::InOut,
            1,
            [System.IO.Pipes.PipeTransmissionMode]::Byte,
            [System.IO.Pipes.PipeOptions]::Asynchronous
        )

        try {
            $pipe.WaitForConnection()
            $utf8 = [System.Text.UTF8Encoding]::new($false)
            $reader = [System.IO.StreamReader]::new($pipe, $utf8, $false, 4096, $true)
            $writer = [System.IO.StreamWriter]::new($pipe, $utf8, 4096, $true)
            $writer.AutoFlush = $true
            $request = $reader.ReadLine() | ConvertFrom-Json

            if ($Mode -eq 'event-then-ok') {
                $event = [ordered]@{
                    id = 'event-1'
                    type = 'unity-editor-update'
                    message = 'tick'
                } | ConvertTo-Json -Compress
                $writer.WriteLine($event)

                $response = [ordered]@{
                    id = 'response-1'
                    type = 'response'
                    reply_to = $request.id
                    ok = $true
                    message = 'pong'
                } | ConvertTo-Json -Compress
                $writer.WriteLine($response)
            }
            else {
                $response = [ordered]@{
                    id = 'response-1'
                    type = 'response'
                    reply_to = $request.id
                    ok = $false
                    error = 'mock failure'
                } | ConvertTo-Json -Compress
                $writer.WriteLine($response)
            }
        }
        finally {
            if ($null -ne $reader) {
                $reader.Dispose()
            }
            if ($null -ne $writer) {
                $writer.Dispose()
            }
            $pipe.Dispose()
        }
    }
}

function Invoke-BridgeProcess {
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory)]
        [string[]] $BridgeArguments
    )

    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-File',
        $scriptUnderTest
    ) + $BridgeArguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdoutTask.GetAwaiter().GetResult()
        Stderr = $stderrTask.GetAwaiter().GetResult()
    }
}

Invoke-Test 'resolves Unity project by walking upward' {
    $project = New-TestUnityProject
    try {
        $nested = Join-Path $project 'Assets\Scripts\Editor'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        $actual = Resolve-LocusUnityProject -Path $nested
        Assert-Equal $actual $project 'Project root should be resolved'
    }
    finally {
        Remove-Item -LiteralPath $project -Recurse -Force
    }
}

Invoke-Test 'fresh process discovers a missing-package project from a nested directory' {
    $project = New-TestUnityProject
    try {
        $nested = Join-Path $project 'Assets\Nested'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        $result = Invoke-BridgeProcess `
            -WorkingDirectory $nested `
            -BridgeArguments @('-Command', 'probe', '-TimeoutSeconds', '1')
        Assert-Equal $result.ExitCode 0 'Diagnostic probe should succeed'
        $probe = $result.Stdout | ConvertFrom-Json
        Assert-Equal $probe.Status 'package_missing' 'Fresh process should resolve the project upward'
    }
    finally {
        Remove-Item -LiteralPath $project -Recurse -Force
    }
}

Invoke-Test 'fresh process distinguishes bridge not enabled from editor unreachable' {
    $project = New-TestUnityProject
    try {
        $editor = Join-Path $project 'Packages\com.farlocus.locus\Editor'
        New-Item -ItemType Directory -Path $editor -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $editor 'Locus.Editor.asmdef') -Force | Out-Null

        $notEnabled = Invoke-BridgeProcess `
            -WorkingDirectory $project `
            -BridgeArguments @(
                '-Command', 'probe',
                '-ProjectPath', $project,
                '-TimeoutSeconds', '1'
            )
        Assert-Equal $notEnabled.ExitCode 0 'Disconnected diagnostic probe should succeed'
        $notEnabledProbe = $notEnabled.Stdout | ConvertFrom-Json
        Assert-Equal $notEnabledProbe.Status 'bridge_not_enabled' 'Missing marker should be explicit'

        $markerDirectory = Join-Path $project 'Library\Locus'
        New-Item -ItemType Directory -Path $markerDirectory -Force | Out-Null
        Set-Content `
            -LiteralPath (Join-Path $markerDirectory 'NativeBridge.enabled') `
            -Value ('missing_' + [guid]::NewGuid().ToString('N')) `
            -Encoding utf8NoBOM

        $unreachable = Invoke-BridgeProcess `
            -WorkingDirectory $project `
            -BridgeArguments @(
                '-Command', 'probe',
                '-ProjectPath', $project,
                '-TimeoutSeconds', '1'
            )
        Assert-Equal $unreachable.ExitCode 0 'Unreachable diagnostic probe should succeed'
        $unreachableProbe = $unreachable.Stdout | ConvertFrom-Json
        Assert-Equal $unreachableProbe.Status 'editor_unreachable' 'Marker without server should be explicit'
    }
    finally {
        Remove-Item -LiteralPath $project -Recurse -Force
    }
}

Invoke-Test 'reports a missing package' {
    $project = New-TestUnityProject
    try {
        $state = Get-LocusPackageState -ProjectPath $project
        Assert-Equal $state.Status 'package_missing' 'Missing package status should be explicit'
        Assert-Equal $state.InstallPath $null 'Missing package should not invent a path'
    }
    finally {
        Remove-Item -LiteralPath $project -Recurse -Force
    }
}

Invoke-Test 'detects canonical package layout' {
    $project = New-TestUnityProject
    try {
        $editor = Join-Path $project 'Packages\com.farlocus.locus\Editor'
        New-Item -ItemType Directory -Path $editor -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $editor 'Locus.Editor.asmdef') -Force | Out-Null
        $state = Get-LocusPackageState -ProjectPath $project
        Assert-Equal $state.Status 'package_present' 'Canonical package should be present'
        Assert-Equal $state.Layout 'canonical' 'Canonical package layout should be labeled'
    }
    finally {
        Remove-Item -LiteralPath $project -Recurse -Force
    }
}

Invoke-Test 'detects legacy package layout' {
    $project = New-TestUnityProject
    try {
        $editor = Join-Path $project 'Assets\Plugins\Locus\Editor'
        New-Item -ItemType Directory -Path $editor -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $editor 'Locus.Editor.asmdef') -Force | Out-Null
        $state = Get-LocusPackageState -ProjectPath $project
        Assert-Equal $state.Status 'package_present' 'Legacy package should be present'
        Assert-Equal $state.Layout 'legacy' 'Legacy package layout should be labeled'
    }
    finally {
        Remove-Item -LiteralPath $project -Recurse -Force
    }
}

Invoke-Test 'uses marker pipe name before computed fallback' {
    $project = New-TestUnityProject
    try {
        $markerDirectory = Join-Path $project 'Library\Locus'
        New-Item -ItemType Directory -Path $markerDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $markerDirectory 'NativeBridge.enabled') -Value "marker_pipe`nignored" -Encoding utf8NoBOM
        $pipe = Get-LocusPipeInfo -ProjectPath $project
        Assert-Equal $pipe.Name 'marker_pipe' 'First nonempty marker line should win'
        Assert-Equal $pipe.Source 'marker' 'Marker source should be reported'
    }
    finally {
        Remove-Item -LiteralPath $project -Recurse -Force
    }
}

Invoke-Test 'computes the Locus native pipe hash' {
    $actual = Get-LocusComputedPipeName -ProjectPath 'C:\Projects\Game\'
    Assert-Equal $actual 'locus_unity_native_b77b5670d55eab3d7294a562f9c5bd60' 'Pipe hash must match Locus'
}

Invoke-Test 'ignores an unsolicited event before the matching response' {
    $pipeName = 'locus_skill_test_' + [guid]::NewGuid().ToString('N')
    $job = Start-MockPipeServer -PipeName $pipeName -Mode 'event-then-ok'
    try {
        Start-Sleep -Milliseconds 150
        $response = Invoke-LocusRequest -PipeName $pipeName -MessageType 'ping' -Message '' -TimeoutMilliseconds 3000
        Assert-Equal $response.message 'pong' 'Client should return the matching response'
        Assert-Equal $response.reply_to.StartsWith('locus-skill-') $true 'Response should match generated request id'
    }
    finally {
        Wait-Job -Job $job -Timeout 3 | Out-Null
        Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $job -Force
    }
}

Invoke-Test 'surfaces ok=false as an error' {
    $pipeName = 'locus_skill_test_' + [guid]::NewGuid().ToString('N')
    $job = Start-MockPipeServer -PipeName $pipeName -Mode 'error'
    try {
        Start-Sleep -Milliseconds 150
        $caught = $null
        try {
            Invoke-LocusRequest -PipeName $pipeName -MessageType 'ping' -Message '' -TimeoutMilliseconds 3000
        }
        catch {
            $caught = $_.Exception.Message
        }
        Assert-Equal $caught.Contains('mock failure') $true 'Server error should be preserved'
    }
    finally {
        Wait-Job -Job $job -Timeout 3 | Out-Null
        Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $job -Force
    }
}

Invoke-Test 'times out when the pipe is unavailable' {
    $caught = $null
    try {
        Invoke-LocusRequest -PipeName ('missing_' + [guid]::NewGuid().ToString('N')) -MessageType 'ping' -Message '' -TimeoutMilliseconds 100
    }
    catch {
        $caught = $_.Exception.Message
    }
    Assert-Equal $caught.Contains('unavailable') $true 'Unavailable pipe should have a clear diagnostic'
}

Invoke-Test 'does not treat an initially unavailable recompile pipe as a reload' {
    $project = New-TestUnityProject
    try {
        $caught = $null
        try {
            Invoke-LocusRecompile `
                -ProjectPath $project `
                -RequestTimeoutMilliseconds 100 `
                -OverallTimeoutSeconds 1
        }
        catch {
            $caught = $_.Exception.Message
        }
        Assert-Equal $caught.Contains('unavailable') $true 'A recompile that never connected should fail immediately'
    }
    finally {
        Remove-Item -LiteralPath $project -Recurse -Force
    }
}

Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -ne 0) {
    exit 1
}
