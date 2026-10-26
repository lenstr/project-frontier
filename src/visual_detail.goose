// Full two-metre terrain tiles stream independently of simulation chunks.
namespace detail;
import std;
import vec;
import math;
import os;
import .world;
import .horizon;
import .render;
import .types;

let TILE = 128;
let MAX_RADIUS = 16;
let MAX_TILES = 1089;
let MAX_JOBS = 8;

struct Tile {
    cx: i64, cz: i64, active: bool, dirty: bool, queued: bool,
    ticket: i64, mesh: render::Mesh,
}
struct Job {
    cx: i64, cz: i64, slot: i64, ticket: i64, seed: u32, stop: bool,
    edits: world::Edit[],
}
struct Result {
    slot: i64, ticket: i64, generation_ns: i64,
    vertices: ft::Vertex[],
}

reusable var tiles: Tile[>..] = [];
var previous_edits: world::Edit[>..<] = [];
var previous_seed: u32 = 0;
var workers: i64[2];
var running = false;
var pending: i64 = 0;
var next_ticket: i64 = 1;
var loaded: i64 = 0;
var generated: i64 = 0;
var uploaded: i64 = 0;
var released: i64 = 0;
var live_meshes: i64 = 0;
var peak_meshes: i64 = 0;
var stale_results: i64 = 0;
var generation_ms: f64 = 0.0;
var queue_ms: f64 = 0.0;
var upload_ms: f64 = 0.0;

fn tile_radius(metres: f32) -> i64 {
    clamp(ceil(metres / TILE) as i64, 4, MAX_RADIUS)
}

fn release_mesh(tile: Tile&) {
    if tile.mesh.vertices.id != 0 {
        render::release(tile.mesh);
        tile.mesh = render::Mesh { .. };
        live_meshes--;
        released++;
    }
}

thread_fn generate_worker() {
    loop {
        var job = qget<Job>();
        if job.stop {
            break;
        }
        world::seed = job.seed;
        world::edits.clear();
        world::edits.append(job.edits);
        let started = clock_ns();
        var result = Result {
            slot: job.slot, ticket: job.ticket, generation_ns: 0,
            vertices: horizon::build_detail_tile(job.cx, job.cz),
        };
        result.generation_ns = clock_ns() - started;
        assert(qput(result));
    }
}

fn init() {
    shutdown();
    pending = 0;
    loaded = 0;
    generated = 0;
    uploaded = 0;
    released = 0;
    peak_meshes = 0;
    stale_results = 0;
    generation_ms = 0.0;
    queue_ms = 0.0;
    upload_ms = 0.0;
    previous_seed = world::seed;
    previous_edits.clear();
    previous_edits.append(world::edits);
    qlimit<Job>(MAX_JOBS + 2);
    qlimit<Result>(MAX_JOBS + 2);
    for i in 2 {
        workers[i] = thread_spawn(generate_worker);
    }
    running = true;
}

fn accept(result: Result&) {
    pending--;
    generated++;
    generation_ms += result.generation_ns / 1000000.0;
    if result.slot >= tiles.len || !tiles[result.slot].active || tiles[result.slot].ticket != result.ticket {
        stale_results++;
        return;
    }
    let tile .= tiles[result.slot];
    let started = clock();
    release_mesh(tile);
    tile.mesh = render::upload(result.vertices);
    tile.mesh.casts_shadow = false;
    tile.mesh.receives_shadow = false;
    live_meshes++;
    uploaded++;
    peak_meshes = max(peak_meshes, live_meshes);
    tile.queued = false;
    tile.dirty = false;
    upload_ms += (clock() - started) * 1000.0;
}

fn collect(budget: i64) {
    for i in max(0, budget) {
        let started = clock();
        var result, available = qpoll<Result>();
        queue_ms += (clock() - started) * 1000.0;
        if !available {
            break;
        }
        accept(result);
    }
}

fn drain() {
    while pending > 0 {
        var result = qget<Result>();
        accept(result);
    }
}

fn find(cx: i64, cz: i64) -> i64 {
    for i in tiles.len {
        if tiles[i].active && tiles[i].cx == cx && tiles[i].cz == cz {
            return i;
        }
    }
    -1
}

fn edits_match() -> bool {
    if previous_edits.len != world::edits.len {
        return false;
    }
    for i in previous_edits.len {
        let a = previous_edits[i];
        let b = world::edits[i];
        if a.gx != b.gx || a.gz != b.gz || a.delta != b.delta {
            return false;
        }
    }
    true
}

fn touches(cx: i64, cz: i64, edits: const world::Edit[:]) -> bool {
    for edit in edits {
        let x = edit.gx * 2;
        let z = edit.gz * 2;
        if x >= cx * TILE - 2 && x <= (cx + 1) * TILE + 2
            && z >= cz * TILE - 2 && z <= (cz + 1) * TILE + 2
        {
            return true;
        }
    }
    false
}

fn job_edits(cx: i64, cz: i64) -> world::Edit[>..] {
    var result: world::Edit[>..] = [];
    for edit in world::edits {
        let x = edit.gx * 2;
        let z = edit.gz * 2;
        if x >= cx * TILE - 2 && x <= (cx + 1) * TILE + 2
            && z >= cz * TILE - 2 && z <= (cz + 1) * TILE + 2
        {
            result.push(edit);
        }
    }
    result
}

fn stream(center: float3, metres: f32, enabled: bool, budget: i64) {
    assert(running);
    collect(2);
    let cx = floor(center.x / TILE) as i64;
    let cz = floor(center.z / TILE) as i64;
    let radius = tile_radius(metres);
    let changed_seed = previous_seed != world::seed;
    let changed_edits = !edits_match();
    for i in tiles.len {
        if !tiles[i].active {
            continue;
        }
        let tile .= tiles[i];
        if !enabled || abs(tile.cx - cx) > radius || abs(tile.cz - cz) > radius {
            release_mesh(tile);
            tile.active = false;
            tiles.free(i);
            loaded--;
        } else if changed_seed || (changed_edits &&
            (touches(tile.cx, tile.cz, previous_edits) || touches(tile.cx, tile.cz, world::edits)))
        {
            tile.dirty = true;
            tile.queued = false;
            tile.ticket = next_ticket;
            next_ticket++;
        }
    }
    if changed_seed || changed_edits {
        previous_seed = world::seed;
        previous_edits.clear();
        previous_edits.append(world::edits);
    }
    if !enabled {
        return;
    }
    var sent: i64 = 0;
    for ring in radius + 1 {
        for dz in -ring..ring + 1 {
            for dx in -ring..ring + 1 {
                if max(abs(dx), abs(dz)) != ring {
                    continue;
                }
                if pending >= MAX_JOBS || sent >= budget {
                    return;
                }
                var slot = find(cx + dx, cz + dz);
                if slot < 0 {
                    let allocated .= tiles.alloc_ref(Tile { cx: cx + dx, cz: cz + dz, active: true, dirty: true, .. });
                    slot = tiles.index_of(allocated);
                    assert(tiles.len <= MAX_TILES);
                    loaded++;
                }
                let tile .= tiles[slot];
                if !tile.dirty || tile.queued {
                    continue;
                }
                tile.ticket = next_ticket;
                next_ticket++;
                assert(qput(Job {
                    cx: tile.cx, cz: tile.cz, slot: slot, ticket: tile.ticket,
                    seed: world::seed, stop: false, edits: job_edits(tile.cx, tile.cz),
                }));
                tile.queued = true;
                pending++;
                sent++;
            }
        }
    }
}

fn append_meshes(out: render::Mesh[>..]&) {
    for tile in tiles {
        if tile.active && tile.mesh.vertices.id != 0 {
            out.push(tile.mesh);
        }
    }
}

fn shutdown() {
    if !running {
        return;
    }
    drain();
    for i in 2 {
        assert(qput(Job { stop: true, .. }));
    }
    for worker in workers {
        assert(thread_wait(worker));
    }
    for i in tiles.len {
        if tiles[i].active {
            release_mesh(tiles[i]);
            tiles[i].active = false;
            tiles.free(i);
        }
    }
    loaded = 0;
    running = false;
    assert(live_meshes == 0 && uploaded == released);
}
