# Project Frontier

Playable 3D exploration and automation game, primarily in Goose. Project documentation is in English. Use conventional commits.

- Pin the compiler to Goose v2026.3. The local distribution is under `.tools/goose-v2026.3-macos-arm64/`.
- Keep game rules, terrain generation, entity storage, navigation and persistence in Goose.
- Use the official `gfx`, `ui` and `audio` packages for platform work. Any extra native code must have a narrow, documented purpose.
- Preserve headless deterministic tests alongside graphical gameplay.
- Never commit the downloaded compiler, build products or player saves.
- Record measured results separately from assumptions in `GOOSE_EVALUATION.md`.
- Keep Goose source readable: four-space indentation, spaces around operators, one statement per line, and expanded control flow. Avoid compressed one-line functions and long nested conditionals.
- Several agents may share this checkout: own specific files, stage only those files, and do not revert others' changes.
