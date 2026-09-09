---
name: locus-unity-bridge
description: Use when an agent needs to inspect or control a real Unity Editor through Locus, especially when Unity MCP is unavailable, a project may lack the Locus package, named-pipe discovery is needed, C# must be executed, or Unity scripts must be recompiled.
---

# Locus Unity Bridge

Use the bundled PowerShell client to inspect or control a real Unity Editor.
Do not rewrite its named-pipe client. Always pass the exact Unity root to
`-ProjectPath`; it identifies the bridge connection.

## Safety

`execute` can run arbitrary C# in Unity. Use it only for the project and task
the user authorized. Do not install Locus, create its marker, launch or close
Unity, or modify a project merely to connect the bridge.

## Command map

The client has six top-level commands. `send` is a transport command: its
`-MessageType` selects a curated Locus protocol message. Do not treat a
message type as a value for `-Command`.

| Top-level `-Command` | Use |
|---|---|
| `probe` | Check package and bridge connectivity before every Unity operation. |
| `send` | Send one approved protocol message listed below. |
| `thumbnail` | Save an asset thumbnail as a local PNG. |
| `render-preview` | Save a Prefab/model preview as a local PNG. |
| `execute` | Run authorized C# from a file. |
| `recompile` | Request compilation and wait through domain reload. |

Resolve the client once:

```powershell
$locusBridge = Join-Path $env:USERPROFILE '.agents\skills\locus-unity-bridge\scripts\locus-unity.ps1'
```

## 1. Probe first

```powershell
& pwsh.exe -NoLogo -NoProfile -NonInteractive -File $locusBridge `
    -Command probe -ProjectPath 'E:\Source\SomeUnityProject'
```

| Status | Next action |
|---|---|
| `connected` | Continue with an operation. |
| `package_missing` | Report the expected `Packages/com.farlocus.locus`; request approval before installation. |
| `package_invalid` | Report the incomplete installation path. |
| `bridge_not_enabled` | Ask the user to enable/connect Locus for this project. |
| `editor_unreachable` | Verify that the matching project is open in Unity and Locus is active. |

The probe recognizes canonical and legacy package layouts, plus a live
computed pipe when `LOCUS_UNITY_NATIVE_BRIDGE=1` is enabled.

## 2. Inspect with `send`

Use this shape for all entries in the table. Successful responses are JSON;
parse a nested JSON payload from the envelope's `message` field when noted.

```powershell
& pwsh.exe -NoLogo -NoProfile -NonInteractive -File $locusBridge `
    -Command send -ProjectPath 'E:\Source\SomeUnityProject' `
    -MessageType <message-type> -Message '<json-or-empty-string>'
```

| Need | `-MessageType` | `-Message` / guidance |
|---|---|---|
| Editor status and active scene | `status` | Empty string. |
| Console errors or warnings | `unity_get_console_log` | `{"levels":["error","warn"],"limit":20}`; raise `limit` only when needed. |
| Known serialized target | `property_tree_read` | Read [Property Tree requests](references/property-tree.md). |
| Locate serialized properties | `property_tree_discover` | Read [Property Tree requests](references/property-tree.md). |
| Find objects/fields in `.unity` or `.prefab` | `search_yaml` | Read [Scene and Prefab search](references/scene-prefab-search.md). |
| Inspect one found scene/Prefab object | `read_yaml` | Use the `object_path` from search; see the same reference. |
| Capture Game, Scene, or Editor window | `capture_viewport` | JSON below. |

`property_tree_write` and `property_tree_apply` modify serialized data; never
use them as diagnostics. `get_console_text` is a large compatibility snapshot,
not a default query.

For `capture_viewport`, set `target` to `game`, `scene`, or `editor_window`.
`maxLongEdge` defaults to `1280`, accepts `0` for source size, and is capped at
`8192`; `editor_window` optionally accepts `windowTitle`. The response returns
a PNG path under `Library/Locus/Screenshots/`; report it and do not delete it.

```json
{"target":"game","maxLongEdge":1280}
```

## 3. Use a top-level operation

### Asset images

Do not send `asset_thumbnail` or `asset_preview_render` directly: their PNG
responses contain Base64. These commands decode it locally and return only a
path plus image metadata. Use `-OutputDirectory` to choose a local destination;
otherwise the client uses its local temporary folder.

```powershell
# Any asset under Assets/ or Packages/; -MaxSize is 64-512 (default 192).
& pwsh.exe -NoLogo -NoProfile -NonInteractive -File $locusBridge `
    -Command thumbnail -ProjectPath 'E:\Source\SomeUnityProject' `
    -AssetPath 'Assets\Art\Icon.png' -MaxSize 192

# Prefab or model only; width/height are 96-640.
& pwsh.exe -NoLogo -NoProfile -NonInteractive -File $locusBridge `
    -Command render-preview -ProjectPath 'E:\Source\SomeUnityProject' `
    -AssetPath 'Assets\Props\Chair.prefab' `
    -PreviewWidth 320 -PreviewHeight 220 -Yaw 25 -Pitch -12 -Distance 1.15
```

Use `-PanX`, `-PanY`, and `-PanZ` only when reframing the model preview is
necessary. Rendering does not modify the source asset.

### Execute authorized C# or recompile

Use `execute` only when the curated operations do not answer the task. Prefer a
multi-line `-CodeFile` and `print(...)` or `printJson(...)` for returned data.

`-CodeFile` content becomes the body of a Locus-generated entry method, not an
independent C# file. Write direct statements and, when useful, local functions;
async local functions must be awaited from the snippet. Do not declare `Main`,
`class`, `struct`, or `namespace`. The injected `print`, `printJson`, `clear`,
`ctx`, and `ct` are available directly; a non-null `return` value is printed.

Top-level `await` is supported. For Unity work that must span editor frames,
prefer `await ctx.wait`, `ctx.WaitFrames(...)`, `ctx.WaitSeconds(...)`, or
`ctx.WaitUntil(...)`; their continuations run from `EditorApplication.update`.
Check `ct` (the injected cancellation token) in long loops. Emit `print(...)`
or `ctx.Progress(...)` at least every 30 seconds, otherwise Locus cancels the
execution for inactivity. Set `-TimeoutSeconds` for the expected total duration.

```csharp
print("Waiting for the editor");
await ctx.WaitFrames(3);
ctx.Progress("Inspecting scene", 0.5f);
ct.ThrowIfCancellationRequested();
print("Ready");
```

Use these `ctx` awaitables rather than `Task.Delay` when Unity API access must
continue after the wait.

```powershell
& pwsh.exe -NoLogo -NoProfile -NonInteractive -File $locusBridge `
    -Command execute -ProjectPath 'E:\Source\SomeUnityProject' `
    -CodeFile 'C:\Temp\inspect-scene.cs' -TimeoutSeconds 30

& pwsh.exe -NoLogo -NoProfile -NonInteractive -File $locusBridge `
    -Command recompile -ProjectPath 'E:\Source\SomeUnityProject' `
    -TimeoutSeconds 10 -RecompileTimeoutSeconds 120
```

## Transport notes

- The pipe can emit `unity-editor-update` events before the matching response;
  the client already waits for the envelope whose `reply_to` matches its request.
- Do not target the Locus source checkout when the requested Unity project is
  elsewhere.
- Do not assume Unity MCP is required; this skill uses Locus directly.
