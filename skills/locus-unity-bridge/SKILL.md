---
name: locus-unity-bridge
description: Use when an agent needs to inspect or control a real Unity Editor through Locus, especially when Unity MCP is unavailable, named-pipe discovery is needed, C# must be executed, or Unity scripts must be recompiled.
---

# Locus Unity Bridge

Use the bundled PowerShell client to inspect or control a real Unity Editor.
Do not rewrite its named-pipe client. Always pass the exact Unity root to
`-ProjectPath`; it identifies the bridge connection.

## Safety

`execute` can run arbitrary C# in Unity, and the property-tree write messages
(`property_tree_write`, `property_tree_apply`) mutate the user's project. Use
any of them only for the project and task the user authorized, and prefer the
read path when the task is inspection. A connected bridge requires Locus to
already be installed and enabled in the target project. Do not install or
repair Locus, create its marker, launch or close Unity, or modify a project
merely to connect the bridge.

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
| `execute` | Run an authorized C# snippet. |
| `recompile` | Request compilation and wait through domain reload. |

All commands except `recompile` use `-TimeoutSeconds` (default `10`, range
`1`–`600`) for their final pipe response. Increase it only for an operation
that is expected to take longer. `recompile` instead uses its dedicated timeout
options below.

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
| `package_missing` | Report the expected `Packages/com.farlocus.locus`; installation is outside this skill. |
| `package_invalid` | Report the incomplete installation path; repair is outside this skill. |
| `bridge_not_enabled` | Ask the user to enable/connect Locus for this project. |
| `editor_unreachable` | Verify that the matching project is open in Unity and Locus is active. |

The probe recognizes canonical and legacy package layouts. It uses a bridge
marker when present, otherwise it computes the project-specific pipe name.

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

`get_console_text` is a large compatibility snapshot, not a default query.

For `capture_viewport`, set `target` to `game`, `scene`, or `editor_window`.
`maxLongEdge` defaults to `1280`, accepts `0` for source size, and is capped at
`8192`; `editor_window` optionally accepts `windowTitle`. The response returns
a PNG path under `Library/Locus/Screenshots/`; report it and do not delete it.

```json
{"target":"game","maxLongEdge":1280}
```

### Writing properties (mutating — confirm authorization first)

Everything above is read-only. Unity's property write path is a separate,
explicitly authorized step:

| Need | `-MessageType` | `-Message` |
|---|---|---|
| Set one existing serialized property | `property_tree_write` | `{"target":{"kind":"selection","propertyPath":"m_Speed"},"valueJson":"12.5"}` |
| Commit several writes together | `property_tree_apply` | `{"writes":[<write request>, ...]}` |

A write reuses the read targets (`selection`, `asset`, `scriptableobject`,
`material`, `gameobject`, `component`) plus the `target.propertyPath` reported
by a preceding read or discover. `valueJson` is the JSON-encoded value.
`mode: "preview"` applies a transient drag preview instead of committing; omit
`mode` for a real commit. `bindingId` is only echoed back and may be omitted.

`property_tree_write` records Undo, marks the object and scene dirty, and
returns a fresh read plus a `beforeSnapshot`. **It does not save the asset** —
`live` writes keep Property Tree commit semantics, so the asset can still be
waiting for Unity to save it. Never report a write as persisted without a
separate save step, and say so when the file is still dirty.

Writes that must be persisted, revision-checked, or correct against Prefab
inheritance use a different surface: `asset_api` (transaction id,
`expected_revision`, `dependencies`, `persist: "disk"`, array operations,
batches up to 256 files / 10,000 operations). That is the transactional YAML
backend, not a raw file writer; treat it as its own task and confirm scope with
the user before using it.

Do not hand-edit `.unity`/`.prefab` YAML as a substitute for either path: exact
fileIDs/GUIDs, Prefab variant override/revert topology, import ordering, and
stale-revision rejection are precisely what the transactional layer exists to
handle.

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

Use `execute` only when the curated operations do not answer the task. Use
`-Code` for a short snippet or `-CodeFile` for multi-line/reusable code; provide
exactly one. Prefer `print(...)` or `printJson(...)` for returned data.

#### Snippet contract

- The supplied code is the body of a Locus-generated entry method, not an
  independent C# file. Write direct statements and local functions; do not
  declare `Main`, `class`, `struct`, or `namespace`.
- `print`, `printJson`, `clear`, `ctx`, and `ct` are injected. A non-null
  `return` value is printed as text.
- For structured output, use `printJson(new { key = value, items = values })`.
  It serializes anonymous objects, dictionaries, and ordinary property-bearing
  values to JSON; do not declare a DTO class solely to return data.

#### Execute safety

- Every loop in an execute snippet needs an explicit completion condition and an
  iteration or time bound. Do not use unbounded `while`, `for`, or polling loops.
- Long-running loops must call `ct.ThrowIfCancellationRequested()` regularly;
  use `await ctx...` for waits that continue with Unity API access.
- `-TimeoutSeconds` only stops this client from waiting; it does not stop Unity
  code already running. Treat it as a wait limit, not a recovery mechanism.
- The client can cancel a running snippet only when `-AcceptCancel` is set and
  its stdin stays writable. It then sends `cancel_execute_code` carrying the
  execution id injected into the snippet (`//__LOCUS_EXECUTION_ID__:<id>`, the
  same id `execute_code_progress` uses). Without `-AcceptCancel` there is no
  cancel path, so a timed-out snippet simply keeps running.
- Locus also has a 30-second inactivity watchdog. It requests cancellation and
  returns a timeout, but cannot preempt code already blocking Unity's main
  thread. Do not treat that watchdog as a hard stop.
- The watchdog only fires on silence, so a snippet that keeps emitting `print`
  or `ctx.Progress(...)` can run indefinitely.
- Never re-send an `execute` merely because it timed out: the snippet may still
  be running and would then execute a second time. Use `-AcceptCancel` when you
  may need to stop it, keep snippets bounded and repeat-safe, and tell the user
  when a snippet might still be live instead of retrying silently.

| Symbol | Purpose |
|---|---|
| `print` / `printJson` | Append plain text / JSON to the final result buffer. |
| `clear` | Clear that buffer; rarely needed. |
| `ctx` | Unity-aware waits and progress, such as `WaitFrames`, `WaitSeconds`, and `Progress`. |
| `ct` | Cancellation token; check it in long loops or call `ThrowIfCancellationRequested()`. |

#### Async work

Top-level `await` is supported. For waits followed by Unity API access, use a
`ctx` awaitable so the continuation resumes from `EditorApplication.update`.

| Expression | Waits for |
|---|---|
| `await ctx.wait` / `await ctx.WaitFrame()` | The next editor update. |
| `await ctx.WaitFrames(n)` | `n` editor updates. |
| `await ctx.WaitSeconds(s)` | At least `s` seconds, then a later editor update. |
| `await ctx.WaitUntil(() => condition, "description")` | A condition checked on each editor update. |

Do not pass Unity yield objects to `ctx`. Await local async functions from the
snippet. Each `await ctx...` checks cancellation before continuing. In long
synchronous loops, or after an external await that does not accept `ct`, call
`ct.ThrowIfCancellationRequested()`. The watchdog fires after 30 seconds of
silence: emit `ctx.Progress(...)` more often than that. Do not use a single
silent `await ctx.WaitSeconds(30)` or longer; split a longer wait into chunks
under 30 seconds and report progress between them. `print(...)` also resets the watchdog,
but does not check cancellation, so pair it with an explicit `ct` check in
long-running loops. Set `-TimeoutSeconds` for the expected total duration.

For a bounded scan, check cancellation on every iteration and periodically
report progress before yielding the Unity main thread:

```csharp
var scene = SceneManager.GetActiveScene();
var roots = scene.GetRootGameObjects();
var rootNames = new List<string>(roots.Length);

for (var i = 0; i < roots.Length; i++)
{
    // Limit cancellation latency within this 100-item batch.
    ct.ThrowIfCancellationRequested();
    rootNames.Add(roots[i].name);

    if ((i + 1) % 100 == 0 || i == roots.Length - 1)
    {
        ctx.Progress("Inspecting roots", $"{i + 1}/{roots.Length}",
            (float)(i + 1) / roots.Length);
        await ctx.WaitFrame();
    }
}

printJson(new { scene = scene.name, rootNames });
```

Use these `ctx` awaitables rather than `Task.Delay` when Unity API access must
continue after the wait. For `execute`, `-TimeoutSeconds` is the maximum wait
for the snippet's final response.

```powershell
& pwsh.exe -NoLogo -NoProfile -NonInteractive -File $locusBridge `
    -Command execute -ProjectPath 'E:\Source\SomeUnityProject' `
    -CodeFile 'C:\Temp\inspect-scene.cs' -TimeoutSeconds 30

# Opt in only when intermediate async progress is useful.
& pwsh.exe -NoLogo -NoProfile -NonInteractive -File $locusBridge `
    -Command execute -ProjectPath 'E:\Source\SomeUnityProject' `
    -CodeFile 'C:\Temp\inspect-scene.cs' -TimeoutSeconds 60 `
    -FollowProgress -ProgressIntervalSeconds 2 -AcceptCancel

& pwsh.exe -NoLogo -NoProfile -NonInteractive -File $locusBridge `
    -Command recompile -ProjectPath 'E:\Source\SomeUnityProject' `
    -RecompileRequestTimeoutSeconds 10 -RecompileTimeoutSeconds 120
```

For `recompile`, `-RecompileRequestTimeoutSeconds` limits each pipe request;
`-RecompileTimeoutSeconds` limits the complete compile, reload, and reconnect
workflow. `-TimeoutSeconds` does not apply to `recompile`.

#### Cancel a running execute

Add `-AcceptCancel` only when the caller keeps the running PowerShell process's
stdin writable. To stop the execution, write one line containing `cancel` to
that stdin. The script sends the cancellation on its existing Locus connection,
then returns `{ "Status": "canceled", ... }`. This works with or without
`-FollowProgress`; progress merely gives the agent a basis for deciding. Do not
start a second Locus client to cancel a running execution. Cancellation is
cooperative: snippets must await `ctx` or check `ct` in long-running code.

For progress-driven cancellation, the process runner must consume stdout
incrementally while keeping stdin writable. Concurrently read progress records
line by line, then write `cancel` to the same process's stdin when needed. A
final-only capture such as waiting for `ReadToEndAsync()` cannot make a decision
from progress before the process exits. Keep `-NonInteractive`. If cancellation
input is unavailable, split the work into bounded execute calls.

## Invocation pitfalls (Windows / PowerShell)

`pwsh.exe -File <script> -Message '<json>'` mangles the argument on the way to
the native process: internal `"` are stripped (`JSON parse error: Missing a
name for object member`) and an empty `-Message ''` is dropped entirely
(`Missing an argument for parameter 'Message'`). Invoke the script in the
current PowerShell session instead, so the parameters bind as real objects:

```powershell
$locusBridge = Join-Path $env:USERPROFILE '.agents\skills\locus-unity-bridge\scripts\locus-unity.ps1'
& $locusBridge -Command send -ProjectPath 'E:\Source\SomeUnityProject' `
    -MessageType unity_get_console_log -Message '{"levels":["error","warn"],"limit":15}'

# No-payload messages: '""' also works, but '' only works when called in-process.
& $locusBridge -Command send -ProjectPath 'E:\Source\SomeUnityProject' -MessageType status -Message ''
```

Use `pwsh.exe -File` only for calls whose arguments contain no quotes and no
empty strings. Note `& $locusBridge ... 2>&1 | Out-String` wraps errors in
CLIXML noise; read the raw output when diagnosing.

A transient `managed_reloading` failure means Unity is compiling or in a domain
reload, not that the bridge is broken. Retry `status` every few seconds, or use
`recompile` to drive the reload deliberately, and only then report a problem.

## Transport notes

- `execute -FollowProgress` is opt-in for long async snippets. It checks
  progress every 2 seconds by default and writes only meaningful status changes
  as compact `<locus-execute-progress>{...}</locus-execute-progress>` lines
  before the usual final JSON response. The compact record excludes `sourceText`;
  do not use it for short operations or as a substitute for final output.
- Do not target the Locus source checkout when the requested Unity project is
  elsewhere.
- Do not assume Unity MCP is required; this skill uses Locus directly.
