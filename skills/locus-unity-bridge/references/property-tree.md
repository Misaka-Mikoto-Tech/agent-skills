# Property Tree requests

Use this read-only interface to inspect Unity serialized properties without
writing ad-hoc C#. These are `send` message types, not top-level `-Command`
values. Pass each JSON payload as `-Message` to the client's `send` command.

## Read a known target

For the current Unity selection:

```powershell
& pwsh.exe -NoLogo -NoProfile -NonInteractive -File $locusBridge `
    -Command send -ProjectPath 'E:\Source\SomeUnityProject' `
    -MessageType property_tree_read `
    -Message '{"target":{"kind":"selection"},"maxDepth":2,"maxArrayItems":20}'
```

For an asset, use an `Assets/` or `Packages/` path:

```json
{
  "target": { "kind": "asset", "path": "Assets/Config/GameSettings.asset" },
  "maxDepth": 3,
  "maxArrayItems": 20
}
```

For a scene object or component, identify its scene and hierarchy path. Add
`componentType` and, when needed, `componentIndex` for a component target:

```json
{
  "target": {
    "kind": "component",
    "scenePath": "Assets/Scenes/Main.unity",
    "objectPath": "Player/Camera",
    "componentType": "UnityEngine.Camera"
  },
  "maxDepth": 2,
  "maxArrayItems": 20
}
```

Supported target kinds are `selection`, `asset`, `scriptableobject`,
`material`, `gameobject`, and `component`. Use the smallest useful
`maxDepth` and `maxArrayItems` to bound output.

## Discover a serialized property

Use discovery when the target is known but its serialized property path is
not. Constrain the search with `query`, `fieldName`, `fieldType`, or
`matchFields`, and keep `maxResults` modest:

```json
{
  "target": { "kind": "selection" },
  "query": "speed",
  "matchFields": ["name", "value"],
  "maxDepth": 3,
  "maxResults": 20
}
```

The response reports a `propertyPath` for each match, along with type and
display information. To read only that property, copy it into the next
request's `target.propertyPath`:

```json
{
  "target": { "kind": "selection", "propertyPath": "m_Speed" },
  "maxDepth": 2,
  "maxArrayItems": 20
}
```

If the response is `truncated`, tighten the query rather than raising limits
blindly.

## Boundary

`property_tree_write` and `property_tree_apply` can alter Unity serialized
data. Do not use either without explicit user authorization for that change.
