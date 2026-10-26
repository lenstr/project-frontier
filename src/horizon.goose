// Six bounded terrain annuli extend the planet beyond detailed streaming.
// CPU mesh scratch dies per ring; active GPU rings swap atomically as a set.
namespace horizon;
import std;
import vec;
import math;
import os;
import gfx;
import .types;
import .world;
import .render;

let RINGS = 6;
let SNAP: f32 = 256.0;
let MIN_DISTANCE: f32 = 1536.0;
let MAX_DISTANCE: f32 = 16384.0;

var cache: render::Mesh[6];
var staging: render::Mesh[6];
var triangles: i64 = 0;
var mesh_count: i64 = 0;
var generation_ms: f64 = 0.0;
var generation_total_ms: f64 = 0.0;
var ready = false;
var active_center: float3;
var building = false;
var fading = false;
var fade_started: f64 = 0.0;
let FADE_SECONDS: f64 = 0.35;
var pending_rings: i64 = 0;
var generated_rings: i64 = 0;
var rebuilds: i64 = 0;
var live_meshes: i64 = 0;
var peak_meshes: i64 = 0;
var uploaded_meshes: i64 = 0;
var released_meshes: i64 = 0;
var requested_x: i64 = 0;
var requested_z: i64 = 0;
var requested_near: f32 = 0.0;
var requested_far: f32 = 0.0;
var requested_seed: u32 = 0;

struct MeshJob {
    center: float3,
    near_radius: f32,
    far_distance: f32,
    seed: u32,
    ticket: i64,
    ring: i64,
    stop: bool,
}

struct MeshResult {
    ticket: i64,
    ring: i64,
    generate_ns: i64,
    vertices: ft::Vertex[],
}

var worker_id: i64 = 0;
var worker_running = false;
var worker_busy = false;
var ticket: i64 = 0;
var transfer_ms: f64 = 0.0;
var upload_ms: f64 = 0.0;
var stale_results: i64 = 0;

fn ring_step(ring: i64) -> f32 {
    let steps: f32[6] = [8.0, 16.0, 32.0, 64.0, 128.0, 256.0];
    steps[ring]
}

fn ring_inner(ring: i64, near_radius: f32, far_distance: f32) -> f32 {
    if ring == 0 {
        // Keep a buried fallback beneath detail chunks while they stream in.
        return 0.0;
    }
    if ring == 1 {
        return 512.0;
    }
    if ring == 2 {
        return 1024.0;
    }
    if ring == 3 {
        return min(1792.0, far_distance);
    }
    if ring == 4 {
        return min(4096.0, far_distance);
    }
    min(8192.0, far_distance)
}

fn ring_outer(ring: i64, far_distance: f32) -> f32 {
    if ring == 0 {
        return 512.0;
    }
    if ring == 1 {
        return 1024.0;
    }
    if ring == 2 {
        return min(1792.0, far_distance);
    }
    if ring == 3 {
        return min(4096.0, far_distance);
    }
    if ring == 4 {
        return min(8192.0, far_distance);
    }
    far_distance
}

fn fallback_height(x: f32, z: f32) -> f32 {
    // Flat construction pads need only a small depth bias; buildings stay seated.
    let burial = 0.15 + 3.85 * world::natural_weight(x, z);
    world::base_height(x, z) - burial
}

fn surface(x: f32, z: f32, center: float3, near_radius: f32) -> float3 {
    // A constant burial keeps the same world vertex stationary when the
    // streaming center moves. A moving radial depression produced visible waves.
    float3 { x, fallback_height(x, z), z }
}

// Interpolate the parent grid with the same triangle diagonal as terrain.
fn parent_height(x: f32, z: f32, step: f32) -> f32 {
    let gx = floor(x / step) * step;
    let gz = floor(z / step) * step;
    let tx = (x - gx) / step;
    let tz = (z - gz) / step;
    let a = fallback_height(gx, gz);
    let b = fallback_height(gx, gz + step);
    let c = fallback_height(gx + step, gz + step);
    let d = fallback_height(gx + step, gz);
    if tz >= tx {
        a + (c - b) * tx + (b - a) * tz
    } else {
        a + (d - a) * tx + (c - d) * tz
    }
}

fn lod_surface(x: f32, z: f32, center: float3, near_radius: f32, step: f32, outer: f32) -> float3 {
    var point = surface(x, z, center, near_radius);
    let distance = max(abs(x - center.x), abs(z - center.z));
    let blend = world::smooth(outer * 0.65, outer, distance);
    if blend > 0.0 {
        let parent = parent_height(x, z, step * 2.0);
        point.y += (parent - point.y) * blend;
    }
    point
}

fn face(out: ft::Vertex[>..]&, a: float3, b: float3, c: float3) {
    let normal = normalize(cross(b - a, c - a));
    let center = (a + b + c) * ft::splat(1.0 / 3.0);
    // Shared palette/climate, without close terrain's nine height samples for
    // concavity shading or tiny persistent edits that this LOD cannot resolve.
    let col = world::far_color(center.x, center.z, center.y, normal);
    out.push(ft::Vertex { a, normal, col });
    out.push(ft::Vertex { b, normal, col });
    out.push(ft::Vertex { c, normal, col });
}

fn edge_skirt(out: ft::Vertex[>..]&, a: float3, b: float3) {
    let drop = float3 { 0.0, -64.0, 0.0 };
    face(out, a, b, b + drop);
    face(out, a, b + drop, a + drop);
}

fn boundary_surface(
    x: f32, z: f32, center: float3, near_radius: f32, step: f32, outer: f32,
) -> float3 {
    if step > 0.0 {
        return lod_surface(x, z, center, near_radius, step, outer);
    }
    surface(x, z, center, near_radius)
}

fn boundary(
    out: ft::Vertex[>..]&, center: float3, radius: f32,
    step: f32, near_radius: f32, view_center: float3,
    morph_step: f32 = 0.0, morph_outer: f32 = 0.0,
) {
    if radius <= 0.0 {
        return;
    }
    let segments = (radius * 2.0 / step) as i64;
    for i in segments {
        let offset: f32 = -radius + i * step;
        let left = center.x - radius;
        let right = center.x + radius;
        let front = center.z - radius;
        let back = center.z + radius;
        edge_skirt(
            out,
            boundary_surface(center.x + offset, front, view_center, near_radius, morph_step, morph_outer),
            boundary_surface(center.x + offset + step, front, view_center, near_radius, morph_step, morph_outer),
        );
        edge_skirt(
            out,
            boundary_surface(center.x + offset + step, back, view_center, near_radius, morph_step, morph_outer),
            boundary_surface(center.x + offset, back, view_center, near_radius, morph_step, morph_outer),
        );
        edge_skirt(
            out,
            boundary_surface(left, center.z + offset + step, view_center, near_radius, morph_step, morph_outer),
            boundary_surface(left, center.z + offset, view_center, near_radius, morph_step, morph_outer),
        );
        edge_skirt(
            out,
            boundary_surface(right, center.z + offset, view_center, near_radius, morph_step, morph_outer),
            boundary_surface(right, center.z + offset + step, view_center, near_radius, morph_step, morph_outer),
        );
    }
}

fn touches_feature(x: f32, z: f32, step: f32, fx: f32, fz: f32, radius: f32) -> bool {
    let dx = max(abs(x + step * 0.5 - fx) - step * 0.5, 0.0);
    let dz = max(abs(z + step * 0.5 - fz) - step * 0.5, 0.0);
    dx * dx + dz * dz < (radius + 8.0) * (radius + 8.0)
}

fn refine_cell(x: f32, z: f32, step: f32) -> bool {
    // Distant landmarks are subpixel; refining them would scale with world area.
    if step <= 8.0 || step > 64.0 {
        return false;
    }
    let feature = world::landmark(x + step * 0.5, z + step * 0.5);
    if feature.kind != 0 && touches_feature(x, z, step, feature.x, feature.z, feature.radius) {
        return true;
    }
    touches_feature(x, z, step, -370.0, -307.0, 30.0)
}

fn cell(
    out: ft::Vertex[>..]&, x: f32, z: f32, step: f32, center: float3,
    near_radius: f32, lod_step: f32, outer: f32,
) {
    let a = lod_surface(x, z, center, near_radius, lod_step, outer);
    let b = lod_surface(x, z + step, center, near_radius, lod_step, outer);
    let c = lod_surface(x + step, z + step, center, near_radius, lod_step, outer);
    let d = lod_surface(x + step, z, center, near_radius, lod_step, outer);
    face(out, a, b, c);
    face(out, a, c, d);
}

fn build_ring(
    ring: i64, center: float3, near_radius: f32, far_distance: f32,
) -> ft::Vertex[>..] {
    assert(ring >= 0 && ring < RINGS);
    var out: ft::Vertex[>..] = [];
    let inner = ring_inner(ring, near_radius, far_distance);
    let outer = ring_outer(ring, far_distance);
    if outer <= inner {
        return out;
    }
    let step = ring_step(ring);
    let cells = (outer * 2.0 / step) as i64;
    for zi in cells {
        let z: f32 = -outer + zi * step;
        for xi in cells {
            let x: f32 = -outer + xi * step;
            if abs(x + step * 0.5) < inner && abs(z + step * 0.5) < inner {
                continue;
            }
            let wx = center.x + x;
            let wz = center.z + z;
            if refine_cell(wx, wz, step) {
                // Narrow spires must not disappear between coarse grid points.
                // Only landmark cells retain eight-metre samples at long range.
                let subdivisions = (step / 8.0) as i64;
                for zi in subdivisions {
                    for xi in subdivisions {
                        cell(out, wx + xi * 8.0, wz + zi * 8.0, 8.0, center, near_radius, step, outer);
                    }
                }
                let tile_center = float3 { wx + step * 0.5, 0.0, wz + step * 0.5 };
                boundary(out, tile_center, step * 0.5, 8.0, near_radius, center, step, outer);
            } else {
                cell(out, wx, wz, step, center, near_radius, step, outer);
            }
        }
    }
    // Different grid spacings share endpoints but have T junctions in between.
    // Buried walls cover any vertical interpolation difference at those joins.
    boundary(out, center, inner, step, near_radius, center, step, outer);
    boundary(out, center, outer, step, near_radius, center, step, outer);
    out
}

fn retire(mesh: render::Mesh&) {
    if mesh.vertices.id == 0 {
        return;
    }
    render::release(mesh);
    mesh = render::Mesh { .. };
    live_meshes--;
    released_meshes++;
}

fn clear_staging() {
    for i in RINGS {
        retire(staging[i]);
    }
    pending_rings = 0;
}

fn refresh_stats() {
    triangles = 0;
    mesh_count = 0;
    for mesh in cache {
        if mesh.vertices.id != 0 {
            triangles += mesh.count / 3;
            mesh_count++;
        }
    }
}

thread_fn generate_worker() {
    loop {
        let job = qget<MeshJob>();
        if job.stop {
            break;
        }
        world::seed = job.seed;
        let started = clock_ns();
        var result = MeshResult {
            ticket: job.ticket,
            ring: job.ring,
            generate_ns: 0,
            vertices: build_ring(job.ring, job.center, job.near_radius, job.far_distance),
        };
        result.generate_ns = clock_ns() - started;
        assert(qput(result));
    }
}

fn init() {
    shutdown();
    requested_seed = world::seed;
    requested_near = 0.0;
    requested_far = 0.0;
    generation_ms = 0.0;
    generation_total_ms = 0.0;
    transfer_ms = 0.0;
    upload_ms = 0.0;
    stale_results = 0;
    generated_rings = 0;
    rebuilds = 0;
    uploaded_meshes = 0;
    released_meshes = 0;
    peak_meshes = 0;
    qlimit<MeshJob>(2);
    qlimit<MeshResult>(2);
    worker_id = thread_spawn(generate_worker);
    worker_running = true;
}

fn accept(result: MeshResult&) {
    worker_busy = false;
    generation_ms = result.generate_ns / 1000000.0;
    generation_total_ms += generation_ms;
    if result.ticket != ticket {
        stale_results++;
        return;
    }
    assert(result.ring == pending_rings);
    let started = clock();
    staging[result.ring] = render::upload(result.vertices);
    upload_ms += (clock() - started) * 1000.0;
    staging[result.ring].casts_shadow = false;
    staging[result.ring].receives_shadow = false;
    if staging[result.ring].vertices.id != 0 {
        live_meshes++;
        uploaded_meshes++;
        peak_meshes = max(peak_meshes, live_meshes);
    }
    pending_rings++;
    generated_rings++;
    assert(live_meshes <= RINGS * 2);
    if pending_rings == RINGS {
        fading = ready;
        fade_started = clock();
        for i in RINGS {
            let previous = cache[i];
            cache[i] = staging[i];
            staging[i] = previous;
        }
        pending_rings = 0;
        active_center = float3 { requested_x * SNAP, 0.0, requested_z * SNAP };
        ready = true;
        building = false;
        rebuilds++;
        refresh_stats();
    }
}

fn update(center: float3, near_radius: f32, far_distance: f32, budget: i64) {
    assert(worker_running);
    if fading {
        if clock() - fade_started < FADE_SECONDS {
            return;
        }
        clear_staging();
        fading = false;
    }
    let cx = floor(center.x / SNAP) as i64;
    let cz = floor(center.z / SNAP) as i64;
    let near = clamp(floor(near_radius / 8.0) * 8.0, 32.0, 256.0);
    let far = clamp(floor(far_distance / 64.0) * 64.0, MIN_DISTANCE, MAX_DISTANCE);
    let settings_changed = requested_near != near || requested_far != far || requested_seed != world::seed;
    let moved = requested_x != cx || requested_z != cz;
    // Coalesce camera travel until the current complete set is ready. Only
    // incompatible settings invalidate an outstanding result by its ticket.
    if settings_changed || (moved && !building) {
        clear_staging();
        ticket++;
        requested_x = cx;
        requested_z = cz;
        requested_near = near;
        requested_far = far;
        requested_seed = world::seed;
        building = true;
    }
    generation_ms = 0.0;
    if budget <= 0 {
        return;
    }
    if worker_busy {
        let started = clock();
        var result, available = qpoll<MeshResult>();
        transfer_ms += (clock() - started) * 1000.0;
        if available {
            accept(result);
        }
    }
    if building && !worker_busy {
        let origin = float3 { requested_x * SNAP, 0.0, requested_z * SNAP };
        let started = clock();
        assert(qput(MeshJob {
            center: origin,
            near_radius: requested_near,
            far_distance: requested_far,
            seed: requested_seed,
            ticket: ticket,
            ring: pending_rings,
            stop: false,
        }));
        transfer_ms += (clock() - started) * 1000.0;
        worker_busy = true;
    }
}

// Blocking is reserved for initial loading, tests and shutdown, never flight frames.
fn drain() {
    while building || worker_busy {
        if worker_busy {
            var result = qget<MeshResult>();
            accept(result);
        }
        if building {
            update(float3 { requested_x * SNAP, 0.0, requested_z * SNAP }, requested_near, requested_far, 1);
        }
    }
    if fading {
        clear_staging();
        fading = false;
    }
}

fn fade_progress() -> f32 {
    clamp((clock() - fade_started) / FADE_SECONDS, 0.001, 0.999) as f32
}

fn previous_meshes() -> render::Mesh[:] {
    staging[..]
}

fn meshes() -> render::Mesh[:] {
    cache[..]
}

fn shutdown() {
    if worker_running {
        drain();
        assert(qput(MeshJob { stop: true, .. }));
        assert(thread_wait(worker_id));
        worker_running = false;
    }
    clear_staging();
    for i in RINGS {
        retire(cache[i]);
    }
    ready = false;
    building = false;
    triangles = 0;
    mesh_count = 0;
    assert(live_meshes == 0);
}
