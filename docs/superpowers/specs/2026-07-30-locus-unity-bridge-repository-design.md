# Locus Unity Bridge Repository Integration Design

## Goal

Add the existing `locus-unity-bridge` personal skill to this repository and
make `~/.agents/skills` the documented default installation directory so one
installation can be shared by compatible agents.

## Repository Content

Copy the complete verified skill into `skills/locus-unity-bridge/`:

- `SKILL.md`
- `agents/openai.yaml`
- `scripts/locus-unity.ps1`
- `scripts/Test-LocusUnityBridge.ps1`

The repository copy must not depend on the local `E:\Source\Locus` checkout.
It keeps the existing safety boundary: probe first; never install the Unity
package, launch or close Unity, create the marker, or mutate a project without
separate user authorization.

## README Changes

- Change the default target from `~/.codex/skills` to `~/.agents/skills`.
- Keep the current portable `$repo = (Get-Location).Path` pattern.
- Add `locus-unity-bridge` to the copy example and available-skills table.
- Explain that agents without `.agents/skills` support should replace
  `$target` with their own skill directory.
- Add a short Locus prerequisite note: Windows, PowerShell 7, a Unity project,
  and the Locus package/bridge for live control. A missing package remains a
  diagnostic state and is not installed automatically.
- Keep README reader-facing and installation-first; do not turn it into a
  maintainer log or duplicate the full skill instructions.

## Verification

- Establish a failing README check before editing: `.agents/skills` and the
  Locus inventory entry are currently absent.
- Confirm the repository skill matches the installed `.agents` source.
- Run `scripts/Test-LocusUnityBridge.ps1` from the repository copy.
- Run the official skill validator.
- Check PowerShell syntax, `git diff --check`, LF normalization, and absence of
  `E:\Source\Locus` runtime references.
