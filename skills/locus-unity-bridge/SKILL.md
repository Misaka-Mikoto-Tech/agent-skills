---
name: locus-unity-bridge
description: Use when an agent needs to inspect or control a real Unity Editor through Locus, especially when Unity MCP is unavailable, a project may lack the Locus package, named-pipe discovery is needed, C# must be executed, or Unity scripts must be recompiled.
---

# Locus Unity Bridge

Use the bundled PowerShell client instead of rewriting named-pipe code. Locus
uses UTF-8 JSON Lines and may emit events before a response; the client waits
for the envelope whose `reply_to` matches its request ID.

## Safety boundary

`execute_code` has arbitrary Unity Editor authority. Use it only for the
project and task the user authorized.

Do not install/copy the Locus package, create its marker, launch/close Unity,
or modify a project merely to make the bridge connect. Diagnose first and ask
for authorization if setup changes are required.

## Workflow

1. Resolve the script relative to this skill:

   ```powershell
   $locusBridge = Join-Path $env:USERPROFILE '.agents\skills\locus-unity-bridge\scripts\locus-unity.ps1'
   ```

2. Probe the target project before any Unity operation:

   ```powershell
   & pwsh.exe -NoLogo -NoProfile -NonInteractive -File $locusBridge `
       -Command probe -ProjectPath 'E:\Source\SomeUnityProject'
   ```

3. Read the returned `Status`:

   | Status | Meaning and next action |
   |---|---|
   | `connected` | Use `execute`, `send`, or `recompile`. |
   | `package_missing` | Locus is not installed. Report the expected package `Packages/com.farlocus.locus`; request permission before installation. |
   | `package_invalid` | A candidate folder exists without `Editor/Locus.Editor.asmdef`; report the incomplete path. |
   | `bridge_not_enabled` | Package exists, but no marker or reachable computed pipe exists. Ask the user to enable/connect Locus for this project. |
   | `editor_unreachable` | A marker exists, but its pipe is unavailable. Verify that the matching project is open in Unity and Locus is active. |

The probe supports the canonical package plus legacy `Assets/Locus` and
`Assets/Plugins/Locus` layouts. It also handles
`LOCUS_UNITY_NATIVE_BRIDGE=1`, where no marker may exist but the computed pipe
is live.

## Commands

Execute multi-line C# from a file. Use `print(...)` or `printJson(...)` to
return data:

```powershell
& pwsh.exe -NoLogo -NoProfile -NonInteractive -File $locusBridge `
    -Command execute -ProjectPath 'E:\Source\SomeUnityProject' `
    -CodeFile 'C:\Temp\inspect-scene.cs' -TimeoutSeconds 30
```

Example snippet:

```csharp
print(UnityEngine.SceneManagement.SceneManager.GetActiveScene().path);
```

Send a protocol message:

```powershell
& pwsh.exe -NoLogo -NoProfile -NonInteractive -File $locusBridge `
    -Command send -ProjectPath 'E:\Source\SomeUnityProject' `
    -MessageType status -Message ''
```

Request compilation and wait across domain reload:

```powershell
& pwsh.exe -NoLogo -NoProfile -NonInteractive -File $locusBridge `
    -Command recompile -ProjectPath 'E:\Source\SomeUnityProject' `
    -TimeoutSeconds 10 -RecompileTimeoutSeconds 120
```

All successful commands print JSON. A failed transport or Unity response exits
nonzero and preserves the useful error text.

## Common mistakes

- Do not treat the first pipe line as the response; unsolicited
  `unity-editor-update` events have no matching `reply_to`.
- Do not run against the Locus source checkout when the requested Unity project
  is elsewhere.
- Do not assume Unity MCP is required; this skill talks directly to Locus.
- Do not infer package installation from a running Unity process; trust
  `probe`.
