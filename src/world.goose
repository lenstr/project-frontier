// Deterministic two-metre heightfield chunks. GPU resources belong to render.
// Jobs contain values, never views or references into the main program.
namespace world;
import std;
import vec;
import math;
import os;
import .types;

let CHUNK_SIZE = 32;
let GRID = 17;
let CELLS = 289;
let MAX_RADIUS = 8;
let MAX_CHUNKS = 289;
let MAX_JOBS = 8;

struct Edit { gx: i64, gz: i64, delta: f32 }

struct Chunk {
    cx: i64, cz: i64, active: bool, ready: bool,
    revision: i64, ticket: i64, heights: f32[289], }

struct Job { cx: i64, cz: i64, slot: i64, ticket: i64, seed: u32, stop: bool }

struct Result {
    cx: i64, cz: i64, slot: i64, ticket: i64,
    heights: f32[289], generate_ns: i64, }
reusable var chunks: Chunk[>..] = [];
var edits: Edit[>..<] = [];
var seed: u32 = 73129;
var pending: i64 = 0;
var generated: i64 = 0;
var evicted: i64 = 0;
var loaded: i64 = 0;
var generation_ms: f64 = 0.0;
var generation_total_ms: f64 = 0.0;
// Time inside qput/qpoll/qget calls, including the actual value copies.
var transfer_ms: f64 = 0.0;
var max_pending: i64 = 0;
var next_revision: i64 = 1;
var worker_ids: i64[2];
var running = false;

fn hash(x: i64, z: i64, s: u32) -> u32 {
    var h = (x as! u32) * 374761393 + (z as! u32) * 668265263 + s * 2246822519;
    h = (h ^ (h >> 13)) * 1274126177;
    h ^ (h >> 16)
}

fn random01(x: i64, z: i64, s: u32) -> f32 {
    (hash(x, z, s) & 65535) / 65535.0
}

fn noise(x: f32, z: f32, s: u32) -> f32 {
    let ix = floor(x) as i64;
    let iz = floor(z) as i64;
    let fx = x - ix;
    let fz = z - iz;
    let u = fx * fx * (3.0 - 2.0 * fx);
    let v = fz * fz * (3.0 - 2.0 * fz);
    let a = random01(ix, iz, s) * (1.0 - u) + random01(ix + 1, iz, s) * u;
    let b = random01(ix, iz + 1, s) * (1.0 - u) + random01(ix + 1, iz + 1, s) * u;
    a * (1.0 - v) + b * v
}

fn gaussian(x: f32, z: f32, cx: f32, cz: f32, radius: f32) -> f32 {
    let dx = x - cx;
    let dz = z - cz;
    exp(-(dx * dx + dz * dz) / (radius * radius))
}

fn climate_at(x: f32, z: f32, s: u32) -> f32 {
    let original = noise(x / 160.0 + 1.5, z / 160.0 - 2.0, s + 101);
    let amber = gaussian(x, z, -121.0, -207.0, 130.0);
    let amber_core = gaussian(x, z, -121.0, -207.0, 45.0);
    let fungal = gaussian(x, z, -226.0, -81.0, 120.0);
    let district = gaussian(x, z, -123.0, -102.0, 110.0);
    // A compact warm core keeps the nearby amber patch distinct without
    // broadening its outer climate falloff or changing the meadow at spawn.
    let shaped = original - 0.32 * amber - 0.55 * amber_core + 0.32 * fungal;
    shaped * (1.0 - district) + 0.5 * district
}

fn climate(x: f32, z: f32) -> f32 {
    climate_at(x, z, seed)
}

// Components are meadow, amber and fungal. The two blend bands cannot overlap.
fn climate_weights(value: f32) -> float3 {
    let amber = clamp((0.40 - value) * 6.0, 0.0, 1.0);
    let fungal = clamp((value - 0.58) * 6.0, 0.0, 1.0);
    float3 { 1.0 - amber - fungal, amber, fungal }
}

fn grove_mask(x: f32, z: f32) -> f32 {
    noise(x / 38.0, z / 38.0, seed + 1547)
}

fn district_distance(x: f32, z: f32) -> f32 {
    let dx = x + 123.0;
    let dz = z + 102.0;
    let u = dx * 0.64 - dz * 0.77;
    let v = -dx * 0.77 - dz * 0.64;
    let outside_u = max(abs(u) - 88.0, 0.0);
    let outside_v = max(abs(v) - 80.0, 0.0);
    sqrt(outside_u * outside_u + outside_v * outside_v)
}

fn natural_weight(x: f32, z: f32) -> f32 {
    let landing = smooth(13.0, 37.0, sqrt(x * x + z * z));
    let district = smooth(0.0, 22.0, district_distance(x, z));
    // The landing apron joins the district instead of leaving a ridge across
    // the only direct walking route and the initial view of its working spine.
    let u = 0.64 * x - 0.77 * z;
    let v = -0.77 * x - 0.64 * z;
    let across = max(abs(u) - 20.0, 0.0);
    let along = max(max(-v, v - 90.0), 0.0);
    let approach = smooth(0.0, 16.0, sqrt(across * across + along * along));
    landing * district * approach
}

struct Landmark {
    kind: i64,
    x: f32,
    z: f32,
    radius: f32,
    height: f32,
}

fn landmark_at(x: f32, z: f32, s: u32) -> Landmark {
    let cx = floor(x / 384.0) as i64;
    let cz = floor(z / 384.0) as i64;
    let position = hash(cx, cz, s + 601);
    let shape = hash(cx, cz, s + 619) % 10;
    let center_x: f32 = cx * 384.0 + 96.0 + (position & 65535) / 65535.0 * 192.0;
    let center_z: f32 = cz * 384.0 + 96.0 + ((position >> 16) & 65535) / 65535.0 * 192.0;
    let size = random01(cx, cz, s + 607);
    if shape < 3 {
        return Landmark {
            kind: 1,
            x: center_x,
            z: center_z,
            radius: 22.0 + size * 10.0,
            height: 45.0 + random01(cx, cz, s + 613) * 30.0,
        };
    }
    if shape < 6 {
        return Landmark {
            kind: 2,
            x: center_x,
            z: center_z,
            radius: 35.0 + size * 25.0,
            height: 7.0,
        };
    }
    Landmark { kind: 0, x: center_x, z: center_z, radius: 0.0, height: 0.0 }
}

fn landmark(x: f32, z: f32) -> Landmark {
    landmark_at(x, z, seed)
}

fn in_crater(x: f32, z: f32) -> bool {
    let feature = landmark(x, z);
    if feature.kind != 2 {
        return false;
    }
    let dx = x - feature.x;
    let dz = z - feature.z;
    dx * dx + dz * dz < feature.radius * feature.radius * 0.64
}

fn terraced(value: f32, interval: f32) -> f32 {
    let q = value / interval;
    let whole = floor(q);
    interval * (whole + smooth(0.42, 0.58, q - whole))
}

fn spire_profile(distance: f32, radius: f32, height: f32) -> f32 {
    let t = max(1.0 - distance / radius, 0.0);
    let exponent: f32 = 1.6;
    let profile = height * pow(t, exponent);
    min(height, terraced(profile, 6.0))
}

fn landmark_height(x: f32, z: f32, s: u32) -> f32 {
    let feature = landmark_at(x, z, s);
    let dx = x - feature.x;
    let dz = z - feature.z;
    let distance = sqrt(dx * dx + dz * dz);
    if feature.kind == 1 {
        return spire_profile(distance, feature.radius, feature.height);
    }
    if feature.kind == 2 {
        let t = distance / feature.radius;
        let rim = (t - 1.0) / 0.18;
        return 7.0 * exp(-rim * rim) - 9.0 * (1.0 - smooth(0.0, 0.9, t));
    }
    0.0
}

fn forced_spire(x: f32, z: f32) -> f32 {
    let dx = x + 370.0;
    let dz = z + 307.0;
    spire_profile(sqrt(dx * dx + dz * dz), 30.0, 70.0)
}

fn salt_strength_at(x: f32, z: f32, s: u32) -> f32 {
    let river = abs(noise(x / 300.0, z / 300.0, s + 401) - 0.5);
    smooth(0.045, 0.012, river)
}

fn ridge_amplitude(x: f32, z: f32) -> f32 {
    // Keep the foreground below the fungal canopy sightline; distant ridges
    // retain their full silhouette after the 120-to-180 metre transition.
    let distance = sqrt(x * x + z * z);
    10.0 + 36.0 * smooth(120.0, 180.0, distance)
}

fn ridge_height(x: f32, z: f32, s: u32) -> f32 {
    let ridge = 1.0 - abs(2.0 * noise(x / 210.0, z / 210.0, s + 71) - 1.0);
    let squared = ridge * ridge;
    ridge_amplitude(x, z) * squared * squared
}

fn generated_height(x: f32, z: f32, s: u32) -> f32 {
    // ART_DIRECTION.md section 11.2. Workers receive only the seed and coords;
    // every term is identical to main-thread collision and distant LOD sampling.
    let flat_weight = natural_weight(x, z);
    if flat_weight == 0.0 {
        return 1.8;
    }
    let weights = climate_weights(climate_at(x, z, s));
    let broad = (noise(x / 120.0, z / 120.0, s) - 0.5) * 27.0;
    let detail = (noise(x / 29.0, z / 29.0, s + 13) - 0.5) * 7.0;
    let micro = (noise(x / 9.0, z / 9.0, s + 47) - 0.5) * 1.1;
    let continental = (noise(x / 700.0, z / 700.0, s + 5) - 0.5) * 36.0;
    let meadow = continental + broad + detail + micro + ridge_height(x, z, s);
    let mesa = smooth(0.52, 0.60, noise(x / 85.0, z / 85.0, s + 211));
    let amber = terraced(continental + 0.6 * broad + 0.5 * detail + 24.0 * mesa, 8.0)
        + 0.4 * micro;
    let hummocks = (noise(x / 14.0, z / 14.0, s + 303) - 0.5) * 3.0;
    let bowls = smooth(0.62, 0.78, noise(x / 48.0, z / 48.0, s + 313));
    let fungal = 0.7 * continental + 0.5 * broad - 6.0 + hummocks - 7.0 * bowls;
    var h = weights.x * meadow + weights.y * amber + weights.z * fungal;
    let river = abs(noise(x / 300.0, z / 300.0, s + 401) - 0.5);
    h -= 4.0 * smooth(0.09, 0.045, river) + 5.0 * smooth(0.045, 0.012, river);
    h += landmark_height(x, z, s) + forced_spire(x, z);
    // Last, shared flat masks override even cliffs and landmarks at the start.
    1.8 + (h - 1.8) * flat_weight
}

fn base_height(x: f32, z: f32) -> f32 {
    generated_height(x, z, seed)
}

fn biome(x: f32, z: f32) -> i64 {
    let value = climate(x, z);
    if value < 0.34 {
        return 1;
    }
    if value > 0.64 {
        return 2;
    }
    0
}

fn delta_at(gx: i64, gz: i64) -> f32 {
    for e in edits {
        if e.gx == gx && e.gz == gz {
            return e.delta;
        }
    }
    0.0
}

fn sample(gx: i64, gz: i64) -> f32 {
    generated_height(gx * 2.0, gz * 2.0, seed) + delta_at(gx, gz)
}

// Shared visual-only depth bias for coarse terrain and its distant vegetation.
fn visual_height(x: f32, z: f32) -> f32 {
    base_height(x, z) - (0.15 + 3.85 * natural_weight(x, z))
}

fn height(x: f32, z: f32) -> f32 {
    let gx = floor(x / 2.0) as i64;
    let gz = floor(z / 2.0) as i64;
    let tx = x / 2.0 - gx;
    let tz = z / 2.0 - gz;
    // Matches the two triangles used by mesh(), including across x/z zero.
    let a = sample(gx, gz);
    let b = sample(gx, gz + 1);
    let c = sample(gx + 1, gz + 1);
    let d = sample(gx + 1, gz);
    if tz >= tx { a + (c - b) * tx + (b - a) * tz } else { a + (d - a) * tx + (c - d) * tz }
}

fn modification(x: f32, z: f32) -> f32 {
    let gx = floor(x / 2.0) as i64;
    let gz = floor(z / 2.0) as i64;
    let tx = x / 2.0 - gx;
    let tz = z / 2.0 - gz;
    let a = delta_at(gx, gz);
    let b = delta_at(gx, gz + 1);
    let c = delta_at(gx + 1, gz + 1);
    let d = delta_at(gx + 1, gz);
    if tz >= tx {
        return a + (c - b) * tx + (b - a) * tz;
    }
    a + (d - a) * tx + (c - d) * tz
}

fn revision() -> i64 {
    let r = next_revision;
    next_revision++;
    r
}

thread_fn generate_worker() {
    loop {
        let job = qget<Job>();
        if job.stop {
            break;
        }
        let start = clock_ns();
        var out = Result { cx: job.cx, cz: job.cz, slot: job.slot, ticket: job.ticket, .. };
        for z in GRID {
            for x in GRID {
                out.heights[z * GRID + x] = generated_height(
                    job.cx * 32.0 + x * 2.0, job.cz * 32.0 + z * 2.0, job.seed);
            }
        }
        out.generate_ns = clock_ns() - start;
        assert(qput(out));
    }
}

fn init(s: u32) {
    if running {
        shutdown();
    }
    seed = s;
    pending = 0;
    loaded = 0;
    qlimit<Job>(MAX_JOBS + 2);
    qlimit<Result>(MAX_JOBS + 2);
    for i in 2 {
        worker_ids[i] = thread_spawn(generate_worker);
    }
    running = true;
}

fn find(cx: i64, cz: i64) -> i64 {
    for i in chunks.len {
        if chunks[i].active && chunks[i].cx == cx && chunks[i].cz == cz {
            return i;
        }
    }
    -1
}

fn apply_edits(c: Chunk&) {
    for e in edits {
        let x = e.gx - c.cx * 16;
        let z = e.gz - c.cz * 16;
        if x >= 0 && x < GRID && z >= 0 && z < GRID {
            c.heights[z * GRID + x] += e.delta;
        }
    }
}

fn accept(r: Result&) {
    pending--;
    generated++;
    generation_ms = r.generate_ns / 1000000.0;
    generation_total_ms += generation_ms;
    if r.slot >= chunks.len {
        return;
    }
    let c .= chunks[r.slot];
    if !c.active || c.ticket != r.ticket {
        return;
    }
    c.heights = r.heights;
    apply_edits(c);
    c.ready = true;
    c.revision = revision();
}

fn collect() {
    loop {
        let start = clock_ns();
        var r, ok = qpoll<Result>();
        transfer_ms += (clock_ns() - start) / 1000000.0;
        if !ok {
            break;
        }
        accept(r);
    }
}

fn drain() {
    while pending > 0 {
        let start = clock_ns();
        var r = qget<Result>();
        // This includes waiting; it is reported separately from copy-only timing.
        wait_ms += (clock_ns() - start) / 1000000.0;
        accept(r);
    }
}
var wait_ms: f64 = 0.0;

fn stream(x: f32, z: f32, requested_radius: i64, budget: i64) {
    assert(running);
    collect();
    let radius = clamp(requested_radius, 0, MAX_RADIUS);
    let cx = floor(x / CHUNK_SIZE) as i64;
    let cz = floor(z / CHUNK_SIZE) as i64;
    for i in chunks.len {
        if !chunks[i].active {
            continue;
        }
        if abs(chunks[i].cx - cx) > radius || abs(chunks[i].cz - cz) > radius {
            chunks[i].active = false;
            chunks[i].ready = false;
            chunks[i].revision = revision();
            chunks.free(i);
            loaded--;
            evicted++;
        }
    }
    var sent = 0;
    // Concentric squares prioritize terrain close to the player.
    for ring in radius + 1 {
        for dz in -ring..ring + 1 {
            for dx in -ring..ring + 1 {
                if max(abs(dx), abs(dz)) != ring {
                    continue;
                }
                if sent >= max(0, budget) || pending >= MAX_JOBS {
                    return;
                }
                if find(cx + dx, cz + dz) >= 0 {
                    continue;
                }
                let ticket = revision();
                let c .= chunks.alloc_ref(Chunk {
                    cx: cx + dx, cz: cz + dz, active: true,
                    revision: ticket, ticket: ticket, ..
                });
                let slot = chunks.index_of(c);
                assert(chunks.len <= MAX_CHUNKS);
                let start = clock_ns();
                let sent_ok = qput(Job {
                    cx: c.cx, cz: c.cz, slot: slot, ticket: ticket, seed: seed, stop: false,
                });
                transfer_ms += (clock_ns() - start) / 1000000.0;
                assert(sent_ok);
                pending++;
                max_pending = max(max_pending, pending);
                loaded++;
                sent++;
            }
        }
    }
}

fn invalidate() {
    for i in chunks.len {
        let c .= chunks[i];
        if !c.active || !c.ready {
            continue;
        }
        for z in GRID {
            for x in GRID {
                c.heights[z * GRID + x] = sample(c.cx * 16 + x, c.cz * 16 + z);
            }
        }
        c.revision = revision();
    }
}

fn edit(x: f32, z: f32, delta: f32) {
    let gx = floor(x / 2.0 + 0.5) as i64;
    let gz = floor(z / 2.0 + 0.5) as i64;
    // A nine-vertex brush leaves a readable low-poly crater, never a crack.
    for dz in -1..2 {
        for dx in -1..2 {
            let falloff: f32 = if dx == 0 && dz == 0 { 1.0 } else if dx == 0 || dz == 0 { 0.42 } else { 0.18 };
            let amount = delta * falloff;
            var index: i64 = -1;
            for i in edits.len {
                if edits[i].gx == gx + dx && edits[i].gz == gz + dz {
                    index = i;
                    break;
                }
            }
            if index < 0 {
                edits.push(Edit { gx + dx, gz + dz, clamp(amount, -14.0, 10.0) });
            } else {
                edits[index].delta = clamp(edits[index].delta + amount, -14.0, 10.0);
            }
        }
    }
    // Only chunks touched by this brush are recomputed.
    for i in chunks.len {
        let c .= chunks[i];
        if !c.active || !c.ready {
            continue;
        }
        if gx + 1 < c.cx * 16 || gx - 1 > c.cx * 16 + 16 || gz + 1 < c.cz * 16 || gz - 1 > c.cz * 16 + 16 {
            continue;
        }
        for zz in GRID {
            for xx in GRID {
                c.heights[zz * GRID + xx] = sample(c.cx * 16 + xx, c.cz * 16 + zz);
            }
        }
        c.revision = revision();
    }
}

fn smooth(a: f32, b: f32, value: f32) -> f32 {
    let t = clamp((value - a) / (b - a), 0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

fn blend(a: float3, b: float3, t: f32) -> float3 {
    a * ft::splat(1.0 - t) + b * ft::splat(t)
}

fn height_tint(low: float3, ground: float3, crest: float3, t: f32) -> float3 {
    blend(blend(low, ground, min(t * 2.0, 1.0)), crest, max(t * 2.0 - 1.0, 0.0))
}

fn terrain_color(x: f32, z: f32, y: f32, n: float3, close_detail: bool) -> float4 {
    // ART_DIRECTION.md: painted teal, amber strata and lavender fungal loam.
    let weights = climate_weights(climate(x, z));
    let arid = weights.y;
    let fungal = weights.z;
    let broad = (noise(x / 120.0, z / 120.0, seed) - 0.5) * 27.0;
    let continental = (noise(x / 700.0, z / 700.0, seed + 5) - 0.5) * 36.0;
    let local_mean = weights.x * (continental + broad)
        + arid * (continental + 0.6 * broad + 12.0)
        + fungal * (0.7 * continental + 0.5 * broad - 6.0);
    let t = smooth(-6.0, 14.0, y - local_mean);
    let meadow = height_tint(
        float3 { 0.173, 0.478, 0.447 },
        float3 { 0.247, 0.635, 0.557 },
        float3 { 0.486, 0.812, 0.690 }, t,
    );
    let amber = height_tint(
        float3 { 0.788, 0.451, 0.239 },
        float3 { 0.886, 0.635, 0.341 },
        float3 { 0.941, 0.788, 0.541 }, t,
    );
    let lavender = height_tint(
        float3 { 0.365, 0.310, 0.573 },
        float3 { 0.541, 0.482, 0.761 },
        float3 { 0.718, 0.643, 0.902 }, t,
    );
    var col = blend(blend(meadow, amber, arid), lavender, fungal);
    let rock = smooth(0.80, 0.62, n.y);
    let band_pos = y / 1.6 + 0.15 * noise(x / 20.0, z / 20.0, seed + 29);
    let band = band_pos - floor(band_pos);
    let strata = if band < 0.35 {
        float3 { 0.941, 0.788, 0.541 }
    } else if band < 0.70 {
        float3 { 0.788, 0.451, 0.239 }
    } else {
        float3 { 0.612, 0.306, 0.212 }
    };
    let cliff = blend(
        blend(float3 { 0.337, 0.376, 0.478 }, strata, arid),
        float3 { 0.294, 0.267, 0.439 }, fungal,
    );
    col = blend(col, cliff, rock);
    if grove_mask(x, z) >= 0.42 {
        let forest = float3 { 0.165, 0.478, 0.525 };
        col = blend(col, forest, 0.6 * weights.x * (1.0 - rock));
    }
    let salt = salt_strength_at(x, z, seed) * natural_weight(x, z);
    if salt > 0.5 {
        col = float3 { 0.902, 0.925, 0.910 };
    }
    var dug: f32 = 0.0;
    if close_detail && edits.len > 0 {
        // Interpolation on a natural terrace is not excavation. Only persistent
        // edit deltas expose soil; distant LOD omits these small modifications.
        dug = -modification(x, z);
    }
    if dug > 0.15 {
        let soil = blend(
            float3 { 0.431, 0.294, 0.247 },
            float3 { 0.290, 0.204, 0.204 }, smooth(1.8, 2.2, dug),
        );
        col = blend(col, soil, smooth(0.15, 0.60, dug));
    }
    if close_detail {
        let gx = floor(x / 2.0) as i64;
        let gz = floor(z / 2.0) as i64;
        var neighbor_mean: f32 = 0.0;
        for dz in -1..2 {
            for dx in -1..2 {
                neighbor_mean += sample(gx + dx, gz + dz);
            }
        }
        col *= ft::splat(1.0 - 0.15 * smooth(0.5, 1.3, neighbor_mean / 9.0 - y));
    }
    let j = random01(floor(x) as i64, floor(z) as i64, seed + 3) * 2.0 - 1.0;
    col *= float3 { 1.0 + j * 0.05, 1.0 + j * 0.03, 1.0 - j * 0.02 };
    float4 { col.x, col.y, col.z, 1.0 }
}

fn color(x: f32, z: f32, y: f32, n: float3) -> float4 {
    terrain_color(x, z, y, n, true)
}

fn far_color(x: f32, z: f32, y: f32, n: float3) -> float4 {
    terrain_color(x, z, y, n, false)
}

fn tri(out: ft::Vertex[>..]&, a: float3, b: float3, c: float3) {
    let n = normalize(cross(b - a, c - a));
    let center = (a + b + c) * ft::splat(1.0 / 3.0);
    let col = color(center.x, center.z, center.y, n);
    out.push(ft::Vertex { a, n, col });
    out.push(ft::Vertex { b, n, col });
    out.push(ft::Vertex { c, n, col });
}

fn skirt(out: ft::Vertex[>..]&, a: float3, b: float3) {
    // Terraces can leave more than eight metres of interpolation underlap at
    // the coarse horizon edge. Buried walls cover that gap with ample margin.
    // Interior chunk walls remain depth-occluded by neighbouring terrain.
    let down = float3 { 0.0, -32.0, 0.0 };
    let normal = normalize(cross(b - a, down));
    let center = (a + b) * ft::splat(0.5);
    let col = color(center.x, center.z, center.y, normal);
    out.push(ft::Vertex { a, normal, col });
    out.push(ft::Vertex { b, normal, col });
    out.push(ft::Vertex { b + down, normal, col });
    out.push(ft::Vertex { a, normal, col });
    out.push(ft::Vertex { b + down, normal, col });
    out.push(ft::Vertex { a + down, normal, col });
}

fn mesh(slot: i64) -> ft::Vertex[>..] {
    var out: ft::Vertex[>..] = [];
    let ch .= chunks[slot];
    if !ch.active || !ch.ready {
        return out;
    }
    for z in GRID - 1 {
        for x in GRID - 1 {
            let wx: f32 = ch.cx * 32.0 + x * 2.0;
            let wz: f32 = ch.cz * 32.0 + z * 2.0;
            let a = float3 { wx, ch.heights[z * GRID + x], wz };
            let b = float3 { wx, ch.heights[(z + 1) * GRID + x], wz + 2.0 };
            let c = float3 { wx + 2.0, ch.heights[(z + 1) * GRID + x + 1], wz + 2.0 };
            let d = float3 { wx + 2.0, ch.heights[z * GRID + x + 1], wz };
            tri(out, a, b, c);
            tri(out, a, c, d);
        }
    }
    for i in GRID - 1 {
        let x: f32 = ch.cx * 32.0 + i * 2.0;
        let z: f32 = ch.cz * 32.0 + i * 2.0;
        let left: f32 = ch.cx * 32.0;
        let front: f32 = ch.cz * 32.0;
        skirt(
            out,
            float3 { x, ch.heights[i], front },
            float3 { x + 2.0, ch.heights[i + 1], front },
        );
        skirt(
            out,
            float3 { x + 2.0, ch.heights[16 * GRID + i + 1], front + 32.0 },
            float3 { x, ch.heights[16 * GRID + i], front + 32.0 },
        );
        skirt(
            out,
            float3 { left, ch.heights[(i + 1) * GRID], z + 2.0 },
            float3 { left, ch.heights[i * GRID], z },
        );
        skirt(
            out,
            float3 { left + 32.0, ch.heights[i * GRID + 16], z },
            float3 { left + 32.0, ch.heights[(i + 1) * GRID + 16], z + 2.0 },
        );
    }
    out
}

fn shutdown() {
    if !running {
        return;
    }
    drain();
    for i in 2 {
        assert(qput(Job { stop: true, .. }));
    }
    for i in 2 {
        assert(thread_wait(worker_ids[i]));
    }
    for i in chunks.len {
        if chunks[i].active {
            chunks[i].active = false;
            chunks[i].ready = false;
            chunks[i].revision = revision();
            chunks.free(i);
        }
    }
    loaded = 0;
    running = false;
}
