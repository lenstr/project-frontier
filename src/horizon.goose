// Four bounded terrain annuli extend the planet beyond detailed streaming.
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

let RINGS = 4;
let SNAP: f32 = 64.0;
let MIN_DISTANCE: f32 = 1536.0;
let MAX_DISTANCE: f32 = 2432.0;

var cache: render::Mesh[4];
var staging: render::Mesh[4];
var triangles: i64 = 0;
var mesh_count: i64 = 0;
var generation_ms: f64 = 0.0;
var generation_total_ms: f64 = 0.0;
var ready = false;
var active_center: float3;
var building = false;
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

fn ring_step(ring: i64) -> f32 {
    let steps: f32[4] = [8.0, 16.0, 32.0, 64.0];
    steps[ring]
}

fn ring_inner(ring: i64, near_radius: f32, far_distance: f32) -> f32 {
    if ring == 0 {
        return max(0.0, floor((near_radius - 96.0) / 8.0) * 8.0);
    }
    if ring == 1 {
        return 512.0;
    }
    if ring == 2 {
        return 1024.0;
    }
    min(1792.0, far_distance)
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
    far_distance
}

fn surface(x: f32, z: f32, center: float3, near_radius: f32) -> float3 {
    let distance = max(abs(x - center.x), abs(z - center.z));
    // The overlap is deliberately buried, so detailed two-metre facets win
    // the depth test. Detail skirts bridge its edge while it eases back up.
    let burial = 4.0 * (1.0 - world::smooth(near_radius + 16.0, near_radius + 80.0, distance));
    float3 { x, world::base_height(x, z) - burial, z }
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

fn boundary(
    out: ft::Vertex[>..]&, center: float3, radius: f32,
    step: f32, near_radius: f32, view_center: float3
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
            surface(center.x + offset, front, view_center, near_radius),
            surface(center.x + offset + step, front, view_center, near_radius)
        );
        edge_skirt(
            out,
            surface(center.x + offset + step, back, view_center, near_radius),
            surface(center.x + offset, back, view_center, near_radius)
        );
        edge_skirt(
            out,
            surface(left, center.z + offset + step, view_center, near_radius),
            surface(left, center.z + offset, view_center, near_radius)
        );
        edge_skirt(
            out,
            surface(right, center.z + offset, view_center, near_radius),
            surface(right, center.z + offset + step, view_center, near_radius)
        );
    }
}

fn touches_feature(x: f32, z: f32, step: f32, fx: f32, fz: f32, radius: f32) -> bool {
    let dx = max(abs(x + step * 0.5 - fx) - step * 0.5, 0.0);
    let dz = max(abs(z + step * 0.5 - fz) - step * 0.5, 0.0);
    dx * dx + dz * dz < (radius + 8.0) * (radius + 8.0)
}

fn refine_cell(x: f32, z: f32, step: f32) -> bool {
    if step <= 8.0 {
        return false;
    }
    let feature = world::landmark(x + step * 0.5, z + step * 0.5);
    if feature.kind != 0 && touches_feature(x, z, step, feature.x, feature.z, feature.radius) {
        return true;
    }
    touches_feature(x, z, step, -370.0, -307.0, 30.0)
}

fn cell(out: ft::Vertex[>..]&, x: f32, z: f32, step: f32, center: float3, near_radius: f32) {
    let a = surface(x, z, center, near_radius);
    let b = surface(x, z + step, center, near_radius);
    let c = surface(x + step, z + step, center, near_radius);
    let d = surface(x + step, z, center, near_radius);
    face(out, a, b, c);
    face(out, a, c, d);
}

fn build_ring(
    ring: i64, center: float3, near_radius: f32, far_distance: f32
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
                        cell(out, wx + xi * 8.0, wz + zi * 8.0, 8.0, center, near_radius);
                    }
                }
                let tile_center = float3 { wx + step * 0.5, 0.0, wz + step * 0.5 };
                boundary(out, tile_center, step * 0.5, 8.0, near_radius, center);
            } else {
                cell(out, wx, wz, step, center, near_radius);
            }
        }
    }
    // Different grid spacings share endpoints but have T junctions in between.
    // Buried walls cover any vertical interpolation difference at those joins.
    boundary(out, center, inner, step, near_radius, center);
    boundary(out, center, outer, step, near_radius, center);
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

fn init() {
    shutdown();
    requested_seed = world::seed;
    requested_near = 0.0;
    requested_far = 0.0;
    generation_ms = 0.0;
    generation_total_ms = 0.0;
    generated_rings = 0;
    rebuilds = 0;
    uploaded_meshes = 0;
    released_meshes = 0;
    peak_meshes = 0;
}

fn update(center: float3, near_radius: f32, far_distance: f32, budget: i64) {
    let cx = floor(center.x / SNAP) as i64;
    let cz = floor(center.z / SNAP) as i64;
    let near = clamp(floor(near_radius / 8.0) * 8.0, 32.0, 256.0);
    let far = clamp(floor(far_distance / 64.0) * 64.0, MIN_DISTANCE, MAX_DISTANCE);
    let settings_changed = requested_near != near || requested_far != far || requested_seed != world::seed;
    let moved = requested_x != cx || requested_z != cz;
    // Finish an in-flight set before following the newest center. Cancelling
    // every 64 m starved all four rings during fast survey flight.
    if settings_changed || (moved && (!building || pending_rings == 0)) {
        clear_staging();
        requested_x = cx;
        requested_z = cz;
        requested_near = near;
        requested_far = far;
        requested_seed = world::seed;
        building = true;
    }
    generation_ms = 0.0;
    if !building || budget <= 0 {
        return;
    }
    let start = clock();
    let origin = float3 { requested_x * SNAP, 0.0, requested_z * SNAP };
    for job in min(budget, RINGS) {
        if pending_rings >= RINGS {
            break;
        }
        var vertices = build_ring(pending_rings, origin, requested_near, requested_far);
        staging[pending_rings] = render::upload(vertices);
        staging[pending_rings].casts_shadow = false;
        if staging[pending_rings].vertices.id != 0 {
            live_meshes++;
            uploaded_meshes++;
            peak_meshes = max(peak_meshes, live_meshes);
        }
        pending_rings++;
        generated_rings++;
    }
    generation_ms = (clock() - start) * 1000.0;
    generation_total_ms += generation_ms;
    assert(live_meshes <= RINGS * 2);
    if pending_rings == RINGS {
        for i in RINGS {
            retire(cache[i]);
            cache[i] = staging[i];
            staging[i] = render::Mesh { .. };
        }
        pending_rings = 0;
        active_center = origin;
        ready = true;
        building = false;
        rebuilds++;
        refresh_stats();
    }
}

fn meshes() -> render::Mesh[:] {
    cache[..]
}

fn shutdown() {
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
