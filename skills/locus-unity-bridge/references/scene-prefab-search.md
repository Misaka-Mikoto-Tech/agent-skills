# Scene and Prefab search

`search_yaml` and `read_yaml` inspect `.unity` and `.prefab` files through
Unity APIs. These are `send` message types, not top-level `-Command` values.
Despite their names, they are not generic raw-YAML readers.

## Find candidate objects

`search_yaml` requires `file_path` plus either `query` or
`component_filter`. Use `limit`, `max_nodes`, and `path_prefix` to bound the
result before sending it to the model:

```powershell
& pwsh.exe -NoLogo -NoProfile -NonInteractive -File $locusBridge `
    -Command send -ProjectPath 'E:\Source\SomeUnityProject' `
    -MessageType search_yaml `
    -Message '{"file_path":"Assets/Scenes/Main.unity","query":"Player","limit":20,"max_nodes":200}'
```

Search by component instead when the object name is unknown:

```json
{
  "file_path": "Assets/Prefabs/Enemy.prefab",
  "component_filter": "UnityEngine.AI.NavMeshAgent",
  "limit": 20,
  "max_nodes": 200
}
```

`match_fields` is one comma-separated string, not a JSON array. Use it to
search nested serialized data without broadening every match field:

```json
{
  "file_path": "Assets/Scenes/Main.unity",
  "query": "OnClick",
  "match_fields": "field_name,field_value",
  "limit": 20,
  "max_nodes": 200
}
```

## Read one object

Search returns readable text with a source banner. Copy the hierarchy path at
the beginning of a matching result line; omit any displayed component suffix
or annotation. Pass that value as `object_path` to `read_yaml`:

```json
{
  "file_path": "Assets/Scenes/Main.unity",
  "object_path": "Player/Camera",
  "max_field_depth": 2,
  "max_array_items": 20
}
```

For a search involving nested serialized fields such as UnityEvents, use
`match_fields` to target field names or values before increasing field depth.
The search path has higher default field/array bounds than the displayed read
result so it can find nested matches without returning all nested data.

## Scene-loading behavior

For an unloaded scene, Unity 2023.1 and newer can open a Preview Scene and
restore the user's regular active scene. Older Unity versions do not additively
open the scene; the request reports that it cannot inspect the unloaded scene.
Use Property Tree instead for a known object in an already loaded scene.
