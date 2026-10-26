# Developer panel: design

Owner: art director session (Opus 5.5). This file owns the panel's layout, information hierarchy,
colors, plots and the parameter set. Code structure belongs to the coding agents. Palette names
refer to `ART_DIRECTION.md` §2.

## Purpose

The user asked for a developer panel with "интересную статистику по времени работы количеству чего
либо ... чтобы понимать внутрянку как там чего раскладывается и крутится и еще ползунки разные чтобы
поменять параметры", and said it was "не понятно в чем язык помог". The panel answers three
questions, in order:

1. Where does the frame go? Overview.
2. What is the engine holding and churning right now? World, Goose.
3. What happens if I push it? Controls, Inspect.

It replaces the current debug text block (raw floats such as `0.003000255674123764 ms`). No
value is ever printed unformatted.

Honesty rule: the Goose tab shows memory reuse, handle safety and threading behavior. It never
claims that frame rate or GPU time comes from Goose. Show a metric only if the code measures it;
an unmeasured field is omitted, not estimated.

## Opening it

- **F1** cycles closed → full → compact → closed. The state persists across sessions in settings,
  not in saves.
- A **visible button** whenever the panel is closed: a pill at the bottom-right, 16 px from the
  right edge, its bottom edge 8 px above the biome card: a key chip "F1" (Ivory fill, Navy Ink
  text, 20x20) plus "Developer" in 14 px Ivory, on Navy Ink 86%, rounding 10, 112x28. Clicking it
  opens the full panel. When open, the chip border is Signal Orange.
- While the panel is open, the cursor is free over the panel and mouse-look requires a held right
  mouse button. Keyboard movement keeps working, so the user can fly around and watch numbers.

## Geometry at 1280x800 (scale everything by `ui_scale`)

| Element | Rect (x, y, w, h) | Notes |
|---|---|---|
| Full panel | 814, 16, 450, 768 | right side; 64% of the world stays visible |
| Header | inside, 0, 0, 450, 44 | |
| Tab bar | inside, 0, 44, 450, 30 | 5 tabs × 90 |
| Body | inside, 12, 82, 426, 674 | scrollable group, 12 px padding |
| Compact panel | 814, 16, 450, 156 | header + frame chart only |
| Power card while open | 566, 16, 240, 64 | moves to the left of the panel |
| Toasts while open | 526, 88, 280, w | same column |
| Biome card | hidden while full is open | its text moves into the World tab |

Panel style: Navy Ink at 92% (more opaque than HUD cards, for plot legibility), the same
`#24305A` → Navy Ink gradient, 1 px border `#3A4670`, rounding 6. Sections inside the body are
separated by 16 px gaps and a section caption, not by boxes inside boxes.

## Typography and number formatting

- Roboto everywhere in this panel (the ProggyClean rule in `ART_DIRECTION.md` §7 is replaced
  for the developer panel: the panel is a designed tool now, not a debug dump).
- Sizes: section caption 12 UPPER CASE Signal Orange; label 13 secondary `#A9B0C8`; value 14
  Ivory, right-aligned in a fixed column; hero value 22 Ivory.
- Time: `8.39 ms` (2 decimals under 10 ms, 1 decimal from 10 ms up), `412 µs` under 1 ms.
- Counts: thin-space groups `12 064`. Rates: `38 /s`. Memory: `142.6 MB`. Shares: `27%`.
- Value colors by state, never green: good Power Cyan, warning Signal Orange, bad Alert Red,
  neutral Ivory.

## Series colors (fixed in every tab and chart)

| Series | Color | Hex |
|---|---|---|
| Frame total | Ivory | `#F2EAD8` |
| Simulation (Goose game rules, robots, power, navigation) | Signal Orange | `#FF7A2F` |
| World (stream, mesh build, upload) | Lavender | `#B7A4E6` |
| Render CPU (scene build, draw submit) | Power Cyan | `#5FF2E0` |
| GPU (only if measured) | Glacite | `#8FD3FF` |
| UI and HUD | Bone | `#D3C8B0` |
| Other / unattributed | Slate | `#4A5578` |
| Memory | Aurite | `#FFD447` |

Chart surface: `#141B33`, gridlines `#2B3A66` 1 px, axis labels 11 px `#5E6788`. A budget line
at `1000 / refresh_hz` ms is dashed Signal Orange at 60% alpha, labeled at its right end
("8.3 ms budget"). Every chart has a legend row of 8 px square swatches plus names directly
above it, and the y-axis maximum printed at the top left with its unit.

All time series hold exactly 240 samples (a ring buffer, one sample per frame unless noted).

## Header (always visible, also in compact mode)

- Left: "DEVELOPER" caption, below it `Goose v2026.3 · release · 1280x800` in 11 px secondary.
- Right: FPS as the hero value (22 px), then three chips `p50 7.9`, `p95 9.4`, `p99 12.1` (ms over
  the 240-frame window), each colored by the budget: under budget cyan, up to 1.5x budget orange,
  over that red.
- Far right: the panel's own cost, `panel 0.21 ms`, in 11 px secondary. The panel must show what
  it costs.
- Compact mode adds only the Overview frame chart under the header (426x96).

## Tab bar

Overview, World, Goose, Controls, Inspect. Selected: Ivory 14 px with a 2 px Signal Orange
underline; others secondary 13 px. Clicking switches; `Shift+F1` cycles.

## Overview tab

1. **Frame chart** (426x120): stacked bars, one 1.77 px column per frame (240 × 1.77 = 426),
   segments in series order bottom-up: simulation, world, render CPU, UI, other. The frame total
   is an Ivory polyline over the top. Y range `0 .. max(p99 * 1.25, budget * 1.5)`, rounded up to
   a whole ms. Spikes over budget get a 2 px Alert Red tick above the column.
2. **Where the frame goes** (426x14): a single 100% bar split by the same series, averaged over
   240 frames. Below it, a table with one row per series: swatch, name, avg, p95, share. Sorted by
   avg, descending.
3. **Simulation breakdown**: rows for each subsystem the sim timer covers (machines, power
   network, belts and rails, robots and navigation, packets). Each row has a name, a 160 px
   horizontal bar (orange, scaled to the largest row), and avg/p95 in µs. This is where Goose code
   time is visible; label it "Simulation (Goose)".
4. **Counters**, a grid of 3 × 2 tiles, 136x52 each: caption 11 px secondary, value 18 px Ivory,
   a 40x14 sparkline (last 240 frames) in the series color at the right. Tiles: Entities live,
   Robots active, Chunks loaded, Mesh jobs queued, Triangles, Draw calls.

## World tab

1. **Chunk map** (200x200, left), square cells around the player out to the view radius (radius
   8 means 17x17 cells, 11 px each). Cell fill: loaded is the biome ground color at 55% value;
   queued is a 1 px Lavender outline; generating is solid Lavender pulsing at 2 Hz; evicted in the
   last 2 s is Slate fading out; far-LOD ring cells are `#24305A`. The player is an orange
   triangle pointing along the camera yaw. This one picture explains streaming better than numbers.
2. **Right of the map** (214 wide): biome name and the climate value, view radius in chunks and
   meters (`6 · 192 m`), loaded/slots/high-water, generated/s and evicted/s, edits stored.
3. **Workers chart** (426x80): job queue depth (Lavender line) and per-chunk generation ms
   (Lavender bars at 50% alpha), 240 frames.
4. Rows: generation p50/p95 per chunk, mesh build p50/p95, GPU upload ms per frame, far LOD
   triangles, vegetation instances (near / far tint).

## Goose tab

A one-line lead in 13 px secondary at the top: "Pooled storage, generational handles and worker
queues in this build. Frame time is mostly mesh and draw work; this tab shows memory reuse and
safety, not FPS."

1. **Pools.** One row per pool: entities, inventory cells, queue cells, edge cells, chunk slots,
   packets. Each row has the name and a 426x12 bar: live (Power Cyan), retained-free (Slate),
   unused capacity (`#141B33`), plus a 2 px Signal Orange tick at the high-water mark. Under it in
   11 px: `live 1 024 · free 312 · high-water 1 336 · capacity 2 048`.
2. **Reuse chart** (426x90): entity pool live (cyan) and allocated slots (Slate fill) over 240
   samples at 4 Hz (60 s). After a churn, the slots line stays flat while live rises and falls.
   That plateau is the language story; caption it "storage reused, not grown".
3. **Handles.** Rows: issued this session, highest generation, stale lookups rejected (cyan
   count), stale-handle crashes `0`. A handle is always drawn as a chip `#0412 g3` (index and
   generation) in Navy with an Ivory 12 px label, here and in Inspect.
4. **Churn controls**: buttons `Spawn 1 000`, `Destroy 1 000`, `Churn ×10` (10 rounds of both).
   After each, one result line: `1 000 spawned in 7.6 ms · slots 1 124 → 1 124 · RSS 142.6 →
   142.7 MB`. Slots unchanged is cyan; growth is orange.
5. **Memory chart** (426x70): process RSS in Aurite, 240 samples at 4 Hz, y axis in MB.
6. **Threads**: one row per world worker: busy % bar (Lavender), jobs done/s, queue in/out
   depth, and the main thread's `qput`/poll time in µs.

## Controls tab

Grouped rows: label 150 px (13 px secondary), slider 196 px, value 64 px right-aligned with its
unit, and a 16 px reset button. The reset button and an orange dot on the label show only when the
value differs from its default; the default is in the tooltip. A row's control changes the running
game immediately.

| Group | Control | Range, step | Default |
|---|---|---|---|
| SIMULATION | Simulation speed | 0..4, 0.25 (0 shows "paused") | 1 |
| | Day cycle | toggle Pause, button `Step +1 h` | running |
| | Time of day | 0..24 h, 0.25 | 15:00 |
| WORLD | View radius | 2..8 chunks; value shows `· 192 m` and the chunk count `169` | 6 |
| | Mesh jobs per frame | 1..8 | root's default |
| | Far LOD terrain | toggle | on |
| ATMOSPHERE | Fog clear distance | 80..400 m, 10 | 140 |
| | Visibility | 600..2400 m, 50 | 1600 |
| | Shadows | toggle | on |
| SCENE | Vegetation density | 0.5..3.0 ×, 0.1 | 1.0 |
| LOAD | Colony load | 32..2000 entities, 32; button `Load factory` applies it | 512 |
| | Entities | buttons `Spawn 1 000`, `Destroy 1 000` | |
| | Robots | button `+10 robots` | |

A slider whose cost is large shows a one-line orange hint under it while dragging, from measured
data where available (for example `radius 8: 289 chunks, last measured 1.9 ms mesh/frame`).
`Reset all` sits at the bottom, right-aligned.

## Inspect tab

- Picking: the `Pick` button arms pick mode (the cursor becomes a cyan ring); the next left click
  in the world pins the entity under it. Middle click also pins directly.
- The pinned entity gets a world marker: a cyan ground ring 1.5x its footprint, pulsing ±10% at
  1 Hz, emissive 1.0. It is visible through the panel's 64% world view, so the user sees what is
  being inspected.
- Body, top to bottom:
  1. Title: kind icon (the hotbar silhouette), name 16 px Ivory, handle chip, state chip
     (Working cyan, Idle orange, Unpowered red).
  2. Rows: entity age, handle generation and the time it was issued, position, power draw or
     generation, throughput per minute.
  3. **Inventory**: one row per item, an ore diamond, name, a bar of count over capacity in the
     item color, count.
  4. **Queues**: input and output as slot strips of 14 px squares, filled with the item diamond
     or empty `#141B33`; capacity is the strip length.
  5. **Links**: one row per edge: direction arrow, kind (belt, rail, wire, robot route), the
     target's handle chip and name. Clicking a row pins that target, so the user can walk the
     production graph.
  6. Robots add: task, cargo, path length, and the path drawn in the world as a thin cyan line.
- When the pinned entity is destroyed, the body is replaced by one orange line: `Handle #0412 g3
  is stale: entity destroyed 2.4 s ago (lookup rejected)`, plus the last known values in
  disabled color. Inspect never crashes on a stale handle, and it shows that.

## Out of scope for now

GPU timestamp queries (if the `gfx` package lacks them, omit the GPU series), saved profiles,
flame graphs, remote telemetry, editing entity state from Inspect.
