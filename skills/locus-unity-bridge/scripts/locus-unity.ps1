[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('probe', 'send', 'execute', 'recompile', 'thumbnail', 'render-preview')]
    [string] $Command = 'probe',

    [string] $ProjectPath = (Get-Location).Path,

    [string] $MessageType,

    [AllowEmptyString()]
    [string] $Message = '',

    [string] $Code,

    [string] $CodeFile,

    [string] $AssetPath,

    [ValidateRange(64, 512)]
    [int] $MaxSize = 192,

    [string] $OutputDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) 'locus-unity-bridge'),

    [ValidateRange(96, 640)]
    [int] $PreviewWidth = 320,

    [ValidateRange(96, 640)]
    [int] $PreviewHeight = 220,

    [float] $Yaw = 25,

    [float] $Pitch = -12,

    [float] $Distance = 1.15,

    [float] $PanX = 0,

    [float] $PanY = 0,

    [float] $PanZ = 0,

    [ValidateRange(1, 600)]
    [int] $TimeoutSeconds = 10,

    [switch] $FollowProgress,

    [ValidateRange(1, 60)]
    [int] $ProgressIntervalSeconds = 2,

    [ValidateRange(1, 1800)]
    [int] $RecompileTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

function Resolve-LocusUnityProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $resolved = [System.IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        $resolved = [System.IO.Path]::GetDirectoryName($resolved)
    }

    $current = [System.IO.DirectoryInfo]::new($resolved)
    while ($null -ne $current) {
        $assets = Join-Path $current.FullName 'Assets'
        $settings = Join-Path $current.FullName 'ProjectSettings'
        if (
            (Test-Path -LiteralPath $assets -PathType Container) -and
            (Test-Path -LiteralPath $settings -PathType Container)
        ) {
            return $current.FullName.TrimEnd('\', '/')
        }
        $current = $current.Parent
    }

    throw "No Unity project found at or above '$Path' (expected Assets and ProjectSettings)."
}

function Get-LocusPackageState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ProjectPath
    )

    $candidates = @(
        [pscustomobject]@{
            Layout = 'canonical'
            RelativePath = 'Packages\com.farlocus.locus'
        },
        [pscustomobject]@{
            Layout = 'legacy'
            RelativePath = 'Assets\Locus'
        },
        [pscustomobject]@{
            Layout = 'legacy'
            RelativePath = 'Assets\Plugins\Locus'
        }
    )

    $invalid = $null
    foreach ($candidate in $candidates) {
        $installPath = Join-Path $ProjectPath $candidate.RelativePath
        $assemblyDefinition = Join-Path $installPath 'Editor\Locus.Editor.asmdef'
        if (Test-Path -LiteralPath $assemblyDefinition -PathType Leaf) {
            return [pscustomobject]@{
                Status = 'package_present'
                Layout = $candidate.Layout
                InstallPath = $installPath
                AssemblyDefinition = $assemblyDefinition
            }
        }
        if ((Test-Path -LiteralPath $installPath -PathType Container) -and $null -eq $invalid) {
            $invalid = [pscustomobject]@{
                Status = 'package_invalid'
                Layout = $candidate.Layout
                InstallPath = $installPath
                AssemblyDefinition = $assemblyDefinition
            }
        }
    }

    if ($null -ne $invalid) {
        return $invalid
    }

    return [pscustomobject]@{
        Status = 'package_missing'
        Layout = $null
        InstallPath = $null
        AssemblyDefinition = $null
    }
}

function Get-LocusComputedPipeName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ProjectPath
    )

    $normalized = $ProjectPath.Trim()
    if ($normalized.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(4)
    }
    $normalized = $normalized.Replace('/', '\')
    while (
        $normalized.EndsWith('\', [System.StringComparison]::Ordinal) -and
        $normalized.Length -gt 3
    ) {
        $normalized = $normalized.Substring(0, $normalized.Length - 1)
    }
    $normalized = $normalized.ToLowerInvariant()

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    $key = [System.BitConverter]::ToString($hash[0..15]).Replace('-', '').ToLowerInvariant()
    return "locus_unity_native_$key"
}

function ConvertTo-LocusBarePipeName {
    param(
        [Parameter(Mandatory)]
        [string] $PipeName
    )

    $value = $PipeName.Trim()
    $prefix = '\\.\pipe\'
    if ($value.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $value.Substring($prefix.Length)
    }
    return $value.TrimStart('\')
}

function Get-LocusPipeInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ProjectPath
    )

    $markerPath = Join-Path $ProjectPath 'Library\Locus\NativeBridge.enabled'
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        $markerLines = Get-Content -LiteralPath $markerPath
        foreach ($rawLine in $markerLines) {
            $line = if ($null -eq $rawLine) { '' } else { $rawLine.Trim() }
            if (-not [string]::IsNullOrEmpty($line)) {
                $bareName = ConvertTo-LocusBarePipeName -PipeName $line
                return [pscustomobject]@{
                    Name = $bareName
                    Path = "\\.\pipe\$bareName"
                    Source = 'marker'
                    MarkerPath = $markerPath
                    MarkerPresent = $true
                }
            }
        }
    }

    $computed = Get-LocusComputedPipeName -ProjectPath $ProjectPath
    return [pscustomobject]@{
        Name = $computed
        Path = "\\.\pipe\$computed"
        Source = 'computed'
        MarkerPath = $markerPath
        MarkerPresent = (Test-Path -LiteralPath $markerPath -PathType Leaf)
    }
}

function Invoke-LocusRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $PipeName,

        [Parameter(Mandatory)]
        [string] $MessageType,

        [AllowEmptyString()]
        [string] $Message = '',

        [ValidateRange(1, 600000)]
        [int] $TimeoutMilliseconds = 10000
    )

    $bareName = ConvertTo-LocusBarePipeName -PipeName $PipeName
    $requestId = 'locus-skill-' + [guid]::NewGuid().ToString('N')
    $request = [ordered]@{
        id = $requestId
        type = $MessageType
        message = $Message
    }
    $json = $request | ConvertTo-Json -Compress -Depth 20
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(
        '.',
        $bareName,
        [System.IO.Pipes.PipeDirection]::InOut,
        [System.IO.Pipes.PipeOptions]::Asynchronous
    )

    try {
        try {
            $pipe.ConnectAsync($TimeoutMilliseconds).GetAwaiter().GetResult()
        }
        catch {
            throw "Locus pipe '\\.\pipe\$bareName' is unavailable: $($_.Exception.Message)"
        }

        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $reader = [System.IO.StreamReader]::new($pipe, $utf8, $false, 4096, $true)
        $writer = [System.IO.StreamWriter]::new($pipe, $utf8, 4096, $true)
        $writer.AutoFlush = $true
        $writer.WriteLine($json)

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            $remaining = [Math]::Max(1, $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds)
            $readTask = $reader.ReadLineAsync()
            $completed = [System.Threading.Tasks.Task]::WhenAny(
                $readTask,
                [System.Threading.Tasks.Task]::Delay($remaining)
            ).GetAwaiter().GetResult()

            if ($completed -ne $readTask) {
                throw "Timed out waiting for '$MessageType' response from '\\.\pipe\$bareName'."
            }

            $line = $readTask.GetAwaiter().GetResult()
            if ($null -eq $line) {
                throw "Locus pipe '\\.\pipe\$bareName' disconnected before replying to '$MessageType'."
            }

            try {
                $envelope = $line | ConvertFrom-Json
            }
            catch {
                throw "Locus pipe returned malformed JSON: $line"
            }

            if ($envelope.reply_to -ne $requestId) {
                continue
            }

            if ($envelope.ok -ne $true) {
                $reason = if (-not [string]::IsNullOrWhiteSpace($envelope.error)) {
                    $envelope.error
                }
                elseif (-not [string]::IsNullOrWhiteSpace($envelope.message)) {
                    $envelope.message
                }
                else {
                    "$MessageType failed without an error message"
                }
                throw "Locus '$MessageType' failed: $reason"
            }

            return $envelope
        }

        throw "Timed out waiting for '$MessageType' response from '\\.\pipe\$bareName'."
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

function Invoke-LocusExecuteWithProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $PipeName,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Code,

        [Parameter(Mandatory)]
        [ValidateRange(1, 600000)]
        [int] $TimeoutMilliseconds,

        [Parameter(Mandatory)]
        [ValidateRange(1, 60)]
        [int] $ProgressIntervalSeconds
    )

    $bareName = ConvertTo-LocusBarePipeName -PipeName $PipeName
    $executeRequestId = 'locus-skill-' + [guid]::NewGuid().ToString('N')
    $executionId = 'locus-skill-execution-' + [guid]::NewGuid().ToString('N')
    $source = $Code + [Environment]::NewLine + "//__LOCUS_EXECUTION_ID__:$executionId"
    $executeRequest = [ordered]@{
        id = $executeRequestId
        type = 'execute_code'
        message = $source
    } | ConvertTo-Json -Compress -Depth 20
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(
        '.',
        $bareName,
        [System.IO.Pipes.PipeDirection]::InOut,
        [System.IO.Pipes.PipeOptions]::Asynchronous
    )
    $reader = $null
    $writer = $null

    try {
        try {
            $pipe.ConnectAsync($TimeoutMilliseconds).GetAwaiter().GetResult()
        }
        catch {
            throw "Locus pipe '\\.\pipe\$bareName' is unavailable: $($_.Exception.Message)"
        }

        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $reader = [System.IO.StreamReader]::new($pipe, $utf8, $false, 4096, $true)
        $writer = [System.IO.StreamWriter]::new($pipe, $utf8, 4096, $true)
        $writer.AutoFlush = $true
        $writer.WriteLine($executeRequest)

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $intervalMilliseconds = ([int64] $ProgressIntervalSeconds) * 1000
        $nextProgressAt = $intervalMilliseconds
        $lastProgressSignature = $null
        $readTask = $null

        while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            $elapsed = $stopwatch.ElapsedMilliseconds
            if ($elapsed -ge $nextProgressAt) {
                $progressRequest = [ordered]@{
                    id = 'locus-skill-' + [guid]::NewGuid().ToString('N')
                    type = 'execute_code_progress'
                    message = $executionId
                } | ConvertTo-Json -Compress -Depth 20
                $writer.WriteLine($progressRequest)
                $nextProgressAt = $elapsed + $intervalMilliseconds
            }

            if ($null -eq $readTask) {
                $readTask = $reader.ReadLineAsync()
            }

            $remaining = [Math]::Max(1, $TimeoutMilliseconds - [int] $stopwatch.ElapsedMilliseconds)
            $untilProgress = [Math]::Max(1, [int] ($nextProgressAt - $stopwatch.ElapsedMilliseconds))
            $waitMilliseconds = [Math]::Min($remaining, $untilProgress)
            $completed = [System.Threading.Tasks.Task]::WhenAny(
                $readTask,
                [System.Threading.Tasks.Task]::Delay($waitMilliseconds)
            ).GetAwaiter().GetResult()

            if ($completed -ne $readTask) {
                continue
            }

            $line = $readTask.GetAwaiter().GetResult()
            $readTask = $null
            if ($null -eq $line) {
                throw "Locus pipe '\\.\pipe\$bareName' disconnected before replying to 'execute_code'."
            }

            try {
                $envelope = $line | ConvertFrom-Json
            }
            catch {
                throw "Locus pipe returned malformed JSON: $line"
            }

            if ($envelope.reply_to -eq $executeRequestId) {
                if ($envelope.ok -ne $true) {
                    $reason = if (-not [string]::IsNullOrWhiteSpace($envelope.error)) {
                        $envelope.error
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace($envelope.message)) {
                        $envelope.message
                    }
                    else {
                        'execute_code failed without an error message'
                    }
                    throw "Locus 'execute_code' failed: $reason"
                }
                return $envelope
            }

            if ($envelope.reply_to -and $envelope.ok -eq $true) {
                try {
                    $progress = $envelope.message | ConvertFrom-Json
                    $progressOutput = [ordered]@{
                        active = [bool] $progress.active
                        title = [string] $progress.title
                        info = [string] $progress.info
                        progress = $progress.progress
                        revision = $progress.revision
                        source = [string] $progress.source
                        waitKind = [string] $progress.waitKind
                        waitTarget = [string] $progress.waitTarget
                        waitCondition = [string] $progress.waitCondition
                        sourceLine = $progress.sourceLine
                        waitedMs = $progress.waitedMs
                    }
                    $progressSignature = [ordered]@{
                        active = $progressOutput.active
                        title = $progressOutput.title
                        info = $progressOutput.info
                        progress = $progressOutput.progress
                        source = $progressOutput.source
                        waitKind = $progressOutput.waitKind
                        waitTarget = $progressOutput.waitTarget
                        waitCondition = $progressOutput.waitCondition
                        sourceLine = $progressOutput.sourceLine
                    } | ConvertTo-Json -Compress -Depth 20
                    if ($progressSignature -ne $lastProgressSignature) {
                        $lastProgressSignature = $progressSignature
                        $progressJson = $progressOutput | ConvertTo-Json -Compress -Depth 20
                        Write-Host "<locus-execute-progress>$progressJson</locus-execute-progress>"
                    }
                }
                catch {
                    # Ignore non-progress replies and malformed progress snapshots;
                    # the execute request remains authoritative.
                }
            }
        }

        throw "Timed out waiting for 'execute_code' response from '\\.\pipe\$bareName'."
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

function Invoke-LocusProbe {
    param(
        [Parameter(Mandatory)]
        [string] $ProjectPath,

        [Parameter(Mandatory)]
        [int] $TimeoutMilliseconds
    )

    $project = Resolve-LocusUnityProject -Path $ProjectPath
    $package = Get-LocusPackageState -ProjectPath $project
    $pipe = Get-LocusPipeInfo -ProjectPath $project

    if ($package.Status -ne 'package_present') {
        return [pscustomobject]@{
            Status = $package.Status
            Connected = $false
            ProjectPath = $project
            Package = $package
            Pipe = $pipe
            Diagnostic = if ($package.Status -eq 'package_missing') {
                'Locus is not installed in this Unity project.'
            }
            else {
                "Locus installation is incomplete; expected '$($package.AssemblyDefinition)'."
            }
        }
    }

    try {
        $capabilities = Invoke-LocusRequest `
            -PipeName $pipe.Name `
            -MessageType 'bridge_capabilities' `
            -Message '' `
            -TimeoutMilliseconds $TimeoutMilliseconds
        return [pscustomobject]@{
            Status = 'connected'
            Connected = $true
            ProjectPath = $project
            Package = $package
            Pipe = $pipe
            Capabilities = $capabilities.message
            Diagnostic = 'Locus Unity bridge is connected.'
        }
    }
    catch {
        $status = if ($pipe.MarkerPresent) { 'editor_unreachable' } else { 'bridge_not_enabled' }
        return [pscustomobject]@{
            Status = $status
            Connected = $false
            ProjectPath = $project
            Package = $package
            Pipe = $pipe
            Diagnostic = $_.Exception.Message
        }
    }
}

function ConvertTo-LocusSafeFileStem {
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Value)
    if ([string]::IsNullOrWhiteSpace($stem)) {
        $stem = 'asset'
    }
    foreach ($invalid in [System.IO.Path]::GetInvalidFileNameChars()) {
        $stem = $stem.Replace([string] $invalid, '_')
    }
    return $stem
}

function Save-LocusPngResponse {
    param(
        [Parameter(Mandatory)]
        [string] $Payload,

        [Parameter(Mandatory)]
        [string] $Base64Property,

        [Parameter(Mandatory)]
        [string] $OutputDirectory
    )

    try {
        $image = $Payload | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Locus image response was not valid JSON: $($_.Exception.Message)"
    }

    $base64 = $image.$Base64Property
    if ([string]::IsNullOrWhiteSpace($base64)) {
        throw "Locus image response did not include '$Base64Property'."
    }
    if ($image.mimeType -ne 'image/png') {
        throw "Locus image response has unsupported MIME type '$($image.mimeType)'."
    }

    try {
        $png = [System.Convert]::FromBase64String($base64)
    }
    catch {
        throw "Locus image response contains invalid Base64: $($_.Exception.Message)"
    }
    if ($png.Length -eq 0) {
        throw 'Locus image response decoded to an empty PNG.'
    }

    $directory = [System.IO.Path]::GetFullPath($OutputDirectory)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $fileStem = ConvertTo-LocusSafeFileStem -Value ([string] $image.assetPath)
    $fileName = 'locus_' + $fileStem + '_' + [DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff') + '.png'
    $path = Join-Path $directory $fileName
    [System.IO.File]::WriteAllBytes($path, $png)

    return [pscustomobject]@{
        AssetPath = [string] $image.assetPath
        Path = $path
        Width = [int] $image.width
        Height = [int] $image.height
        MimeType = [string] $image.mimeType
    }
}

function Invoke-LocusThumbnail {
    param(
        [Parameter(Mandatory)]
        [string] $ProjectPath,

        [Parameter(Mandatory)]
        [string] $AssetPath,

        [Parameter(Mandatory)]
        [int] $MaxSize,

        [Parameter(Mandatory)]
        [string] $OutputDirectory,

        [Parameter(Mandatory)]
        [int] $TimeoutMilliseconds
    )

    if ([string]::IsNullOrWhiteSpace($AssetPath)) {
        throw '-AssetPath is required for thumbnail.'
    }

    $project = Resolve-LocusUnityProject -Path $ProjectPath
    $pipe = Get-LocusPipeInfo -ProjectPath $project
    $payload = [ordered]@{
        assetPath = $AssetPath
        maxSize = $MaxSize
    } | ConvertTo-Json -Compress
    $response = Invoke-LocusRequest `
        -PipeName $pipe.Name `
        -MessageType 'asset_thumbnail' `
        -Message $payload `
        -TimeoutMilliseconds $TimeoutMilliseconds
    return Save-LocusPngResponse `
        -Payload $response.message `
        -Base64Property 'pngBase64' `
        -OutputDirectory $OutputDirectory
}

function Invoke-LocusAssetPreview {
    param(
        [Parameter(Mandatory)]
        [string] $ProjectPath,

        [Parameter(Mandatory)]
        [string] $AssetPath,

        [Parameter(Mandatory)]
        [int] $PreviewWidth,

        [Parameter(Mandatory)]
        [int] $PreviewHeight,

        [Parameter(Mandatory)]
        [float] $Yaw,

        [Parameter(Mandatory)]
        [float] $Pitch,

        [Parameter(Mandatory)]
        [float] $Distance,

        [Parameter(Mandatory)]
        [float] $PanX,

        [Parameter(Mandatory)]
        [float] $PanY,

        [Parameter(Mandatory)]
        [float] $PanZ,

        [Parameter(Mandatory)]
        [string] $OutputDirectory,

        [Parameter(Mandatory)]
        [int] $TimeoutMilliseconds
    )

    if ([string]::IsNullOrWhiteSpace($AssetPath)) {
        throw '-AssetPath is required for render-preview.'
    }

    $project = Resolve-LocusUnityProject -Path $ProjectPath
    $pipe = Get-LocusPipeInfo -ProjectPath $project
    $payload = [ordered]@{
        assetPath = $AssetPath
        width = $PreviewWidth
        height = $PreviewHeight
        yaw = $Yaw
        pitch = $Pitch
        distance = $Distance
        panX = $PanX
        panY = $PanY
        panZ = $PanZ
    } | ConvertTo-Json -Compress
    $response = Invoke-LocusRequest `
        -PipeName $pipe.Name `
        -MessageType 'asset_preview_render' `
        -Message $payload `
        -TimeoutMilliseconds $TimeoutMilliseconds
    return Save-LocusPngResponse `
        -Payload $response.message `
        -Base64Property 'dataBase64' `
        -OutputDirectory $OutputDirectory
}

function Test-LocusTransientReloadError {
    param(
        [Parameter(Mandatory)]
        [string] $Text
    )

    return $Text -match '(?i)reload|disconnected|managed executor|not ready|pipe.*unavailable|broken pipe'
}

function Test-LocusRecompileMayHaveStarted {
    param(
        [Parameter(Mandatory)]
        [string] $Text
    )

    return $Text -match '(?i)reload|disconnected|managed executor|not ready|broken pipe'
}

function Invoke-LocusRecompile {
    param(
        [Parameter(Mandatory)]
        [string] $ProjectPath,

        [Parameter(Mandatory)]
        [int] $RequestTimeoutMilliseconds,

        [Parameter(Mandatory)]
        [int] $OverallTimeoutSeconds
    )

    $project = Resolve-LocusUnityProject -Path $ProjectPath
    $pipe = Get-LocusPipeInfo -ProjectPath $project
    $sawDisconnect = $false

    try {
        Invoke-LocusRequest `
            -PipeName $pipe.Name `
            -MessageType 'request_recompile' `
            -Message '' `
            -TimeoutMilliseconds $RequestTimeoutMilliseconds | Out-Null
    }
    catch {
        if (-not (Test-LocusRecompileMayHaveStarted -Text $_.Exception.Message)) {
            throw
        }
        $sawDisconnect = $true
    }

    Start-Sleep -Seconds 1
    $deadline = [DateTime]::UtcNow.AddSeconds($OverallTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $pipe = Get-LocusPipeInfo -ProjectPath $project
        if ($sawDisconnect) {
            try {
                Invoke-LocusRequest `
                    -PipeName $pipe.Name `
                    -MessageType 'ping' `
                    -Message '' `
                    -TimeoutMilliseconds $RequestTimeoutMilliseconds | Out-Null
                return [pscustomobject]@{
                    Status = 'ok'
                    Message = 'Compilation succeeded, domain reload complete'
                    ProjectPath = $project
                }
            }
            catch {
                Start-Sleep -Seconds 1
                continue
            }
        }

        Start-Sleep -Milliseconds 500
        try {
            $result = Invoke-LocusRequest `
                -PipeName $pipe.Name `
                -MessageType 'get_compile_result' `
                -Message '' `
                -TimeoutMilliseconds $RequestTimeoutMilliseconds
            if ($result.message -eq 'pending') {
                continue
            }
            if ($result.message -eq 'ok') {
                return [pscustomobject]@{
                    Status = 'ok'
                    Message = 'Compilation succeeded, domain reload complete'
                    ProjectPath = $project
                }
            }
        }
        catch {
            if (Test-LocusTransientReloadError -Text $_.Exception.Message) {
                $sawDisconnect = $true
                continue
            }
            throw
        }
    }

    throw "Compilation timed out after $OverallTimeoutSeconds seconds."
}

function Write-LocusJson {
    param(
        [Parameter(Mandatory)]
        $InputObject
    )

    $InputObject | ConvertTo-Json -Depth 20
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $timeoutMilliseconds = $TimeoutSeconds * 1000
        switch ($Command) {
            'probe' {
                Write-LocusJson -InputObject (
                    Invoke-LocusProbe -ProjectPath $ProjectPath -TimeoutMilliseconds $timeoutMilliseconds
                )
            }
            'send' {
                if ([string]::IsNullOrWhiteSpace($MessageType)) {
                    throw '-MessageType is required for send.'
                }
                $project = Resolve-LocusUnityProject -Path $ProjectPath
                $pipe = Get-LocusPipeInfo -ProjectPath $project
                Write-LocusJson -InputObject (
                    Invoke-LocusRequest `
                        -PipeName $pipe.Name `
                        -MessageType $MessageType `
                        -Message $Message `
                        -TimeoutMilliseconds $timeoutMilliseconds
                )
            }
            'execute' {
                if (
                    [string]::IsNullOrWhiteSpace($Code) -and
                    [string]::IsNullOrWhiteSpace($CodeFile)
                ) {
                    throw 'Provide -Code or -CodeFile for execute.'
                }
                if (
                    -not [string]::IsNullOrWhiteSpace($Code) -and
                    -not [string]::IsNullOrWhiteSpace($CodeFile)
                ) {
                    throw 'Provide only one of -Code or -CodeFile.'
                }
                $source = if (-not [string]::IsNullOrWhiteSpace($CodeFile)) {
                    Get-Content -LiteralPath $CodeFile -Raw
                }
                else {
                    $Code
                }
                $project = Resolve-LocusUnityProject -Path $ProjectPath
                $pipe = Get-LocusPipeInfo -ProjectPath $project
                $execute = if ($FollowProgress) {
                    Invoke-LocusExecuteWithProgress `
                        -PipeName $pipe.Name `
                        -Code $source `
                        -TimeoutMilliseconds $timeoutMilliseconds `
                        -ProgressIntervalSeconds $ProgressIntervalSeconds
                }
                else {
                    Invoke-LocusRequest `
                        -PipeName $pipe.Name `
                        -MessageType 'execute_code' `
                        -Message $source `
                        -TimeoutMilliseconds $timeoutMilliseconds
                }
                Write-LocusJson -InputObject (
                    $execute
                )
            }
            'recompile' {
                Write-LocusJson -InputObject (
                    Invoke-LocusRecompile `
                        -ProjectPath $ProjectPath `
                        -RequestTimeoutMilliseconds $timeoutMilliseconds `
                        -OverallTimeoutSeconds $RecompileTimeoutSeconds
                )
            }
            'thumbnail' {
                Write-LocusJson -InputObject (
                    Invoke-LocusThumbnail `
                        -ProjectPath $ProjectPath `
                        -AssetPath $AssetPath `
                        -MaxSize $MaxSize `
                        -OutputDirectory $OutputDirectory `
                        -TimeoutMilliseconds $timeoutMilliseconds
                )
            }
            'render-preview' {
                Write-LocusJson -InputObject (
                    Invoke-LocusAssetPreview `
                        -ProjectPath $ProjectPath `
                        -AssetPath $AssetPath `
                        -PreviewWidth $PreviewWidth `
                        -PreviewHeight $PreviewHeight `
                        -Yaw $Yaw `
                        -Pitch $Pitch `
                        -Distance $Distance `
                        -PanX $PanX `
                        -PanY $PanY `
                        -PanZ $PanZ `
                        -OutputDirectory $OutputDirectory `
                        -TimeoutMilliseconds $timeoutMilliseconds
                )
            }
        }
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}
