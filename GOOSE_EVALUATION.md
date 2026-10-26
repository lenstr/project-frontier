# Goose evaluation: Project Frontier

## Scope and verdict

Project Frontier is a playable 3D exploration and automation game written in Goose. It includes
streamed procedural terrain, terrain editing, mining, inventories, construction, power,
processing, visible resource transport, autonomous local-pathfinding robots, a progression goal,
save/load, procedural visuals/audio and deterministic stress tools.

**Measured finding:** the implemented pools repeatedly reuse storage under arbitrary entity
destruction, independent collection growth, chunk eviction and world restoration. The tests
described below pass. A native UI/GPU resource-retirement problem was reproduced and worked
around from Goose; the corrected full-HUD run also has bounded observed memory over 30,000
frames. No project-defined native allocator or native simulation was necessary.

**Engineering judgment:** Goose is viable for this size of game, particularly when lifetimes
are organized as fixed records, reusable runs and scope-local scratch. This result does not
establish production readiness for a large voxel game, a many-thousand-machine factory, or a
long-lived commercial engine. Language/compiler diagnostics, profiling support and scaling
algorithms need further work.

## Full-detail survey terrain follow-up

Player feedback distinguished the small high-detail ground square from distant foliage. The
new independent visual cache extends two-metre terrain from the original 416 m gameplay
window to a default 2,176 m visual window: about 27× its area, with 289 visual tiles and the
same 169 gameplay chunks. F1 Controls exposes a separate 512–2,048 m survey detail radius.
Distant foliage still uses its existing representations; this feature increases terrain detail.

An initial monolithic expanded-ring prototype was discarded. Its headless geometry test took
about 8,011 ms to rebuild a 2,560 m square, which could fall behind a moving camera. The final
implementation reuses 128 m visual tiles and generates only missing/dirty tiles with two
isolated Goose workers. A 128 m tile contains 26,112 vertices including skirts and takes about
22.29 ms in the debug headless geometry test. Those timings describe different workload sizes,
not a like-for-like compiler speed comparison.

Memory/lifetime design: a reusable fixed-record pool is capped at 1,089 visual tiles; each
record explicitly owns one native buffer. Jobs contain values and a filtered inline edit
snapshot; results contain one approximately 1.04 MB flat vertex payload. Eight jobs may be
outstanding, and two result uploads are allowed per frame. Monotonic tickets reject stale
results after eviction or slot reuse. Thread-local scratch dies per tile job; no shared mutable
world, general allocator or new project C/C++ was introduced. Terrain edits invalidate only
touching tiles, including their one-cell lighting halos.

The graphical lifecycle regression retained 81 slots through travel, distant relocation,
suspend/re-enter and edits. It rejected eight stale results, balanced 297 buffer uploads with
297 releases, and regenerated four tiles for one boundary edit. No gameplay chunks were
allocated by that regression. The full gameplay/graphics suite passes.

Measured on the development M5 Max at 1920×1080 with synchronous GPU completion:

| Scenario | Submitted triangles | p50 / p95 / p99 |
|---|---:|---:|
| Low-flight view, camera (465, −854), 45 m above ground, colony load 512 | 6.06 million | 3.40 / 4.85 / 5.20 ms |
| 9,000-frame full-game rapid streaming | 6.06 million at the end | 3.58 / 5.97 / 7.19 ms |

The streaming run generated 884 visual tiles while retaining 289 visual slots and 289 live
visual buffers, with zero pending jobs at the final sample. Gameplay remained at 169 chunk
slots and 636 entities. This is bounded regression evidence, not a long-session OS/GPU memory
measurement or a guarantee at the maximum detail setting and boosted speed.

Ground colour/AO use cached halo samples to avoid a small lighting square. Sparse edits are
preserved in the visual geometry. Near gameplay terrain remains authoritative for interaction
and exposed-soil materials. Distant plant anchors now use procedural elevation with the same
15 cm visual bias, so the new fine surface does not bury the low-detail vegetation.

Evidence: [full tests](artifacts/detail-radius-tests.log),
[static timing](artifacts/detail-radius-static.log),
[streaming timing](artifacts/detail-radius-streaming.log), and
[actual low-flight capture](artifacts/detail-radius.png).

## Distant vegetation and bounded uploads

The next player screenshot exposed a separate limitation: correctly centered detailed chunks
still showed vegetation only within roughly 200 m, leaving the distant terrain bare. The
simulation window was accidentally also the visual draw-distance limit. This was a project
architecture limitation, not evidence of exhausted hardware or a Goose language restriction.

The current renderer adds visual-only vegetation through the isolated horizon worker. Near
and reduced individuals share exact grove/member positions; farther canopies represent grove
footprints. Reduced individuals extend to 896 m, merged canopies to 2,560 m, and coarse grove
silhouettes to 6,144 m. Terrain cells are now 4/8/16/32/64/128 m across the six logical rings.
No extra gameplay entities or simulation chunks are allocated for distant vegetation. The
walking/flight fog defaults are 140/1,600 m and 250/3,500 m respectively, with a smooth mode
transition and an additional distant-canopy haze floor. Near ground stays opaque; only its
plant vertices participate in the near/far decoration dissolve.

The initial whole-ring transfer produced a measured 23.56 ms main-thread LOD update and a
32.09 ms frame in the moving-camera test. Splitting an oversized GPU buffer into offset writes
was considered but not adopted: inspection of the official backend showed allocation zeroes
all unwritten bytes, so initial creation would still perform a whole-buffer transfer. The
implemented pipeline creates independent immutable buffers of at most 90,000 vertices per
batch (3.6 MB). The worker waits for a typed acknowledgment; the main loop polls and uploads
one batch per frame. Sequence offsets and generation tickets validate/cancel transfers.

Native handles live in two independently growing Goose arrays, one per active/staging set.
A complete replacement copies only small handle records, retaining the old set for its fade;
retirement explicitly releases each buffer. Each array is capped at 512 buffers. The final
horizon regression observed at most 163 live buffers and balanced 479 uploads with 479 releases.
This replaces the earlier twelve-buffer layout; it does not imply 163 simulation entities.
Grid-height scratch is scoped to each job, and shared vertices are sampled once per ring.

Goose-specific friction: `copy` does not accept a slice. A small scoped growable array populated
with `append` constructs each inline message payload. No native allocator or project C/C++ was
added. The experiment demonstrates a workable bounded message/collection design, while also
showing that bulk copying and native upload size must be engineered explicitly.

Measured on the development M5 Max, release build, 1920×1080 and synchronous GPU completion:

| Run | Samples | p50 / p95 / p99 | Geometry |
|---|---:|---:|---:|
| Low flight, camera (465, −854), 45 m above ground, colony load 512 | 1,789 | 2.25 / 3.44 / 3.77 ms | 3.55 million submitted triangles |
| Full game, 9,000 frames with automatic 128 m chunk travel | 8,989 | 2.33 / 4.70 / 6.03 ms | 3.48 million at the end |

The static run averaged 417 FPS; the streaming run averaged 365 FPS and generated 1,417 chunks,
retaining 169 chunk slots and 636 active entities. These are measurements of these bounded
scenarios, not a guarantee for arbitrary worlds or hardware. External sampling during the
static run observed a peak RSS of 235,782,144 bytes (235.8 MB); GPU unified-memory accounting
was not measured separately and must not be inferred from RSS.

The isolated moving-horizon test completed three sets over 2,775 frames: last-240 p95/p99
5.20/7.80 ms, maximum main-thread LOD update 1.58 ms. Its maximum whole frame was still 35.56 ms;
this change does not establish that every frame meets 60 FPS. That test excludes the HUD and
simulation and has 4 ms artificial pacing outside measured frame costs.

The full gameplay/graphics suite and the new vegetation regression pass. Art consultation
accepted the low-flight still as resolving the nearby cutoff and empty middle distance. It
flagged far contrast, repeated silhouettes and dither speckle as polish issues; the haze floor
addresses contrast. Motion has automated timing/resource coverage, but no separate visual
30-second normal/boost acceptance recording was produced.

Evidence: [full tests](artifacts/distance-tests.log),
[low-flight timing](artifacts/distance-measured.log),
[streaming timing](artifacts/distance-streaming.log),
[RSS samples and binary identity](artifacts/distance-memory.json), and
[actual low-flight capture](artifacts/distance-low-flight.png).

## Survey camera residency follow-up

Further player testing showed detailed terrain only around the center-screen ray, with coarse
terrain below the camera. The cause was the streaming focus: its projected look-ahead reached
600 m, while detailed terrain extended only 192 m at the default setting and started fading
at 106 m. The previous expansion of distant LOD did not fix this residency error.

Residency and scene visibility now follow the camera's X/Z position projected onto the ground.
Rotating or pitching the camera does not move the loaded area. The camera tile remains inside
the opaque detail region even at the smallest radius. The flight regression covers 640
combinations of altitude, negative/positive coordinates, pitch and yaw. The actual input-driven
flight test also checks that the tile directly under the camera remains resident after its
boosted ascent and travel. The complete graphical/gameplay suite passes. This corrects where the
finite detailed region is placed; it does not make the entire 12–16 km horizon full-detail.
Evidence: [complete tests](artifacts/flight-footprint-tests.log) and
[camera-ground residency input test](artifacts/flight-footprint-input.log).

## Earlier survey-flight LOD correction: 2026-10-26 (`31f95a7`)

Player testing exposed a visible landscape cutoff and two waves of detail changes in flight.
The previous 1.5–2.4 km horizon and 3.2 km camera clip were insufficient from altitude. Ring
meshes also rebuilt synchronously on the main thread. These were implementation problems,
not limitations imposed by Goose.

Survey coverage now starts at 12,288 m and grows with altitude to 16,384 m. Two outer rings
use 128/256 m cells; walking retains its shorter horizon. All ring grids share a world-aligned
256 m center snap. Parent-grid height morphs, stationary depth bias, a 350 ms whole-set dissolve
and detail-chunk arrival/edge dissolves replace abrupt changes. Near/far camera planes preserve
depth precision for survey views. Coarse terrain still omits fine player edits and vegetation.

One Goose worker receives flat jobs and returns a flat, variable-size vertex result. It owns
no GPU handles and shares no mutable world state. Queue capacity is two, with only one job
outstanding. The main loop polls without waiting and uploads one result at a time. Tickets
reject stale settings/seed results. Loading and shutdown explicitly wait; ordinary flight does
not. During a dissolve, old meshes occupy staging storage, preserving a twelve-mesh upper bound.
Building the variable-size result inline avoids an implicit-copy compiler error encountered
when assigning an existing growable vertex array to its inline field.

Measured locally with the pinned compiler on the development M5 Max:

- The full gameplay/graphics suite passed. A 16,384 m test produced 428,268 horizon triangles;
  upload/release counts balanced after shutdown. Parent-edge heights agree, and rendering two
  complementary half-coverage copies is byte-identical to the opaque reference image.
- A separate 1280×800 terrain-only moving-camera test completed three whole sets and 101 fade
  frames over 1,162 frames. The last 240 measured frames had p50/p95/p99 of 1.54/4.37/5.65 ms;
  the maximum measured frame was 16.44 ms and the maximum main-thread LOD update was 4.16 ms.
  Its deliberate 4 ms submission pacing is outside those frame costs. This excludes gameplay,
  vegetation and HUD, and is not a full-game FPS claim.
- The real 1920×1080 scripted flight test with synchronous GPU completion passed: 185 sampled
  frames, p50/p95/p99 3.33/5.47/6.88 ms. Frame-based input scripts now keep their deterministic
  timestep when timing collection is enabled; previously combining those flags invalidated the
  travel assertions by switching the script to wall-clock simulation time.

A subsequent player report described a dark rectangle following the camera. Inspection found
hard shadow-map borders, an airborne shadow focus in survey mode, and the buried fallback
receiving shadows from the detailed terrain sheet above it. The receiver flag now excludes
coarse terrain from that local map, border coverage fades smoothly, and survey shadow focus
is grounded. A rendered regression confirms the fallback matches a shadow-disabled reference
while detailed terrain still shows the occluder's cast shadow. The player's exact frame was
not captured, so correspondence to that reported rectangle still needs player confirmation.

Evidence: [full tests](artifacts/flight-horizon-tests.log),
[sustained terrain motion](artifacts/flight-horizon-sustained.log),
[real flight timing](artifacts/flight-horizon-motion.log),
[shadow receiver regression](artifacts/flight-shadow-boundary.log), and
[800 m terrain capture](artifacts/flight-horizon-800m.png).
These are bounded regression measurements, not proof of zero visible popping at every speed
or stable OS/GPU residency over a long session. Worker CPU, queue calls and GPU uploads are
reported separately in the developer panel for further playtesting.

## Toolchain upgrade: 2026-10-26

The current project pin is upstream commit `a108677d300cb0e8bbb842c35a353abe67a20c6c`,
reported as `v2026.3+git.a108677d300c`, runtime `fba599d313fe`. There is no newer official
release at this point; this is a reproducible source snapshot, not a moving `master` dependency.
`tools/goose-toolchain.env` records the source hash, and bootstrap builds the official native
packages. The historical measurements below retain their original compiler identities.

Adopted features:

- The official formatter passes `--verify` over all 35 source/test files, then `--check` after
  applying formatting. Intentional line breaks remain; the main changes are spaces and trailing
  commas. The standard test runner now checks formatting.
- VS Code workspace settings select the same compiler and format on save. A stdio LSP probe
  verified `documentFormattingProvider`, returned the expected edits, and shut down cleanly.
- `trim_memory()` runs on explicit/coalesced requests after temporary scene/UI scopes return.
  The Goose panel provides a button and honest result/time counters. Large churn, load and
  colony shrink request it automatically; normal frames do not.

Measured on the development Mac, using a separate 64 MiB scratch test:

| Case | RSS after the scratch scope ended | RSS after the request phase |
|---|---:|---:|
| Keep committed pages | 68,730,880 bytes | 68,730,880 bytes |
| Call `trim_memory()` | 68,714,496 bytes | 1,622,016–5,799,936 bytes |

These are externally sampled resident sizes of this small test process, not the game's GPU
footprint. Sampling interval is 70 ms. Live entity/inventory values and pool lengths remain
unchanged; a second 64 MiB allocation and readback pass after release. The API returns a bool,
not a freed-byte count. This closes the earlier missing-API limitation for unused CPU pages;
it does not reduce live reusable-pool capacity or replace native GPU cleanup.

The complete graphical/input suite passes on the new compiler. A deterministic 180-frame
1080p working-colony capture is byte-identical to a v2026.3 build of the previous committed
sources. This is functional/image compatibility evidence, not a comparative performance claim.

Evidence: [memory samples](artifacts/goose-upgrade-memory.json),
[LSP protocol result](artifacts/goose-upgrade-lsp.json),
[formatter verification](artifacts/goose-upgrade-format-verify.log),
[complete test log](artifacts/goose-upgrade-tests-final.log),
[image comparison](artifacts/goose-upgrade-compatibility.json), and
[page-release panel](artifacts/goose-upgrade-memory-panel.png).

## Original benchmark environment

- Development platform: macOS 26.7.1, Apple Silicon arm64.
- Test machine: Apple M5 Max, 18 CPU cores, 40 GPU cores, 128 GB unified memory.
- Compiler: official Goose `v2026.3` Apple Silicon release; `goose version` reports runtime
  `4d3da949e563`.
- Backend: Goose-generated C compiled AOT using the platform compiler; official `gfx` uses
  SDL3's GPU API and Metal on this platform.
- Bootstrap/build: `tools/bootstrap.sh` and `tools/build.sh`; downloaded toolchains and build
  outputs are excluded from source control.
- Source: roughly 8,800 readable production Goose lines including comments and embedded GLSL,
  plus tests. The earlier compact baseline had fewer physical lines; line count is not a measure
  of the language's productivity.
  The repository adds **zero C/C++ source lines**. Generated C and the pre-existing official
  package/runtime implementation are separate from that count.

The official [tutorial](https://aardappel.github.io/goose/docs/tutorial.html),
[reference](https://aardappel.github.io/goose/docs/reference.html),
[library documentation](https://aardappel.github.io/goose/docs/stdlib.html) and
[samples](https://github.com/aardappel/goose/tree/master/samples) informed the design. The
implementation uses the pinned distribution's actual APIs and examples, especially graphics
sample 27, mini-Minecraft sample 30, thread sample 23, serialization sample 25 and reusable
file-tree sample 26. Online master documentation can describe features absent from this release.

## Expanded-world experiment (v2)

The original measurements below remain evidence for the original world and render workload.
They do not describe the expanded world. V2 adds up to 289 detailed chunks, four distant LOD
rings, denser varied vegetation, and an interactive developer panel. Default terrain detail
radius is 6 (169 chunks), with a 1,600 m fog visibility scale and distant terrain around 2 km.
The optional factory fixture contains 32–2,000 real entities, rather than cosmetic stress cubes.

### What can now be observed in the game

F1 opens a five-tab panel with a 240-frame history, frame percentiles, CPU stage intervals,
chunk residency/jobs, navigation work, pool live/free/retained counts, and entity inspection.
Controls change simulation speed, time, fog, vegetation, detail radius, shadows, wireframe,
pathfinding budget and colony load. Churn grows three independent collection pools and reports
time and storage before/after. No panel counter is presented as a GPU utilization percentage.
GPU completion waiting is main-thread elapsed blocking time, not a GPU timestamp query.

The memory estimate counts selected logical payload only. It excludes native graphics memory,
OS residency, allocator metadata and data-stack committed-byte high-water marks. A stale handle
is rejected by generation checks; a global rejection counter is explicitly unavailable rather
than displayed as an invented zero. The inspector's invalid-handle behavior is exercised by
destroying a pinned entity and reusing its slot in the actual-input UI test.

### Real simulation workload

`tests/showcase_benchmark.goose` runs 120 warmup ticks then 600 fixed 1/60 s ticks per load,
in one process with retained pool storage. Release measurements on the M5 Max:

| Requested colony entities | Total active entities | Production machines / robots | Mean tick | p95 | p99 | Outputs |
|---:|---:|---:|---:|---:|---:|---:|
| 32 | 156 | 6 / 5 | 0.0070 ms | 0.003 ms | 0.144 ms | 22 |
| 512 | 636 | 102 / 101 | 0.2272 ms | 0.292 ms | 1.368 ms | 406 |
| 2,000 | 2,124 | 400 / 398 | 0.4106 ms | 0.259 ms | 0.779 ms | 1,600 |

These are elapsed main-thread simulation intervals, excluding rendering, input, streaming,
telemetry refresh and disk. Timers have finite resolution; sub-microsecond zeros mean below
the recorded resolution. A larger workload does not imply a larger percentile for every stage:
robot planning is budgeted, discrete jobs align differently, and outliers matter. The largest
2,000-load tick was **32.907 ms**, in the robot stage. The fixture recorded 7/5/9 failed local
path attempts and peak route-request backlogs of 1/96/395. Two plans per tick limit work and
introduce waiting; these results do not establish responsive navigation for 398 busy robots.

Resource equivalents are conserved across recipes, packets, robot cargo and resize escrow.
Six warmed 32↔2,000 cycles retained the same 2,124 entity slots, 1,696 inventory cells,
645 queue cells, 1,998 edge cells and 1,120 packet slots. This is successful reuse for this
allocation trace, not proof against arbitrary fragmentation. Inputs are finite stores, not
unlimited production grants per tick. The showcase tower is a rendered landmark; the player's
constructed, powered tower remains the progression objective.

### Full rendered workload and an actual optimization

Raw simulation measurements, subsystem distributions and compiler/source/executable identities
are in [the CPU result](artifacts/v2-showcase-benchmark.json) and
[its manifest](artifacts/v2-showcase-source-manifest.json).

The first large graphical runs exposed repeated procedural rail geometry and nearest-wire
endpoint scans in `scene::draw`. A Goose-owned static GPU rail mesh and exact topology cache
remove that repeated work while chevrons, packets, wire power colors and robots remain live.
The cache test matches legacy static vertices exactly, invalidates edits/topology/visibility,
and balances **30 uploads / 30 releases**, with at most two live rail meshes. A cache-only
image comparison differs at one of 2,073,600 pixels due to changed opaque draw ordering; it is
not reported as pixel-identical.

A short paired 1,000-frame M5 Max run measured 123→176 FPS at load 512 and 39→62 at load
2,000. Render CPU p95 changed from 6.18→3.57 ms and 23.31→12.42 ms, respectively.
The [paired result](artifacts/v2-render-cache-comparison.json) records binary identities.
These absolute values must stay separate from earlier and final runs. The dynamic buffer
capacity roughly halved, but static rails now own a separate buffer: total GPU memory was
not shown to halve. This is an engine algorithm/lifetime improvement, not a Goose-vs-C++ test.

Final full-game measurements use 1,920×1,080 offscreen rendering, radius 6, shadows, the full
Overview panel, active simulation and explicit GPU completion every frame:

| Machine | Colony load / total entities | Samples | Mean FPS | Frame p50 / p95 / p99 |
|---|---:|---:|---:|---|
| M1 Max, 32 GB | 512 / 636 | 1,789 | 121.69 | 8.120 / 9.073 / 10.391 ms |
| M1 Max, 32 GB | 2,000 / 2,124 | 1,189 | 44.61 | 21.399 / 24.825 / 46.604 ms |
| M5 Max, 128 GB | 512 / 636 | 2,989 | 102.59 | 7.983 / 14.479 / 18.556 ms |
| M5 Max, 128 GB | 2,000 / 2,124 | 1,989 | 54.18 | 15.117 / 22.123 / 148.094 ms |

Raw [M1 512](artifacts/v2-final-m1-512.json), [M1 2,000](artifacts/v2-final-m1-2000.json),
[M5 512](artifacts/v2-final-m5-512.json) and [M5 2,000](artifacts/v2-final-m5-2000.json)
results include CPU stages and resource counts. These are separate desktop-host runs, not
controlled hardware rankings. The final M5 run was unusually variable, including substantial
GPU-completion waiting; no root cause was established. It would be misleading to hide that
run or infer the M1 is categorically faster. The maximum factory setting does **not** meet a
stable 60 FPS target on either host in these final runs. Presentation/compositor costs and
GPU timestamp-query execution times are not measured.

The final M5 static runs sampled nonzero RSS after two seconds at approximately 109–154 MiB
(512 load) and 172–352 MiB (2,000 load); the raw sample records are authoritative. One zero
sample at process termination is marked unavailable and excluded from the range. These ranges
do not attribute bytes to a particular allocator. The earlier longer static 6,000-frame v2 run
retained a recurring 138–171 MiB RSS range. A final 1,800-frame rapid-flight streaming run
sampled 131–168 MiB over 5.72 wall seconds and ended normally. These finite traces, plus the isolated UI reproducer,
support bounded observed reuse; they do not establish multi-hour memory stability.

### Strategic flight and final input validation

The detached survey controller owns camera state, not the suit. A real 196-frame injected-key
test flew **373.92 m**, gained **264.40 m** altitude, generated 748 chunks in total and retained
at most 169 chunk slots with eight jobs pending. It checks the unchanged player position every
frame, Home overview, G return and the F10 alias. It passed on both development Macs. The
[flight result](artifacts/v2-flight-test.json) is separate from the unchanged 332-frame mining/
building/save/load [input scenario](artifacts/v2-input-test.json).

Fast-flight testing also motivated a lifetime correction: moving the LOD request every frame
could repeatedly cancel partial ring sets. Center changes now coalesce until the current four
rings finish; seed/settings changes still cancel incompatible sets. The regression crosses a
snap cell every frame and verifies completed swaps and bounded handles. Edge fog follows the
active ring center, so an offset survey camera cannot reveal the square landscape boundary.

The final [suite log](artifacts/v2-tests.log) includes seven headless suites, three bounded GPU
tests, renderer smoke, actual flight and normal gameplay input, and launch-option load checks.

### Streaming and integration findings

- The revised world test generated 6,799 chunks with at most 289 slots and eight outstanding
  jobs. Flat-floor, climate, terrain range, negative-coordinate, edit and shared-edge checks pass.
- The horizon test balances **28 GPU uploads with 28 releases**, retains at most eight meshes
  during a staged swap, and has zero live meshes after shutdown. Stationary requests do no rebuild.
- New boundary probes exposed a real 10.44 m detail-to-LOD height underlap, exceeding the old
  8 m detail skirt. Increasing its depth to 32 m fixed the sampled opening without adding vertices.
  The distant-ring skirts remain 64 m. This was a mesh integration defect, not a memory leak.
- A launch integration defect let the UI's default load of 512 overwrite `--load 32` and
  `--load 2000` on the first frame. Benchmark JSON exposed the actual load. Initializing the UI
  load from the parsed option fixed it; graphical load measurements were rerun with assertions
  on the reported load and entity count. The initial mislabeled attempts are not used as results.
- Detailed generation uses two isolated workers. Horizon-ring mesh construction currently runs
  on the main thread, one ring per normal frame, and can produce travel-time spikes. A worker
  pool for those larger jobs is future work; the language's isolated-thread model did not
  automatically parallelize this part of the renderer.

### What this says about Goose

**Measured facts:** entity and variable-slice pools survive repeated independent growth,
destruction and reuse; flat job/result messages support bounded streaming; no project-native
C/C++ or general-purpose native heap was added. Scoped mesh/search scratch does not require
a manually traversed ownership tree. The UI/native resource-retirement workaround is still
necessary in the pinned backend and remains distinct from Goose-pool behavior.

**Engineering judgment:** Goose helps express where storage lives and when temporary work
ends. It solves the collection-ownership problem here through separate reusable slice pools;
it does not design logical entity identity, resource conservation or a fast renderer for us.
Generational handles, explicit reconstruction for saves and cache invalidation remain engine
responsibilities. Relative references and position-independent serialization are useful for
finished data images, but an active pool containing ordinary slices is not automatically a
portable save file. Thread isolation makes races easier to avoid and message payload costs
visible; it also requires explicit job boundaries and can make large mesh transfers expensive.

The strongest practical costs remain a young ecosystem, missing/misleading diagnostics,
version-sensitive native integration, limited live memory instrumentation and the absence of
an official formatter in the pinned release. The project is evidence that Goose can host this
engine architecture. It is not evidence that Goose itself makes frame rates higher than C++,
Rust, or another implementation of the same algorithms.

## Original-workload recorded deterministic results

The following values come from the post-optimization debug run in
`artifacts/optimization-tests.log`. They are observations of these fixtures, not throughput
guarantees. Elapsed times include only each program's timed test region and exclude compilation
and process launch. The suite uses `--debug`, including source-level runtime checks; release
graphical measurements are a separate workload.

| Test | Workload and assertions | Observed result |
|---|---|---|
| `entities_test.goose` | 50 rounds of 1,000 entities; 12 independently growing inventory kinds per entity; varying queues; three outgoing links; interleaved deletion; stale handles | Pass; 50,000 spawns in 380.873 ms; pool plateaus: 1,000 entity slots, 12,064 inventory cells, 5,339 queue cells, 3,002 edge cells |
| `world_test.goose` | Repeated teleports, negative coordinates, shared-border edits, abandoned jobs, maximum-radius streaming, restart | Pass; 2,745 generated chunks, 2,639 evictions; 81-slot high-water; 14 persistent edit vertices; eight jobs maximum; 117.062 ms total |
| World worker timings | Same world fixture | 203.148 ms summed generation CPU; 0.770 ms main queue-call time; 107.686 ms blocking drain time |
| `gameplay_test.goose` | Bootstrap mining, manual recipes, real construction costs, powered automatic production, robot routing, tower completion; independent brownout, rail-free robot delivery and packet-conservation checks | Pass; 137 crafted outputs; 202.208 simulated seconds; 314.693 ms elapsed |
| Navigation in gameplay fixture | Bounded local A* requests made during the progression scenario | 140 attempts, zero failed; 271.327 ms summed path CPU |
| `persistence_test.goose` | Full machine/robot/graph/queue/packet/edit/depletion state; churn allocator to 1,000 slots; corrupt saves; 50 reloads | Pass; 932-byte fixture; original handles and all entity/collection/packet pool high-water marks unchanged through repeated loads |

Generation CPU is summed across two workers, so it may exceed wall time. `queue_call_ms` times
main-thread `qput` and nonblocking result polls; it includes dispatch/runtime overhead and copying.
It is **not** an isolated `memcpy` benchmark, and it excludes the worker's send-call timer.
`blocking_drain_ms` includes waiting and is reported separately. Zero path failures describes
the corrected deterministic gameplay fixture, not all possible player-built obstacle layouts.

### Actual-input integration

`artifacts/input-test.json` records a passing 332-frame test through the game's injected
keyboard/mouse input path: walk, mine three units, open the construction menu, place a machine,
save, move, load, spawn/destroy 1,000 objects, stream, and load again. It generated 172 chunks
and reached 1,125 entity slots. This complements direct simulation tests; it exercises the
player-facing controls and persistence wiring.

### Final game frame benchmark

`artifacts/benchmark.json` measures the actual game loop, complete scene, HUD and active
simulation at **1,920×1,080**, default radius 3 (49 chunks), shadows enabled and 133 entities in
the demo colony. It records 2,989 samples from 3,000 rendered frames after initial warmup.
`synchronous_gpu_completion: true` confirms that benchmark mode waits for GPU completion every
frame; normal play retains asynchronous pipelining.

| Metric | Recorded value |
|---|---:|
| FPS from mean frame interval | 1,526.34 |
| Frame p50 / p95 / p99 | 0.642 / 0.734 / 0.930 ms |
| Simulation CPU p95 | 0.001 ms |
| Scene and HUD render CPU p95 | 0.340 ms |
| Mesh synchronization CPU p95 | 0.001 ms |

The GPU wait is included in the next frame interval and excluded from the render CPU timer.
These are full rendered offscreen frames, not GPU timestamp-query measurements, and they omit
desktop composition/presentation. The colony remains in place, so this is not a streaming
travel benchmark or the much larger production fixture below. The full process runs for 2.61
seconds, including startup and screenshot/readback outside the frame samples.

After the resource-retirement workaround below, this process records **96,518,144 bytes
maximum resident size** and **515,589,512 bytes peak memory footprint**. The preserved
`benchmark-before-fix.json`/`.log` contain the failed approach: 385.83 frames/s, **1,999,290,368
bytes maximum resident size** and **106,185,789,712 bytes peak memory footprint** over the same
3,000-frame workload. Those are distinct operating-system metrics; the very large pre-fix
footprint is not presented as logical Goose pool storage.

### Isolating and bounding full-HUD memory

The discrepancy between the full HUD and no-HUD stress fixture prompted an independent
UI-only reproducer, `tests/ui_memory_probe.goose`. Its artifact,
`artifacts/ui-memory-probe-results.json`, preserves nine probe modes, commands and caveats:

| Probe | Maximum resident bytes | Peak-footprint bytes |
|---|---:|---:|
| Keep official UI GPU buffers, 1,000 GPU-complete frames | 246,890,496 | 17,508,435,000 |
| Keep official UI GPU buffers, 3,000 GPU-complete frames | 633,044,992 | 51,876,480,320 |
| Retire only UI index buffer, 1,000 GPU-complete frames | 71,958,528 | 393,429,904 |
| Retire index buffer, 3,000 pipelined frames | 72,810,496 | 405,095,336 |
| Keep UI buffers, create/release unrelated 16-byte sentinel, 1,000 frames | 71,729,152 | 376,161,216 |

**Measured:** UI font-texture count and GPU buffer capacities remain fixed even in the growing
baseline. Generated C for `ui::render` restores its three temporary Goose stack tops on return;
unchanged-scale font baking exits immediately and native UI commands/conversion buffers clear
per frame. Retiring either UI vertex or index storage also removes the observed growth. Merely
using exact-sized uploads or disabling graphics validation does not. The pipelined probe
sleeps one millisecond per frame, so it is a memory check, not a throughput comparison with the
unpaced synchronous probes.

**Inference, not a proven internal defect:** releasing an unrelated tiny buffer works while
retaining both UI buffers. This points toward native SDL/Metal GPU cleanup timing triggered by
resource retirement, rather than proving that a UI index buffer, Goose stack, font atlas or
general heap allocator is intrinsically leaking. The native implementation was not patched or
fully diagnosed at the driver level.

**Shipping workaround:** `hud::present` renders both UI contexts, releases
`ui::renderer.index_buffer`, and resets its handle/capacity to zero. The next official UI render
call recreates that small buffer; SDL defers destruction until pending draws finish. This costs
one small GPU buffer allocation/retirement per frame, uses no custom allocator or C code, and
depends on the pinned v2026.3 module's renderer fields. It must be reevaluated when upgrading.

The corrected actual game then ran **30,000 full-HUD pipelined frames** at 1,920×1,080 in
**9.66 seconds**. `artifacts/full-app-memory.json` records 89 external RSS samples and source/
executable hashes. After warmup, sampled RSS is **80.4–95.2 MiB**, starting at 81.1 MiB and ending
at 95.2 MiB during the final screenshot/readback; the preceding two samples are 81.5 and
81.3 MiB. Maximum resident size is **101,646,336 bytes**; the distinct peak-footprint metric is
**900,711,624 bytes**. This is much better than the unbounded-looking short baseline and shows
bounded observations under actual pipelined HUD rendering. It remains a finite static-colony
run, not a proof of a perfectly flat footprint or a multi-hour session.

### Production simulation at scale

`tests/network_stress.goose` uses 200 production cells: **2,155 active entities, 2,002
structures, 400 production machines and 32 robots**. It measures 600 ticks after 60 warmup ticks,
with finite starting resources and no rendering. Resource accounting includes committed
recipes, packets and robot cargo. These are functioning production systems, rather than
decorative stress entities.

| Configuration and artifact | Mean tick | p95 | p99 | Maximum |
|---|---:|---:|---:|---:|
| Before optimization, debug (`network-stress-before.json`) | 78.018 ms | 127.010 ms | 193.628 ms | 314.638 ms |
| After optimization, debug (`network-stress-debug.json`) | 6.525 ms | 36.615 ms | 74.189 ms | 146.301 ms |
| After optimization, release (`network-stress.json`) | 0.613 ms | 4.425 ms | 9.510 ms | 18.861 ms |

The same debug configuration improved mean tick time **11.96×**. The additional debug-to-release
difference is a separate build-configuration effect; the combined ratio is not a source-only
optimization result. Before optimization, pathfinding consumed 26,601 ms of roughly 46,811 ms
summed tick CPU. Rasterizing obstacles once per search and caching exact power topology removed
most repeated work. The measured static production fixture required zero topology rebuilds
after warmup; separate assertions exercise invalidation.

Both corrected builds produce **1,600 outputs**, reach **1,181 live packets**, and complete
**1,088 A* routes with zero failures**. Finite resource equivalents remain exactly 20,836
Ferrite, 13,206 Glacite and 24 regolith units. An additional 10,000 creations/destructions with
real inventories and graph edges take 33.787 ms in release; pool high-water marks remain 3,155
entity slots, 2,386 inventory cells and 2,018 edge cells. Maximum resident size is 2,654,208 bytes
for the release test and 3,145,728 bytes for debug; the distinct peak-footprint counters are
2,409,264 and 2,474,800 bytes. JSON artifacts record build flags, source hashes and executable
hashes.

**Limit:** this is CPU simulation timing. Release p99 is below 16.67 ms, but its maximum exceeds
that budget, and debug p95 does not meet it. These results do not establish 60 rendered FPS for
a colony with 2,002 structures.

### GPU streaming, entity churn and memory trace

`artifacts/gpu-stress-results.json` records a **71.17-second**, 1,920×1,080 offscreen Metal run
with shadows. It renders 50,000 frames over 2,500 rounds, creates/destroys 2.5 million entities,
and generates 62,500 chunks with 62,475 evictions. Peak live entities are 1,124; peak submitted
geometry is 76,225 triangles. Every measured frame explicitly waits for GPU completion.

After ten warmup rounds, the 49,800 frame samples average **1.036 ms**, with **p95 1.703 ms**
and **p99 2.565 ms** (965.6 frames/s from the mean). CPU drawing averages 0.433 ms. Streaming,
mesh uploads and entity churn occur **between** the timed frames; their cost appears in the
71.17-second total and round samples, rather than these frame percentiles. No desktop
compositor/window presentation or full player HUD is included in this fixture.

The entity/inventory/queue/edge high-water marks are unchanged from warmup to the end:
**1,124 / 4,000 / 3,999 / 1,000**. Chunk storage remains 25 slots. Dynamic GPU capacity remains
3,621,120 bytes. The external `ps` trace has 659 samples at approximately 0.1-second intervals:
after warmup, observed RSS ranges from **72.5 to 123.4 MiB**. The process maximum-resident counter
is **129,712,128 bytes**; the separate peak-memory-footprint counter is **1,127,974,040 bytes**
(about 1.05 GiB). They are different operating-system metrics and must not be interchanged.

The first-fifth RSS maximum is 105.8 MiB and the last-fifth maximum is 123.4 MiB, so the trace
does not prove a perfectly flat resident footprint. It shows a bounded observed range and
constant Goose pool/GPU capacity counters during this finite run. Native graphics caches and
the final screenshot/readback contribute memory beyond logical game storage. The artifact
retains full samples, source hashes, measurement caveats and an earlier unsuccessful run.
This run precedes final cosmetic lighting/planet adjustments; its allocation policy is the
same, but it is not represented as a measurement of an identical final shader image.

## 1. Entity lifecycle and stable references

**Implementation:** `ecs::entities` is a fixed-record `reusable` pool. Arbitrary destruction
returns slots to Goose's freelist. Cross-object identity is an explicit `(slot, u32 generation)`
handle. Every dereference validates range, liveness and generation. Generation wrap is rejected.

**Measured:** an old handle cannot add resources to or destroy the entity that replaced it in
the same slot. The entity test performs 50,000 spawns, individual graph-aware destruction and
bulk clearing. The entity slot high-water remains exactly 1,000 after the first round.

**Tradeoff:** Goose references are memory safe after pool reuse but do not themselves prove
logical object identity. Generational validation is still an application responsibility. The
pool retains its maximum allocated slot storage; destruction enables reuse rather than reducing
its length or promising immediate resident-memory release.

## 2. Independently growing collections

**Implementation:** each entity owns inventory, queue and link slices backed by three
`reusable[]` slice pools. Resizing returns the slice's current location. Systems replace the
owner's slice after every resize and retain handles or values rather than element references
across a possible move. Machines and robots use independent queue runs simultaneously.

**Measured:** 1,000 entities grow inventories in interleaved passes, while queue lengths and
graph adjacency grow independently. Every element is checked. Inventory/queue/edge pool lengths
plateau over 50 complete lifecycle rounds. Their high-water lengths exceed live element counts
because interleaved growth leaves reusable gaps before coalescing.

**Judgment:** this is a real solution to dynamic ownership in Goose, and it was much more
practical than embedding a separately resizable tail in every entity. It does require explicit
run ownership and resize discipline; it is less direct than writing nested conventional vectors.

## 3. World streaming and reclamation

**Implementation:** each 32-metre chunk stores 289 heights. Reusable chunk slots are bounded
at 81; quality selects 25, 49 or 81 resident chunks. Flat generation jobs carry the seed and an
allocation ticket. Eviction returns a slot; a late result is discarded when its ticket no
longer matches. Only ready chunks may produce render meshes.

**Measured:** the world test generates 2,745 chunks, including repeated visits and abandoned
outstanding jobs. Storage tops out at 81 slots. Edits match after eviction/revisit and worker
restart. Negative coordinates and vertices shared by adjacent chunks are checked explicitly.

**GPU ownership:** the scene releases cached GPU buffers on eviction or revision change.
Terrain/vegetation mesh arrays are local scratch. Dynamic GPU storage grows geometrically,
releases its previous buffer on growth, and updates the current buffer thereafter. Shutdown
releases the remaining buffers, shaders/pipelines, textures and sampler.

**Limitations:** terrain is a heightfield with surface digging/raising. Caves, overhangs, fluid
simulation and fully volumetric terrain were deliberately omitted. Unique terrain edits and
resource depletion records remain persistent and therefore grow with genuinely new player
changes, rather than with chunk traversal alone. Their current lookup is linear.

## 4. Graph structures

**Implementation:** directed logistics edges are generational handles stored in per-owner
slice runs. Entity destruction removes incoming links and clears targets. Resource packets live
in a separate reusable pool. Power connectivity is inferred from structures within 14 metres
and cached by exact membership stamps, with per-tick allocation in stable order; transport links
are explicit and limited to 24 metres.

Robot routing uses a 41×41 grid at two-metre spacing, a 900-expansion cap and up to two searches
per tick. A path is stored in the robot's independently growing queue. Scratch search arrays
die at the end of the call. Buildings and steep terrain constrain movement.

**Measured:** graph deletion leaves only valid handles; packets conserve cargo when a source
or destination disappears; deterministic component brownouts work; real production supplies the
communications objective. All 140 recorded A* requests succeed in the corrected fixture, and a
separate fixture proves robot delivery with no logistics rail.

**Scaling limit:** unchanged power topology now requires O(N) membership validation and O(B)
allocation work; a changed topology still triggers an O(B²) component rebuild. Exact stamps
include slot, generation, kind and X/Z position, so raw ECS moves/replacements are detected as
well as normal construction. Loading clears the cache. Time-of-day output is recomputed every
tick without requiring a rebuild. Tests cover added, removed, moved, retyped and reused-slot
buildings, explicit restoration invalidation and daylight changes.

Search setup rasterizes footprints in O(N + covered grid cells), rather than scanning all
buildings for each grid point. Tests compare its output against the original exact obstacle
predicate. Incoming-edge cleanup and movement collision checks remain linear, and A* scans its
open grid instead of using a heap. The actual production benchmark above addresses meaningful
simulation at the measured scale; larger factories still warrant spatial indexing and
incremental graph work.

There is no general scene-graph hierarchy: machine meshes are procedural assemblies built into
temporary triangle streams. This keeps the experiment focused on persistent simulation graphs.

## 5. Temporary memory

**Implementation:** terrain meshes, dynamic scene batches, path reconstruction, graph walks,
serialization snapshots and sound sample construction use local arrays or fixed arrays.
Compiler-managed data-stack scope exit reclaims scratch logically. There is no frame-arena
allocator written in native code.

Particles use a fixed 256-slot cosmetic ring. Frame timing samples are collected only when
benchmarking and capped at 16,384 samples. Ordinary play does not append an unbounded timing
history. Persistent pools and sparse modifications have explicitly longer ownership.

**Observability limit:** the compiler's `--stacks` and optional `GS_STACK_STATS` reveal data
stack/region counts and reservations. They do not supply per-frame committed-byte high-water
values to this game's HUD. The HUD reports live/storage counts, and process memory must be
measured externally. A 2 GB address-space reservation per stack is not 2 GB of committed RAM.
The full application build log records six data stacks plus 22 global stacks for the main
program (28 regions), and one data-stack region per terrain worker. Standalone tests can have
different counts because compilation specializes their reachable programs.

## 6. Persistence and relative references

**Implementation:** runtime entity slices are not a serializable position-independent image.
The save code constructs flat `SavedEntity` records with finished inline arrays, plus flat
packet, edit, depletion and game-header data. It uses Goose's `to_bytes`/`from_bytes`, an explicit
schema version and FNV-1a checksum. The operating-system API writes the replacement atomically.

Load verifies framing and data layout, checksum, finite/ranged coordinates, resource/count
bounds, unique slots and valid generational graph references before mutating the current game.
It restores original slots independently of freelist order, reconstructs collection runs and
keeps the global generation counter monotonic. Orphaned in-flight cargo remains present and is
delivered/refunded by normal transport logic. Generated deposits regenerate from seed and
persisted depletion.

**Measured:** the 932-byte fixture preserves machine progress, inventories, production queue,
signed robot waypoints, robot state/target/cargo, graph links, packets, edits and game progress.
Fifty reloads after 1,000-slot churn leave all pool high-water lengths unchanged. Truncation,
checksum damage and correctly checksummed invalid coordinates/handles reject without changing
the running state. Orphan packets demonstrably deliver or refund after loading.

**Judgment:** flat snapshots fit Goose well, but the runtime graph could not simply be dumped
as bytes. Goose's self-relative links can support an immutable position-independent image; this
engine instead uses handles so destroyed/reused objects can be recognized. No custom relative
pointer implementation or native serialization fallback was necessary. Schema version 1 has
no migration, and the checksum provides corruption detection rather than authenticity.

## 7. Thread isolation and communication

**Implementation:** two actual Goose `thread_fn` workers consume typed flat jobs. Their input
contains no slices, references or main-thread mutable world state. The seed travels explicitly
in each job. Results contain 289 `f32` heights, coordinates, ticket and generation CPU duration.
No shared mutable arrays, atomics or locks are assumed by the game code.

The job's declared fields total 37 bytes and the result's fields total 1,196 bytes; queue
metadata/runtime overhead is additional. At most eight jobs are outstanding, and both typed
queues are bounded. Workers stop with explicit messages and are joined after results drain.

**Measured:** threaded heights equal serial generation at every sampled vertex in the test.
Queue-call time is small relative to the generation/wait totals in the recorded fixture. This
does not prove a parallel speedup: there is no controlled serial-versus-parallel end-to-end
benchmark for the whole streaming pipeline, and small height jobs may cost less than dispatch.

**Judgment:** isolation was not a blocking architecture limitation here. It naturally matched
independent chunk jobs. Meshing and pathfinding remain on the main program; parallelizing their
larger inputs/results would require another explicit copy/bandwidth experiment.

## 8. Fragmentation, reuse and long-running behavior

**Measured:** entity, inventory, queue and adjacency storage plateau under repeated interleaved
churn. Chunk storage plateaus under repeated teleports. Repeated persistence transactions reuse
all relevant runtime pools. The longer GPU run repeats 2.5 million entity lifecycles and 62,500
chunk generations while all recorded pool high-water marks remain fixed after warmup. The
separate production fixture also plateaus under storage-bearing, graph-linked churn. These
directly exercise reusable slots and coalescing slice runs, rather than merely creating
append-only data and exiting.

**What this establishes:** the tested workloads do not accumulate unusable storage on each
repeat. Pool high-water metadata makes retention visible in the debug overlay and test output.

**What it does not establish:** these finite tests are not a proof against every fragmentation
pattern, a multi-hour RSS/GPU leak, or growth caused by indefinitely adding distinct buildings
and modifications. Reusable pools intentionally retain their peak backing storage. The observed
RSS range and substantially higher native footprint counter also require more attribution than
pool lengths alone provide. A stronger production study needs mixed-size adversarial traces,
longer measured runs and GPU allocation instrumentation.

## Actual implementation problems and unsuccessful assumptions

1. **Local fixed arrays require initialization.** Initial A* source declared fixed `bool`
   arrays and read entries before initializing them. Pinned documentation requires full local
   initialization, but v2026.3 accepted the source and generated uninitialized C arrays. All 97
   path attempts failed in the initial run. Explicit `[false; COUNT]` initializers produced
   successful paths and a passing progression test. This was an application initialization
   error plus a missing definite-assignment diagnostic, not a failure to honor a promised zero
   default. The corrected source initializes every read search flag.
2. **Variable-size copies are explicit.** Constructing the save envelope with an existing
   payload builder failed compilation with a diagnostic requiring `copy(payload)` or a
   reference. The implementation uses an explicit snapshot copy. This makes the extra memory
   traffic visible, but means saving temporarily holds more than one byte image.
3. **Float precision conversions need typed intermediates.** Expressions such as
   `sin(j * 2.1)` selected `f64` and could not silently become `f32` mesh coordinates. The
   diagnostic required an explicit rounding cast. Typed `f32` intermediates/casts fixed the
   scene/camera math. This is a language rule, not a compiler bug.
4. **Online documentation is ahead of the pinned release.** Master documentation described
   `trim_memory`, while v2026.3's `os` module lacks it and the compiler reported an unknown
   function. A `goose format` invocation was also unsupported; the release help has no formatter
   command. The project does not call the missing API or invent a native equivalent.
5. **Zero-stack worker diagnostics are misleading.** The standalone world test reported a
   worker using zero data-stack regions and then printed a zero worker cap with a division by
   zero in the diagnostic text. Two workers actually executed successfully. Whole-application
   specialization can report a different worker stack count; the build's actual `--stacks`
   output is authoritative. The game uses an explicit bounded pair rather than relying on that
   diagnostic to choose a count.
6. **Raw runtime pool serialization is the wrong representation.** Entity records contain
   ordinary slices and runtime freelists are not the save schema. The implemented flat snapshot
   and reconstruction replaced that initial tempting approach before it became a native-code
   workaround.
7. **A robot policy bug caused repeated route failures.** After search flags were initialized,
   robots could still haul resources back out of the home lander and then enter its footprint,
   trapping subsequent routes. Consumer/home priorities and a three-metre lander arrival
   clearance fixed the policy. The final fixture completes 140 plans with zero failures and
   includes rail-free cargo delivery. This was game logic, not a Goose memory limitation. The
   planner still has an explicit local radius and expansion cap, so arbitrary layouts can fail
   and retry after cooldown.
8. **Generic links were initially rendered as transport rails.** The first GPU stress fixture
   exposed scene code drawing AI/stress ownership links as conveyors. It reached 922,497
   triangles, a 207,608,640-byte dynamic buffer, 22.558 ms mean frame time and 2,287,239,168 bytes
   maximum resident size. Restricting conveyor rendering to building-to-building links removed
   the unintended geometry. The corrected long run uses a 3,621,120-byte dynamic buffer. Both
   runs remain recorded in the artifact; this was a scene-interpretation bug, not evidence that
   Goose's reusable pool leaked.
9. **Uncached work missed the simulation target.** The first real 2,002-structure fixture
   averaged 78.018 ms per debug tick. It exposed repeated all-building obstacle scans and power
   reconstruction. Exact obstacle rasterization and invalidatable topology membership caching
   improved same-build mean time to 6.525 ms without changing output/conservation/route counts.
   Release measurements are reported separately rather than credited to those source changes.
10. **Official UI/native memory growth needed an explicit workaround.** A full-HUD benchmark
    reached roughly 2 GB RSS and a much larger footprint counter in 3,000 frames, despite fixed
    game pools. A UI-only reproducer isolated the resource-retirement interaction described
    above. Exact-sized uploads and disabling validation failed; retiring one small GPU buffer
    per frame succeeded in both synchronous and pipelined tests. The project retains all
    measurements and the version-specific workaround. The native cleanup explanation remains
    an inference rather than a claimed driver-level root cause.

## Native integration and production assessment

The game reused the official graphics, UI and audio facilities instead of writing new bindings.
The boundary is explicit: Goose owns `Vertex` arrays, game state and lifetime policy; official
native calls create/update/release GPU objects, present frames, read input, render UI and play
PCM samples. Basic collision is implemented directly in Goose because the world is a
heightfield with simple building footprints. No extra physics library was necessary.

**Subjective conclusion:** Goose's memory model can sustain an evolving, playable small colony
when object identity and allocation ownership are designed explicitly. Reusable slice pools
solve the most important dynamic-collection obstacle without a hidden general-purpose heap.
Scope reclamation and flat messages are useful engine primitives. The costs are deliberate
layout choices, explicit copies, snapshot conversion, a version-specific graphics cleanup
workaround and weaker tooling/diagnostics than a mature game-engine language ecosystem. This
experiment supports further engine work in Goose;
it does not yet justify selecting it for a production-scale open-world factory without more
profiling, compiler hardening and navigation/spatial-index work.
