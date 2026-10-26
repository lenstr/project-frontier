# Project Frontier

Playable 3D exploration and automation game, primarily in Goose. Project documentation is in English. Use conventional commits.

- Pin Goose to the exact upstream snapshot in `tools/goose-toolchain.env`; `tools/bootstrap.sh` builds it under `.tools/`. Do not silently follow `master` or install unmerged PRs.
- Keep game rules, terrain generation, entity storage, navigation and persistence in Goose.
- Use the official `gfx`, `ui` and `audio` packages for platform work. Any extra native code must have a narrow, documented purpose.
- Preserve headless deterministic tests alongside graphical gameplay.
- Never commit the downloaded compiler, build products or player saves.
- Record measured results separately from assumptions in `GOOSE_EVALUATION.md`.
- Keep Goose source readable: four-space indentation, spaces around operators, one statement per line, and expanded control flow. Avoid compressed one-line functions and long nested conditionals.
- Use `./tools/format.sh` and verify `./tools/format.sh --check`; the upstream formatter preserves intentional line breaks.
- `trim_memory()` only releases unused pages of the calling thread's data stacks. Schedule it after temporary scopes return, not every frame; it does not shrink retained pools or release GPU handles.
- Several agents may share this checkout: own specific files, stage only those files, and do not revert others' changes.
