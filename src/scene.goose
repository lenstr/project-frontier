// Art assemblies and cached planet geometry. No game rules live in this module.
namespace scene;
import std;
import vec;
import math;
import .types;
import .render;
import .world;
import .entities;
import .sim;
import .horizon;
import .showcase;

let INK = float4 { 0.106, 0.137, 0.251, 1.0 };
let NAVY = float4 { 0.169, 0.227, 0.400, 1.0 };
let SLATE = float4 { 0.290, 0.333, 0.471, 1.0 };
let IVORY = float4 { 0.949, 0.918, 0.847, 1.0 };
let BONE = float4 { 0.827, 0.784, 0.690, 1.0 };
let ORANGE = float4 { 1.0, 0.478, 0.184, 1.0 };
let CYAN = float4 { 0.373, 0.949, 0.878, 2.5 };
let RED = float4 { 1.0, 0.302, 0.369, 1.6 };
let FERRITE = float4 { 0.824, 0.235, 0.353, 1.3 };
let GLACITE = float4 { 0.561, 0.827, 1.0, 1.5 };
var cached: render::Mesh[world::MAX_CHUNKS];
var revisions: i64[world::MAX_CHUNKS];
var terrain_vertices: i64 = 0;
var mesh_count: i64 = 0;
var last_seconds: f32 = 0.0;
var player_previous: float3;
var player_yaw: f32 = 0.0;
var player_moving: bool = false;
var night_strength: f32 = 0.0;
var district_night_strength: f32 = 0.0;
var vegetation: f32 = 1.0;
var vegetation_cached: f32 = 1.0;
var vegetation_center: float3;
var visible_distance: f32 = 420.0;
var inspector_target: ecs::Handle;
var view_center: float3;
var detached_view: bool = false;

fn visibility_center() -> float3 {
    if detached_view {
        return view_center;
    }
    sim::player
}

// Persistent cache inputs are values, never references into reusable entity
// or slice storage. Exact comparison avoids relying on a topology hash.
struct LogisticsBuilding {
    handle: ecs::Handle,
    kind: i64,
    pos: float3,
    first_link: i64,
    link_count: i64,
}

struct WireSpan {
    owner: ecs::Handle,
    source: ecs::Handle,
    a: float3,
    b: float3,
    distance: f32,
}

var logistics_buildings: LogisticsBuilding[>..<] = [];
var logistics_links: ecs::Handle[>..<] = [];
var logistics_visible: bool[>..<] = [];
var logistics_edits: world::Edit[>..<] = [];
var wire_spans: WireSpan[>..<] = [];
var logistics_ready: bool = false;
var logistics_seed: u32 = 0;
var rail_mesh: render::Mesh;
var rail_buffer_bytes: i64 = 0;
var rail_rebuilds: i64 = 0;
var rail_uploads: i64 = 0;
var rail_releases: i64 = 0;
var rail_live_meshes: i64 = 0;
var rail_peak_meshes: i64 = 0;
var wire_rebuilds: i64 = 0;
var logistics_cache_ms: f64 = 0.0;

struct Particle { pos: float3, velocity: float3, color: float4, life: f32, initial: f32 }
var particles: Particle[256];
var next_particle: i64 = 0;

fn frustum(
    out: ft::Vertex[>..]&, p: float3, bottom_radius: f32, top_radius: f32,
    height: f32, color: float4, sides: i64,
) {
    let b = p - float3 { 0.0, height * 0.5, 0.0 };
    let t = p + float3 { 0.0, height * 0.5, 0.0 };
    for i in max(sides, 3) {
        let a: f32 = i * TAU / max(sides, 3);
        let aa: f32 = (i + 1) * TAU / max(sides, 3);
        let direction = float3 { cos(a), 0.0, sin(a) };
        let next = float3 { cos(aa), 0.0, sin(aa) };
        let ba = b + direction * ft::splat(bottom_radius);
        let bb = b + next * ft::splat(bottom_radius);
        let ta = t + direction * ft::splat(top_radius);
        let tb = t + next * ft::splat(top_radius);
        render::triangle(out, ba, ta, tb, color);
        render::triangle(out, ba, tb, bb, color);
        render::triangle(out, b, ba, bb, color);
        render::triangle(out, t, tb, ta, color);
    }
}

// Flat-faceted ellipsoid, useful for suits, robot hulls and fungal caps.
fn egg(out: ft::Vertex[>..]&, center: float3, size: float3, color: float4) {
    for latitude in 5 {
        let a: f32 = -PI * 0.5 + latitude * PI / 5.0;
        let b: f32 = -PI * 0.5 + (latitude + 1) * PI / 5.0;
        for longitude in 8 {
            let u: f32 = longitude * TAU / 8.0;
            let v: f32 = (longitude + 1) * TAU / 8.0;
            let aa = center + float3 { cos(a) * cos(u), sin(a), cos(a) * sin(u) } * size * ft::splat(0.5);
            let ab = center + float3 { cos(a) * cos(v), sin(a), cos(a) * sin(v) } * size * ft::splat(0.5);
            let ba = center + float3 { cos(b) * cos(u), sin(b), cos(b) * sin(u) } * size * ft::splat(0.5);
            let bb = center + float3 { cos(b) * cos(v), sin(b), cos(b) * sin(v) } * size * ft::splat(0.5);
            render::triangle(out, aa, ba, bb, color);
            render::triangle(out, aa, bb, ab, color);
        }
    }
}

fn tilted_box(out: ft::Vertex[>..]&, center: float3, size: float3, color: float4, yaw: f32, pitch: f32) {
    var local: ft::Vertex[>..] = [];
    render::box(local, float3_0, size, color, 0.0);
    for vertex in local {
        let p = vertex.pos;
        let n = vertex.normal;
        let pitched_pos = float3 {
            p.x,
            p.y * cos(pitch) - p.z * sin(pitch),
            p.y * sin(pitch) + p.z * cos(pitch),
        };
        let pitched_normal = float3 {
            n.x,
            n.y * cos(pitch) - n.z * sin(pitch),
            n.y * sin(pitch) + n.z * cos(pitch),
        };
        let pos = render::turn(pitched_pos, yaw);
        let norm = render::turn(pitched_normal, yaw);
        out.push(ft::Vertex { center + pos, norm, color });
    }
}

fn shifted(p: float3, x: f32, y: f32, z: f32, yaw: f32) -> float3 {
    p + render::turn(float3 { x, y, z }, yaw)
}

fn ring(out: ft::Vertex[>..]&, p: float3, radius: f32, color: float4, thickness: f32) {
    for i in 20 {
        let a: f32 = i * TAU / 20.0;
        let b: f32 = (i + 1) * TAU / 20.0;
        render::beam(
            out, p + float3 { cos(a) * radius, 0.0, sin(a) * radius },
            p + float3 { cos(b) * radius, 0.0, sin(b) * radius }, thickness, color,
        );
    }
}

fn clear_of_machines(x: f32, z: f32) -> bool {
    let approach_u = 0.64 * x - 0.77 * z;
    let approach_v = -0.77 * x - 0.64 * z;
    if abs(approach_u) < 12.0 && approach_v > 0.0 && approach_v < 100.0 {
        return false;
    }
    let camera_dx = x - vegetation_center.x;
    let camera_dz = z - vegetation_center.z;
    if camera_dx * camera_dx + camera_dz * camera_dz < 64.0 {
        return false;
    }
    if x * x + z * z < 144.0 {
        return false;
    }
    for e in ecs::entities {
        if !e.alive || e.kind < 1 || e.kind > 9 || e.kind == 7 {
            continue;
        }
        let dx = e.pos.x - x;
        let dz = e.pos.z - z;
        if dx * dx + dz * dz < 6.25 {
            return false;
        }
    }
    true
}

fn in_factory_district(x: f32, z: f32, margin: f32) -> bool {
    let dx = x + 123.0;
    let dz = z + 102.0;
    let u = 0.64 * dx - 0.77 * dz;
    let v = -0.77 * dx - 0.64 * dz;
    abs(u) <= 88.0 + margin && abs(v) <= 80.0 + margin
}

fn clear_for_grove(x: f32, z: f32, emergent: bool) -> bool {
    if in_factory_district(x, z, 40.0) {
        return false;
    }
    if emergent {
        let u = 0.64 * x - 0.77 * z;
        let v = -0.77 * x - 0.64 * z;
        if abs(u) <= 20.0 && v >= 0.0 && v <= 480.0 {
            return false;
        }
    }
    clear_of_machines(x, z)
}

fn grove_plant(out: ft::Vertex[>..]&, p: float3, biome: i64, size: f32, variant: u32) {
    if biome == 1 {
        for layer in 4 {
            let color = if layer % 2 == 0 {
                ft::rgb(0.941, 0.788, 0.541)
            } else {
                ft::rgb(0.788, 0.451, 0.239)
            };
            frustum(
                out, p + float3 { 0.0, (layer + 0.5) * size, 0.0 },
                (0.85 - layer * 0.12) * size, (0.68 - layer * 0.12) * size,
                size, color, 6,
            );
        }
        return;
    }
    let height: f32 = if biome == 2 { 3.6 * size } else { 4.2 * size };
    if biome == 2 {
        render::cylinder(
            out, p + float3 { 0.0, height * 0.5, 0.0 }, 0.23 * size, height,
            ft::rgb(0.929, 0.890, 0.961), 6,
        );
        frustum(
            out, p + float3 { 0.0, height, 0.0 }, 1.9 * size, 1.4 * size,
            0.2 * size, float4 { 1.0, 0.62, 0.847, 1.4 }, 8,
        );
        frustum(
            out, p + float3 { 0.0, height + 0.5 * size, 0.0 },
            2.0 * size, 0.2 * size, size, ft::rgb(0.788, 0.651, 0.941), 8,
        );
        return;
    }
    let foliage = if variant % 3 == 0 {
        ft::rgb(0.180, 0.549, 0.557)
    } else if variant % 3 == 1 {
        ft::rgb(0.227, 0.612, 0.525)
    } else {
        ft::rgb(0.165, 0.478, 0.525)
    };
    render::cylinder(out, p + float3 { 0.0, height * 0.4, 0.0 }, 0.13 * size, height * 0.8, NAVY, 6);
    if variant % 4 < 2 {
        render::cone(out, p + float3 { 0.0, height * 0.68, 0.0 }, 1.2 * size, 2.4 * size, foliage, 6);
        render::cone(out, p + float3 { 0.0, height * 0.98, 0.0 }, 0.85 * size, 2.0 * size, foliage, 6);
        render::octahedron(out, p + float3 { 0.0, height * 1.22, 0.0 }, ft::splat(0.35 * size), IVORY, 0.0);
    } else if variant % 4 == 2 {
        frustum(out, p + float3 { 0.0, height * 0.92, 0.0 }, 1.8 * size, 1.3 * size, 0.5 * size, foliage, 8);
        frustum(out, p + float3 { 0.0, height * 1.04, 0.0 }, 1.25 * size, 0.5 * size, 0.45 * size, foliage, 8);
    } else {
        render::octahedron(
            out, p + float3 { 0.0, height * 0.84, 0.0 },
            float3 { 2.6 * size, 3.0 * size, 2.6 * size }, foliage, variant as f32,
        );
    }
}

fn decorate(out: ft::Vertex[>..]&, slot: i64) {
    let chunk .= world::chunks[slot];
    for grove in 4 {
        let anchor = world::hash(chunk.cx * 51 + grove, chunk.cz * 37 - grove * 5, world::seed + 909);
        let ax: f32 = chunk.cx * 32.0 + 6.0 + (anchor & 65535) / 65535.0 * 20.0;
        let az: f32 = chunk.cz * 32.0 + 6.0 + ((anchor >> 16) & 65535) / 65535.0 * 20.0;
        if world::grove_mask(ax, az) < 0.42 || !clear_for_grove(ax, az, false) {
            continue;
        }
        let biome = world::biome(ax, az);
        let members = max(3, ((6 + anchor % 11) * vegetation) as! i64);
        for member in members {
            let h = world::hash(chunk.cx * 113 + grove * 101 + member, chunk.cz * 127 - member * 5, world::seed + 1819);
            let x: f32 = ax + ((h & 65535) / 65535.0 - 0.5) * 15.0;
            let z: f32 = az + (((h >> 16) & 65535) / 65535.0 - 0.5) * 15.0;
            if !clear_for_grove(x, z, member == 0) {
                continue;
            }
            let p = float3 { x, world::height(x, z), z };
            let scale: f32 = if member == 0 {
                2.2 + ((h >> 8) & 255) / 255.0 * 0.8
            } else {
                0.6 + ((h >> 8) & 255) / 255.0 * 0.8
            };
            if member > 0 && member % 7 == 0 {
                render::octahedron(
                    out, p + float3 { 0.0, 0.5 * scale, 0.0 },
                    float3 { 1.7 * scale, scale, 1.4 * scale }, ft::rgb(0.337, 0.376, 0.478), member as f32,
                );
            } else {
                grove_plant(out, p, biome, scale, h);
            }
        }
        if biome == 0 {
            for shrub in 4 {
                let angle: f32 = shrub * PI * 0.5 + anchor / 65535.0;
                let x = ax + cos(angle) * 7.0;
                let z = az + sin(angle) * 7.0;
                if clear_for_grove(x, z, false) {
                    let p = float3 { x, world::height(x, z) + 0.4, z };
                    egg(out, p, float3 { 1.8, 0.9, 1.6 }, ft::rgb(0.227, 0.612, 0.525));
                }
            }
        }
    }
}

var grass_mesh: render::Mesh;
var grass_x: i64 = -9223372036854775807;
var grass_z: i64 = -9223372036854775807;
var grass_revision: i64 = -1;
var grass_density: f32 = -1.0;

fn sync_grass() {
    let cx = floor(vegetation_center.x / 16.0) as i64;
    let cz = floor(vegetation_center.z / 16.0) as i64;
    if cx == grass_x && cz == grass_z && grass_revision == world::next_revision
        && abs(grass_density - vegetation) < 0.01
    {
        return;
    }
    grass_x = cx;
    grass_z = cz;
    grass_revision = world::next_revision;
    grass_density = vegetation;
    var vertices: ft::Vertex[>..] = [];
    let tile_x = floor(vegetation_center.x / 32.0) as i64;
    let tile_z = floor(vegetation_center.z / 32.0) as i64;
    for dz in -2..3 {
        for dx in -2..3 {
            let samples = (96.0 * vegetation) as! i64;
            for i in samples {
                let h = world::hash((tile_x + dx) * 67 + i, (tile_z + dz) * 73 - i, world::seed + 231);
                let x: f32 = (tile_x + dx) * 32.0 + (h & 65535) / 65535.0 * 32.0;
                let z: f32 = (tile_z + dz) * 32.0 + ((h >> 16) & 65535) / 65535.0 * 32.0;
                let distance = length(float3 { x - vegetation_center.x, 0.0, z - vegetation_center.z });
                let falloff: f32 = clamp((64.0 - distance) / 16.0, 0.0, 1.0);
                if (h & 255) / 255.0 > falloff || world::biome(x, z) != 0 || !clear_of_machines(x, z) {
                    continue;
                }
                let p = float3 { x, world::height(x, z), z };
                for blade in 3 {
                    let angle: f32 = blade * 2.1 + i;
                    let side = float3 { cos(angle) * 0.11, 0.0, sin(angle) * 0.11 };
                    let tip = p + float3 { cos(angle) * 0.18, 0.4 + (h & 255) / 1024.0, sin(angle) * 0.18 };
                    render::triangle(vertices, p - side, tip, p + side, ft::rgb(0.337, 0.757, 0.627));
                    vertices[vertices.len - 2].color = ft::rgb(0.608, 0.890, 0.769);
                }
            }
        }
    }
    render::release(grass_mesh);
    grass_mesh = render::upload(vertices);
}

fn init() {
    render::init();
    last_seconds = sim::elapsed;
    player_previous = sim::player;
    logistics_ready = false;
}

fn invalidate() {
    for i in revisions.len {
        revisions[i] = 0;
    }
    grass_revision = -1;
    logistics_ready = false;
}

fn sync(budget: i64) {
    if abs(vegetation - vegetation_cached) > 0.01 {
        vegetation_cached = vegetation;
        for i in revisions.len {
            revisions[i] = 0;
        }
    }
    var built: i64 = 0;
    for slot in world::MAX_CHUNKS {
        let active = slot < world::chunks.len && world::chunks[slot].active && world::chunks[slot].ready;
        if !active {
            if cached[slot].vertices.id != 0 {
                render::release(cached[slot]);
                cached[slot] = render::Mesh { .. };
            }
            revisions[slot] = 0;
            continue;
        }
        if revisions[slot] == world::chunks[slot].revision {
            continue;
        }
        if cached[slot].vertices.id != 0 {
            render::release(cached[slot]);
            cached[slot] = render::Mesh { .. };
        }
        if built >= max(0, budget) {
            continue;
        }
        var vertices = world::mesh(slot);
        decorate(vertices, slot);
        cached[slot] = render::upload(vertices);
        revisions[slot] = world::chunks[slot].revision;
        built++;
    }
    sync_grass();
    terrain_vertices = grass_mesh.count;
    mesh_count = if grass_mesh.count > 0 { 1 } else { 0 };
    for m in cached {
        if m.count > 0 {
            terrain_vertices += m.count;
            mesh_count++;
        }
    }
}

fn foundation(out: ft::Vertex[>..]&, p: float3, radius: f32) {
    render::cylinder(out, p + float3 { 0.0, 0.08, 0.0 }, radius, 0.20, INK, 8);
    let color = float4 { 0.373, 0.949, 0.878, 1.0 + night_strength * 0.8 };
    for i in 8 {
        let a: f32 = i * TAU / 8.0;
        let b: f32 = (i + 1) * TAU / 8.0;
        let aa = p + float3 { cos(a) * radius, 0.19, sin(a) * radius };
        let bb = p + float3 { cos(b) * radius, 0.19, sin(b) * radius };
        let cc = p + float3 { cos(b) * (radius - 0.05), 0.19, sin(b) * (radius - 0.05) };
        let dd = p + float3 { cos(a) * (radius - 0.05), 0.19, sin(a) * (radius - 0.05) };
        render::triangle(out, aa, cc, bb, color);
        render::triangle(out, aa, dd, cc, color);
    }
}

fn status(out: ft::Vertex[>..]&, p: float3, powered: bool, active: bool, seconds: f32) {
    let color = if powered && active {
        CYAN
    } else if powered {
        ORANGE
    } else if seconds % 1.0 < 0.5 {
        RED
    } else {
        INK
    };
    render::octahedron(out, p, ft::splat(0.26), color, seconds * 0.5);
}

fn district_light_fade(day: f32) -> f32 {
    // Use the unclamped sun elevation, rather than the renderer's moonlight
    // floor. New window emission starts only below eight degrees.
    let sun_length = sqrt(0.72 * 0.72 + 0.44 * 0.44) as f32;
    let eight_degrees: f32 = 8.0 * PI / 180.0;
    let threshold = sin(eight_degrees) * sun_length;
    let sun_height: f32 = sin(day * TAU) * 0.72;
    clamp((threshold - sun_height) / threshold, 0.0, 1.0)
}

fn district_lit(p: float3) -> bool {
    showcase::enabled && district_night_strength > 0.0 && in_factory_district(p.x, p.z, 0.0)
}

fn window_band(
    out: ft::Vertex[>..]&, p: float3, yaw: f32,
    width: f32, depth: f32, height: f32, color: float4,
) {
    let corners: float2[4] = [
        float2 { -width * 0.5, -depth * 0.5 },
        float2 { width * 0.5, -depth * 0.5 },
        float2 { width * 0.5, depth * 0.5 },
        float2 { -width * 0.5, depth * 0.5 },
    ];
    for i in 4 {
        let a = corners[i];
        let b = corners[(i + 1) % 4];
        let lower_a = shifted(p, a.x, height - 0.055, a.y, yaw);
        let upper_a = shifted(p, a.x, height + 0.055, a.y, yaw);
        let lower_b = shifted(p, b.x, height - 0.055, b.y, yaw);
        let upper_b = shifted(p, b.x, height + 0.055, b.y, yaw);
        render::triangle(out, lower_a, upper_b, lower_b, color);
        render::triangle(out, lower_a, upper_a, upper_b, color);
    }
}

fn district_windows(out: ft::Vertex[>..]&, kind: i64, p: float3, yaw: f32) {
    if !district_lit(p) {
        return;
    }
    if kind == sim::LANDER {
        let cyan = float4 { 0.373, 0.949, 0.878, 1.0 + district_night_strength * 1.5 };
        render::cylinder(out, p + float3 { 0.0, 2.82, 0.0 }, 1.39, 0.12, cyan, 8);
    } else if kind == sim::SMELTER {
        let ember = float4 { 1.0, 0.604, 0.235, 1.0 + district_night_strength * 1.2 };
        window_band(out, p, yaw, 1.93, 2.33, 1.1, ember);
    } else if kind == sim::ASSEMBLER {
        let cyan = float4 { 0.373, 0.949, 0.878, 1.0 + district_night_strength * 0.8 };
        window_band(out, p, yaw, 2.23, 1.93, 0.95, cyan);
    } else if kind == sim::STORAGE {
        let ivory = float4 { 0.949, 0.918, 0.847, 1.0 + district_night_strength * 0.8 };
        window_band(out, p, yaw, 2.04, 1.88, 1.15, ivory);
    }
}

fn lander(out: ft::Vertex[>..]&, p: float3, seconds: f32) {
    let window_light = float4 { 0.373, 0.949, 0.878, 1.0 + night_strength * 1.5 };
    let lamp = float4 { 1.0, 0.851, 0.627, 1.0 + night_strength * 1.5 };
    foundation(out, p, 3.2);
    for i in 3 {
        let a: f32 = i * TAU / 3.0 + 0.5;
        let foot = p + float3 { cos(a) * 2.65, 0.24, sin(a) * 2.65 };
        render::cylinder(out, foot, 0.55, 0.24, NAVY, 8);
        render::beam(out, foot, p + float3 { cos(a) * 1.2, 1.8, sin(a) * 1.2 }, 0.17, NAVY);
        frustum(out, p + float3 { cos(a) * 0.7, 1.05, sin(a) * 0.7 }, 0.48, 0.3, 0.7, NAVY, 8);
        let nozzle = p + float3 { cos(a) * 0.7, 0.72, sin(a) * 0.7 };
        render::cylinder(out, nozzle, 0.33, 0.08, float4 { 0.85, 0.31, 0.16, 1.6 }, 8);
    }
    frustum(out, p + float3 { 0.0, 2.1, 0.0 }, 1.8, 1.25, 2.2, IVORY, 8);
    frustum(out, p + float3 { 0.0, 2.8, 0.0 }, 1.44, 1.3, 0.55, INK, 8);
    render::cylinder(out, p + float3 { 0.0, 3.1, 0.0 }, 1.32, 0.08, window_light, 8);
    render::cone(out, p + float3 { 0.0, 3.7, 0.0 }, 1.35, 1.3, IVORY, 8);
    render::cylinder(out, p + float3 { 0.0, 3.13, 0.0 }, 1.39, 0.16, ORANGE, 8);
    render::beam(out, p + float3 { 0.0, 4.3, 0.0 }, p + float3 { 0.0, 5.5, 0.0 }, 0.05, NAVY);
    status(out, p + float3 { 0.0, 5.55, 0.0 }, true, true, seconds);
    render::octahedron(out, p + float3 { 0.28, 5.15, 0.12 }, ft::splat(0.18), lamp, 0.0);
    tilted_box(out, p + float3 { 0.0, 0.65, 2.1 }, float3 { 1.3, 0.14, 2.3 }, BONE, 0.0, -0.38);
}

fn robot(out: ft::Vertex[>..]&, p: float3, yaw: f32, seconds: f32, id: i64) {
    let bob: f32 = sin(seconds * 4.0 + id * 1.7) * 0.07;
    let body = p + float3 { 0.0, 0.85 + bob, 0.0 };
    render::cylinder(out, p + float3 { 0.0, 0.3 + bob, 0.0 }, 0.35, 0.05, CYAN, 8);
    egg(out, body, float3 { 0.95, 0.85, 0.8 }, IVORY);
    render::box(out, shifted(body, 0.0, 0.05, -0.37, yaw), float3 { 0.7, 0.22, 0.11 }, INK, yaw);
    let eye_color = if seconds % 4.0 < 0.12 { NAVY } else { CYAN };
    let visor = shifted(body, 0.0, 0.05, -0.45, yaw);
    render::octahedron(out, visor, float3 { 0.18, 0.13, 0.08 }, eye_color, yaw);
    for i in 2 {
        let shoulder = shifted(body, (i * 2.0 - 1.0) * 0.22, 0.25, 0.0, yaw);
        let antenna = shifted(body, (i * 2.0 - 1.0) * 0.3, 0.62, 0.0, yaw);
        render::beam(out, shoulder, antenna, 0.035, ORANGE);
    }
    render::box(out, body + float3 { 0.0, 0.49, 0.0 }, float3 { 0.63, 0.15, 0.5 }, NAVY, yaw);
}

fn ore_deposit(out: ft::Vertex[>..]&, kind: i64, p: float3, yaw: f32, id: i64) {
    let color = if kind == 20 { FERRITE } else { GLACITE };
    render::octahedron(out, p + float3 { 0.0, 0.2, 0.0 }, float3 { 2.0, 0.65, 1.8 }, SLATE, yaw);
    for i in 5 {
        let a: f32 = i * 2.4 + id;
        let scale: f32 = 0.6 + (i % 3) * 0.25;
        render::octahedron(
            out,
            p + float3 { cos(a) * 0.6, 0.6 * scale, sin(a) * 0.6 },
            float3 { 0.62 * scale, 1.8 * scale, 0.65 * scale },
            color,
            a,
        );
    }
}

fn drill(out: ft::Vertex[>..]&, p: float3, yaw: f32, progress: f32, powered: bool, seconds: f32) {
    render::chamfered_box(out, p + float3 { 0.0, 0.7, 0.0 }, float3 { 1.6, 1.0, 1.6 }, IVORY, yaw);
    for i in 2 {
        let leg = shifted(p, (i * 2.0 - 1.0) * 0.83, 0.5, 0.0, yaw);
        render::beam(out, leg, p + float3 { 0.0, 2.7, 0.0 }, 0.12, NAVY);
    }
    let bob: f32 = if powered { sin(seconds * 9.0) * 0.18 } else { 0.0 };
    render::cylinder(out, p + float3 { 0.0, 1.4 + bob, 0.0 }, 0.17, 1.8, ORANGE, 8);
    render::cone(out, p + float3 { 0.0, 0.55 + bob, 0.0 }, 0.32, -0.6, NAVY, 8);
    render::chamfered_box(out, shifted(p, 0.0, 0.8, 1.0, yaw), float3 { 1.0, 0.5, 0.7 }, BONE, yaw);
    status(out, p + float3 { 0.0, 2.9, 0.0 }, powered, progress > 0.0, seconds);
}

fn smelter(out: ft::Vertex[>..]&, p: float3, yaw: f32, progress: f32, powered: bool, seconds: f32) {
    render::chamfered_box(out, p + float3 { 0.0, 0.95, 0.0 }, float3 { 1.9, 1.65, 2.3 }, IVORY, yaw);
    render::cylinder(out, p + float3 { 0.0, 1.4, 0.0 }, 0.8, 1.4, NAVY, 12);
    render::box(out, shifted(p, 0.0, 0.85, 1.18, yaw), float3 { 1.0, 0.8, 0.12 }, INK, yaw);
    let night_mix: f32 = if district_lit(p) { district_night_strength } else { 0.0 };
    let fire_green: f32 = 0.31 + sin(seconds * 4.4) * 0.06;
    let fire = if powered {
        float4 {
            1.0,
            fire_green * (1.0 - night_mix) + 0.604 * night_mix,
            0.12 * (1.0 - night_mix) + 0.235 * night_mix,
            2.6 * (1.0 - night_mix) + 2.2 * night_mix,
        }
    } else {
        INK
    };
    render::box(out, shifted(p, 0.0, 0.85, 1.25, yaw), float3 { 0.7, 0.55, 0.04 }, fire, yaw);
    let chimney = shifted(p, 0.55, 2.35, -0.55, yaw);
    render::cylinder(out, chimney, 0.25, 2.1, NAVY, 8);
    render::cylinder(out, chimney + float3 { 0.0, 0.7, 0.0 }, 0.28, 0.16, ORANGE, 8);
    status(out, shifted(p, -0.6, 2.0, 0.6, yaw), powered, progress > 0.0, seconds);
    if powered {
        for i in 3 {
            let age: f32 = (seconds * 0.38 + i / 3.0) % 1.0;
            render::octahedron(
                out,
                chimney + float3 { sin(age * 4.0 + i) * 0.3, 1.1 + age * 1.8, age * 0.4 },
                ft::splat(0.18 + age * 0.55),
                float4 { 0.70 + age * 0.1, 0.70 + age * 0.1, 0.77 + age * 0.05, 1.0 },
                i + seconds * 0.3,
            );
        }
    }
}

fn solar(out: ft::Vertex[>..]&, p: float3, powered: bool, seconds: f32) {
    render::cylinder(out, p + float3 { 0.0, 0.9, 0.0 }, 0.16, 1.8, NAVY, 6);
    render::cylinder(out, p + float3 { 0.0, 1.3, 0.0 }, 0.22, 0.25, IVORY, 8);
    let panel_yaw: f32 = sim::day * TAU + 1.57;
    let pitch: f32 = if sin(sim::day * TAU) > 0.0 { -0.35 } else { 0.0 };
    let center = p + float3 { 0.0, 1.9, 0.0 };
    tilted_box(out, center, float3 { 2.4, 0.12, 1.8 }, IVORY, panel_yaw, pitch);
    for row in 2 {
        for col in 3 {
            let local = float3 { (col - 1.0) * 0.75, 0.09, (row - 0.5) * 0.82 };
            let tilted = float3 {
                local.x,
                local.y * cos(pitch) - local.z * sin(pitch),
                local.y * sin(pitch) + local.z * cos(pitch),
            };
            let rotated = render::turn(tilted, panel_yaw);
            let cell_color = ft::rgb(0.141, 0.212, 0.431);
            tilted_box(out, center + rotated, float3 { 0.69, 0.04, 0.75 }, cell_color, panel_yaw, pitch);
        }
    }
    if district_lit(p) {
        let cyan = float4 { 0.373, 0.949, 0.878, 1.0 + district_night_strength * 0.8 };
        let corners: float2[4] = [
            float2 { -1.21, -0.91 }, float2 { 1.21, -0.91 },
            float2 { 1.21, 0.91 }, float2 { -1.21, 0.91 },
        ];
        for i in 4 {
            let a = corners[i];
            let b = corners[(i + 1) % 4];
            let local_a = float3 { a.x, 0.09 * cos(pitch) - a.y * sin(pitch), 0.09 * sin(pitch) + a.y * cos(pitch) };
            let local_b = float3 { b.x, 0.09 * cos(pitch) - b.y * sin(pitch), 0.09 * sin(pitch) + b.y * cos(pitch) };
            render::beam(out, center + render::turn(local_a, panel_yaw), center + render::turn(local_b, panel_yaw),
                0.06, cyan);
        }
    }
    status(out, p + float3 { 0.0, 1.65, 0.0 }, powered, true, seconds);
}

fn relay(out: ft::Vertex[>..]&, p: float3, yaw: f32, powered: bool, seconds: f32) {
    frustum(out, p + float3 { 0.0, 2.1, 0.0 }, 0.33, 0.12, 4.1, NAVY, 4);
    render::chamfered_box(out, p + float3 { 0.0, 4.1, 0.0 }, float3 { 1.7, 0.18, 0.3 }, IVORY, yaw);
    status(out, p + float3 { 0.0, 4.45, 0.0 }, powered, true, seconds);
}

fn assembler(out: ft::Vertex[>..]&, p: float3, yaw: f32, progress: f32, powered: bool, seconds: f32) {
    render::chamfered_box(out, p + float3 { 0.0, 0.8, 0.0 }, float3 { 2.2, 1.35, 1.9 }, IVORY, yaw);
    render::cylinder(out, p + float3 { 0.0, 1.5, 0.0 }, 0.6, 0.28, NAVY, 8);
    let core_color = if powered { CYAN } else { SLATE };
    let core = p + float3 { 0.0, 1.95, 0.0 };
    render::octahedron(out, core, float3 { 0.7, 0.8, 0.7 }, core_color, seconds * 1.2);
    for i in 2 {
        let a = shifted(p, (i * 2.0 - 1.0) * 0.9, 1.2, -0.3, yaw);
        let b = shifted(p, (i * 2.0 - 1.0) * 0.45, 2.2 + sin(seconds * 2.0 + i) * 0.15, -0.3, yaw);
        render::beam(out, a, b, 0.09, ORANGE);
    }
    status(out, shifted(p, 0.8, 1.7, 0.6, yaw), powered, progress > 0.0, seconds);
}

fn beacon(out: ft::Vertex[>..]&, p: float3, progress: f32, powered: bool, seconds: f32) {
    foundation(out, p, 2.0);
    for i in 4 {
        let radius: f32 = 1.1 - i * 0.2;
        frustum(out, p + float3 { 0.0, 2.0 + i * 3.9, 0.0 }, radius, radius - 0.14, 3.9, IVORY, 6);
        render::cylinder(out, p + float3 { 0.0, 3.85 + i * 3.9, 0.0 }, radius + 0.02, 0.18, ORANGE, 6);
    }
    // A tilted open dish: a shallow faceted bowl with a contrasting interior.
    let dish = p + float3 { 0.0, 16.2, 0.0 };
    render::beam(out, p + float3 { 0.0, 15.4, 0.0 }, dish, 0.14, NAVY);
    egg(out, dish, float3 { 3.8, 0.65, 3.8 }, IVORY);
    frustum(out, dish + float3 { 0.0, 0.28, 0.0 }, 1.55, 1.75, 0.15, NAVY, 12);
    render::beam(out, dish, dish + float3 { 0.0, 1.1, 0.0 }, 0.07, ORANGE);
    status(out, p + float3 { 0.0, 17.5, 0.0 }, powered, progress > 0.0, seconds);
    if sim::objective_done {
        let signal = float4 { 0.37, 0.949, 0.878, 4.0 };
        render::cylinder(out, p + float3 { 0.0, 61.0, 0.0 }, 0.6, 88.0, signal, 8);
        let wave: f32 = (seconds % 2.0) / 2.0;
        let wave_color = float4 { 0.37, 0.949, 0.878, 1.8 - wave * 0.7 };
        ring(out, p + float3 { 0.0, 0.2, 0.0 }, 2.0 + wave * 12.0, wave_color, 0.05);
    }
}

fn depot(out: ft::Vertex[>..]&, p: float3, yaw: f32) {
    render::chamfered_box(out, p + float3 { 0.0, 0.8, 0.0 }, float3 { 2.0, 1.4, 1.8 }, IVORY, yaw);
    for i in 3 {
        let rib = shifted(p, (i - 1.0) * 0.65, 0.85, 0.0, yaw);
        render::box(out, rib, float3 { 0.1, 1.45, 1.85 }, NAVY, yaw);
    }
    render::box(out, shifted(p, 0.0, 1.6, 0.0, yaw), float3 { 0.6, 0.1, 0.4 }, ORANGE, yaw);
}

fn machine(
    out: ft::Vertex[>..]&, kind: i64, p: float3, yaw: f32, progress: f32, powered: bool, seconds: f32,
    id: i64,
) {
    if kind == 1 {
        lander(out, p, seconds);
        district_windows(out, kind, p, yaw);
        return;
    }
    if kind == 7 {
        robot(out, p, yaw, seconds, id);
        return;
    }
    if kind == 90 {
        let rubble = ft::rgb(0.55, 0.67, 0.76);
        render::octahedron(out, p + float3 { 0.0, 0.3, 0.0 }, float3 { 0.45, 0.6, 0.45 }, rubble, yaw);
        return;
    }
    if kind == 20 || kind == 21 {
        ore_deposit(out, kind, p, yaw, id);
        return;
    }
    foundation(out, p, if kind == 8 { 2.0 } else if kind == 5 { 0.6 } else { 1.5 });
    let roof: f32 = if kind == 8 { 17.2 } else if kind == 5 { 4.2 } else if kind == 2 { 2.65 } else { 1.9 };
    let lamp = float4 { 1.0, 0.851, 0.627, 1.0 + night_strength * 1.5 };
    render::octahedron(out, shifted(p, 0.38, roof, 0.22, yaw), ft::splat(0.16), lamp, 0.0);
    if kind == 2 {
        drill(out, p, yaw, progress, powered, seconds);
    } else if kind == 3 {
        smelter(out, p, yaw, progress, powered, seconds);
    } else if kind == 4 {
        solar(out, p, powered, seconds);
    } else if kind == 5 {
        relay(out, p, yaw, powered, seconds);
    } else if kind == 6 {
        assembler(out, p, yaw, progress, powered, seconds);
    } else if kind == 8 {
        beacon(out, p, progress, powered, seconds);
    } else if kind == 9 {
        depot(out, p, yaw);
    }
    district_windows(out, kind, p, yaw);
}

fn district_landmarks(out: ft::Vertex[>..]&, seconds: f32) {
    // This is scenery, not a mission-completing TOWER entity. Uniform scaling
    // preserves the approved assembly while making the district readable.
    var tower: ft::Vertex[>..] = [];
    machine(tower, sim::TOWER, float3_0, 0.0, 1.0, true, seconds, -2);
    for vertex in tower {
        let pos = showcase::tower_position + vertex.pos * ft::splat(2.5);
        out.push(ft::Vertex { pos, vertex.normal, vertex.color });
    }
    let tip = showcase::tower_position + float3 { 0.0, 45.2, 0.0 };
    render::beam(out, tip - float3 { 0.0, 1.5, 0.0 }, tip, 0.09, NAVY);
    render::octahedron(out, tip, ft::splat(0.65), CYAN, seconds * 0.2);
    if seconds % 1.0 < 0.5 {
        let signal = float4 { 1.0, 0.478, 0.184, 2.2 };
        render::octahedron(out, tip + float3 { 0.0, 0.9, 0.0 }, ft::splat(0.24), signal, 0.0);
    }

    let head_strength: f32 = 0.4 + district_night_strength * 0.8;
    let head = float4 { 0.373, 0.949, 0.878, 1.0 + head_strength };
    let rail_light = float4 { 0.373, 0.949, 0.878, 1.0 + 0.4 + district_night_strength * 0.8 };
    let yaw = atan2(showcase::FORWARD_X, showcase::FORWARD_Z);
    for mast in 6 {
        let side: f32 = if mast % 2 == 0 { -5.0 } else { 5.0 };
        let p = showcase::position(side, -80.0 + mast * 32.0);
        render::cylinder(out, p + float3 { 0.0, 5.0, 0.0 }, 0.12, 10.0, NAVY, 6);
        render::chamfered_box(out, p + float3 { 0.0, 9.85, 0.0 }, float3 { 1.4, 0.2, 0.65 }, IVORY, yaw);
        render::box(out, p + float3 { 0.0, 10.05, 0.0 }, float3 { 1.2, 0.12, 0.5 }, head, yaw);
    }
    for light in 19 {
        let v: f32 = -76.0 + light * 8.0 + (seconds * 4.0) % 8.0;
        if v > 72.0 {
            continue;
        }
        let p = showcase::position(0.0, v) + float3 { 0.0, 0.76, 0.0 };
        render::box(out, p, float3 { 0.16, 0.07, 0.8 }, rail_light, yaw);
    }
}

fn path_point(a: float3, b: float3, t: f32) -> float3 {
    var p = a * ft::splat(1.0 - t) + b * ft::splat(t);
    p.y = max(p.y + 0.65, world::height(p.x, p.z) + 0.55);
    p
}

fn conveyor_structure(out: ft::Vertex[>..]&, a: float3, b: float3) {
    let delta = b - a;
    let distance = length(delta);
    if distance < 0.3 || distance > 64.0 {
        return;
    }
    let side = normalize(cross(delta, float3 { 0.0, 1.0, 0.0 })) * ft::splat(0.25);
    let segments = max(1, ceil(distance / 2.0) as i64);
    for i in segments {
        let p = path_point(a, b, i as f32 / segments);
        let q = path_point(a, b, (i + 1) as f32 / segments);
        render::triangle(out, p - side, q - side, q + side, INK);
        render::triangle(out, p - side, q + side, p + side, INK);
        render::beam(out, p - side, q - side, 0.045, NAVY);
        render::beam(out, p + side, q + side, 0.045, NAVY);
        let rail_lift = float3 { 0.0, 0.07, 0.0 };
        render::beam(out, p - side + rail_lift, q - side + rail_lift, 0.015, IVORY);
        render::beam(out, p + side + rail_lift, q + side + rail_lift, 0.015, IVORY);
        if i % 2 == 0 {
            let foot = float3 { p.x, world::height(p.x, p.z), p.z };
            render::beam(out, foot, p, 0.06, NAVY);
        }
    }
}

fn conveyor_arrows(out: ft::Vertex[>..]&, a: float3, b: float3, seconds: f32) {
    let delta = b - a;
    let distance = length(delta);
    if distance < 0.3 || distance > 64.0 {
        return;
    }
    let side = normalize(cross(delta, float3 { 0.0, 1.0, 0.0 })) * ft::splat(0.25);
    let direction = normalize(float3 { delta.x, 0.0, delta.z });
    let arrows = max(1, floor(distance / 1.2) as i64);
    for i in arrows {
        let t: f32 = (i * 1.2 + (seconds * 0.9) % 1.2) / distance;
        if t >= 1.0 {
            continue;
        }
        let p = path_point(a, b, t) + float3 { 0.0, 0.035, 0.0 };
        let tip = p + direction * ft::splat(0.2);
        let back = p - direction * ft::splat(0.12);
        let wing = side * ft::splat(0.65);
        render::triangle(out, tip, back + wing, back - wing, ORANGE);
    }
}

// The complete builder remains useful to isolated geometry tests and tools.
fn conveyor(out: ft::Vertex[>..]&, a: float3, b: float3, seconds: f32) {
    conveyor_structure(out, a, b);
    conveyor_arrows(out, a, b, seconds);
}

fn logistics_topology_matches() -> bool {
    var index: i64 = 0;
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || !sim::building(e.kind) {
            continue;
        }
        if index >= logistics_buildings.len {
            return false;
        }
        let previous = logistics_buildings[index];
        if !ecs::same(previous.handle, sim::handle(i))
            || previous.kind != e.kind
            || previous.pos != e.pos
            || previous.link_count != e.links.len
        {
            return false;
        }
        for j in e.links.len {
            if !ecs::same(logistics_links[previous.first_link + j], e.links[j]) {
                return false;
            }
        }
        index++;
    }
    index == logistics_buildings.len
}

fn remember_logistics_topology() {
    logistics_buildings.clear();
    logistics_links.clear();
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || !sim::building(e.kind) {
            continue;
        }
        logistics_buildings.push(LogisticsBuilding {
            handle: sim::handle(i),
            kind: e.kind,
            pos: e.pos,
            first_link: logistics_links.len,
            link_count: e.links.len,
        });
        logistics_links.append(e.links);
    }
}

fn rebuild_wire_spans() {
    wire_spans.clear();
    for owner in logistics_buildings {
        if owner.kind < 2 || owner.kind > 8 || owner.kind == 4 || owner.kind == 7 {
            continue;
        }
        // Stable slot order and a strict comparison preserve the original
        // nearest-source tie breaking exactly.
        var nearest: i64 = -1;
        var distance: f32 = 14.0;
        for j in logistics_buildings.len {
            let source = logistics_buildings[j];
            if ecs::same(owner.handle, source.handle)
                || (source.kind != 1 && source.kind != 4 && source.kind != 5)
            {
                continue;
            }
            let d = length(source.pos - owner.pos);
            if d < distance {
                nearest = j;
                distance = d;
            }
        }
        if nearest < 0 {
            continue;
        }
        let source = logistics_buildings[nearest];
        let a = source.pos + float3 { 0.0, if source.kind == 5 { 4.25 } else { 2.2 }, 0.0 };
        let b = owner.pos + float3 { 0.0, if owner.kind == 5 { 4.25 } else { 1.7 }, 0.0 };
        wire_spans.push(WireSpan { owner.handle, source.handle, a, b, distance });
    }
    wire_rebuilds++;
}

fn logistics_terrain_matches() -> bool {
    if logistics_seed != world::seed || logistics_edits.len != world::edits.len {
        return false;
    }
    for i in world::edits.len {
        let previous = logistics_edits[i];
        let current = world::edits[i];
        if previous.gx != current.gx || previous.gz != current.gz || previous.delta != current.delta {
            return false;
        }
    }
    true
}

fn logistics_visibility_matches() -> bool {
    if logistics_visible.len != logistics_buildings.len {
        return false;
    }
    for i in logistics_buildings.len {
        let visible = length(logistics_buildings[i].pos - visibility_center()) <= visible_distance;
        if logistics_visible[i] != visible {
            return false;
        }
    }
    true
}

fn build_rail_geometry() -> ft::Vertex[>..] {
    var vertices: ft::Vertex[>..] = [];
    for i in logistics_buildings.len {
        if !logistics_visible[i] {
            continue;
        }
        let source = logistics_buildings[i];
        for j in source.link_count {
            let link = logistics_links[source.first_link + j];
            if !ecs::valid(link) || !sim::building(ecs::entities[link.slot].kind) {
                continue;
            }
            conveyor_structure(vertices, source.pos, ecs::entities[link.slot].pos);
        }
    }
    vertices
}

fn release_rail_mesh() {
    if rail_mesh.vertices.id != 0 {
        render::release(rail_mesh);
        rail_releases++;
        rail_live_meshes--;
    }
    rail_mesh = render::Mesh { .. };
    rail_buffer_bytes = 0;
}

fn sync_logistics() {
    let started = clock();
    let topology_changed = !logistics_ready || !logistics_topology_matches();
    if topology_changed {
        remember_logistics_topology();
        rebuild_wire_spans();
    }
    let terrain_changed = !logistics_ready || !logistics_terrain_matches();
    let visibility_changed = topology_changed || !logistics_visibility_matches();
    if topology_changed || terrain_changed || visibility_changed {
        logistics_visible.clear();
        for building in logistics_buildings {
            logistics_visible.push(length(building.pos - visibility_center()) <= visible_distance);
        }
        logistics_edits.clear();
        logistics_edits.append(world::edits);
        logistics_seed = world::seed;

        // Upload from scope-local scratch, then retire the previous GPU handle.
        // At most the old and replacement meshes coexist during this swap.
        let vertices = build_rail_geometry();
        let replacement_bytes = bytes_of(vertices[..]).len;
        let replacement = render::upload(vertices);
        if replacement.vertices.id != 0 {
            rail_uploads++;
            rail_live_meshes++;
            rail_peak_meshes = max(rail_peak_meshes, rail_live_meshes);
        }
        release_rail_mesh();
        rail_mesh = replacement;
        if replacement.vertices.id != 0 {
            rail_buffer_bytes = replacement_bytes;
        }
        rail_rebuilds++;
        logistics_ready = true;
    }
    logistics_cache_ms = (clock() - started) * 1000.0;
}

fn power_wires(out: ft::Vertex[>..]&) {
    for span in wire_spans {
        if !ecs::valid(span.owner) || !ecs::valid(span.source) {
            continue;
        }
        let e .= ecs::entities[span.owner.slot];
        if length(e.pos - visibility_center()) > 100.0 {
            continue;
        }
        let color = if e.powered { float4 { 0.25, 0.64, 0.66, 1.2 } } else { SLATE };
        var prev = span.a;
        for segment in 6 {
            let t: f32 = (segment + 1) / 6.0;
            let sag = float3 { 0.0, sin(t * PI) * span.distance * 0.08, 0.0 };
            let p = span.a * ft::splat(1.0 - t) + span.b * ft::splat(t) - sag;
            render::beam(out, prev, p, 0.018, color);
            prev = p;
        }
    }
}

fn burst(p: float3, color: float4) {
    for i in 8 {
        let h = world::hash(next_particle, i, world::seed + 878);
        let life: f32 = 0.4 + (h & 255) / 640.0;
        let velocity = float3 {
            ((h & 255) / 127.5 - 1.0) * 2.0,
            1.5 + ((h >> 8) & 255) / 100.0,
            (((h >> 16) & 255) / 127.5 - 1.0) * 2.0,
        };
        particles[next_particle] = Particle { p, velocity, color, life, life };
        next_particle = (next_particle + 1) % 256;
    }
}

fn player_model(out: ft::Vertex[>..]&, seconds: f32) {
    let p = sim::player;
    let yaw: f32 = player_yaw;
    let step: f32 = if player_moving { sin(seconds * 10.0) * 0.18 } else { 0.0 };
    for i in 2 {
        let sign: f32 = if i == 0 { -1.0 } else { 1.0 };
        let ankle = shifted(p, sign * 0.18, 0.12, step * sign, yaw);
        let hip = shifted(p, sign * 0.18, 0.8, 0.0, yaw);
        render::beam(out, ankle, hip, 0.11, NAVY);
        let boot = shifted(p, sign * 0.18, 0.12, step * sign - 0.08, yaw);
        render::chamfered_box(out, boot, float3 { 0.28, 0.2, 0.42 }, IVORY, yaw);
        let shoulder = shifted(p, sign * 0.37, 1.25, 0.0, yaw);
        let hand = shifted(p, sign * 0.43, 0.85, -step * sign, yaw);
        render::beam(out, shoulder, hand, 0.09, IVORY);
        render::octahedron(out, shifted(p, sign * 0.38, 1.33, 0.0, yaw), ft::splat(0.26), ORANGE, yaw);
    }
    egg(out, p + float3 { 0.0, 1.05, 0.0 }, float3 { 0.73, 0.83, 0.5 }, IVORY);
    render::chamfered_box(out, shifted(p, 0.0, 1.12, 0.33, yaw), float3 { 0.55, 0.63, 0.35 }, ORANGE, yaw);
    egg(out, p + float3 { 0.0, 1.65, 0.0 }, float3 { 0.62, 0.57, 0.6 }, IVORY);
    render::chamfered_box(out, shifted(p, 0.0, 1.66, -0.25, yaw), float3 { 0.49, 0.27, 0.15 }, INK, yaw);
    render::box(out, shifted(p, 0.0, 1.54, -0.33, yaw), float3 { 0.45, 0.035, 0.035 }, CYAN, yaw);
    render::beam(out, shifted(p, 0.4, 0.88, -0.1, yaw), shifted(p, 0.4, 0.93, -0.56, yaw), 0.07, NAVY);
    render::octahedron(out, shifted(p, 0.4, 0.93, -0.62, yaw), ft::splat(0.16), CYAN, yaw);
}

fn draw(
    eye: float3, target: float3, day: f32, seconds: f32, selected: ecs::Handle,
    ghost_kind: i64, ghost_pos: float3, ghost_valid: bool, shadows: bool,
) {
    var dynamic: ft::Vertex[>..] = [];
    sync_logistics();
    night_strength = 1.0 - clamp(sin(day * TAU) * 2.2 + 0.23, 0.0, 1.0);
    district_night_strength = district_light_fade(day);
    let dt: f32 = clamp(seconds - last_seconds, 0.0, 0.1);
    last_seconds = seconds;
    if showcase::enabled {
        // This district landmark is scenery, so it cannot silently finish the
        // player's separately constructed and powered communications objective.
        district_landmarks(dynamic, seconds);
    }
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || length(e.pos - visibility_center()) > visible_distance {
            continue;
        }
        machine(dynamic, e.kind, e.pos, e.yaw, e.progress, e.powered, seconds, i);
        if e.kind == 7 && e.cargo_count > 0 {
            let cargo = e.pos + float3 { 0.0, 1.7 + sin(seconds * 4.0 + i * 1.7) * 0.07, 0.0 };
            let cargo_color = if e.cargo_kind == 1 { GLACITE } else { FERRITE };
            render::octahedron(dynamic, cargo, ft::splat(0.4), cargo_color, seconds);
        }
        // Robot links hold AI destinations; only building-to-building links
        // describe visible conveyors. Rendering every graph edge made stress
        // collections and robot destinations sprout unintended belts.
        if sim::building(e.kind) {
            for link in e.links {
                if !ecs::valid(link) || !sim::building(ecs::entities[link.slot].kind) {
                    continue;
                }
                conveyor_arrows(dynamic, e.pos, ecs::entities[link.slot].pos, seconds);
            }
        }
    }
    power_wires(dynamic);
    for packet in sim::packets {
        if !packet.alive || !ecs::valid(packet.source) || !ecs::valid(packet.dest) {
            continue;
        }
        let a = ecs::entities[packet.source.slot].pos;
        let b = ecs::entities[packet.dest.slot].pos;
        let p = path_point(a, b, packet.t) + float3 { 0.0, 0.20, 0.0 };
        if length(p - visibility_center()) > visible_distance {
            continue;
        }
        let color = if packet.kind == 1 { GLACITE } else if packet.kind >= 2 { BONE } else { FERRITE };
        if packet.kind >= 2 {
            render::chamfered_box(dynamic, p, float3 { 0.35, 0.15, 0.22 }, color, 0.0);
        } else {
            render::octahedron(dynamic, p, ft::splat(0.30), color, seconds);
        }
    }
    let displacement = sim::player - player_previous;
    player_moving = displacement.x * displacement.x + displacement.z * displacement.z > 0.000005;
    if player_moving {
        player_yaw = atan2(-displacement.x, -displacement.z);
    }
    player_previous = sim::player;
    player_model(dynamic, seconds);
    if ecs::valid(selected) {
        let p = ecs::entities[selected.slot].pos + float3 { 0.0, 0.23, 0.0 };
        ring(dynamic, p, 1.65, ORANGE, 0.035);
    }
    if ecs::valid(inspector_target) {
        let target = ecs::entities[inspector_target.slot].pos;
        let pulse: f32 = 1.7 + sin(seconds * 4.0) * 0.12;
        ring(dynamic, target + float3 { 0.0, 0.26, 0.0 }, pulse, CYAN, 0.05);
    }
    if ghost_kind > 0 {
        var ghost: ft::Vertex[>..] = [];
        machine(ghost, ghost_kind, ghost_pos, 0.0, 1.0, true, seconds, -1);
        let brightness: f32 = 0.65 + sin(seconds * 4.0) * 0.1;
        let tint = if ghost_valid {
            float4 { 0.373 * brightness, 0.949 * brightness, 0.878 * brightness, 1.6 }
        } else {
            float4 { brightness, 0.302 * brightness, 0.369 * brightness, 1.5 }
        };
        for vertex in ghost {
            dynamic.push(ft::Vertex { vertex.pos, vertex.normal, tint });
        }
        ring(dynamic, ghost_pos + float3 { 0.0, 0.2, 0.0 }, 1.7, tint, 0.04);
    }
    for i in 256 {
        let p .= particles[i];
        if p.life <= 0.0 {
            continue;
        }
        p.life -= dt;
        p.velocity.y -= dt * 6.0;
        p.pos += p.velocity * ft::splat(dt);
        let size: f32 = 0.06 + 0.07 * max(0.0, p.life / p.initial);
        render::octahedron(dynamic, p.pos, ft::splat(size), p.color, seconds * 3.0 + i);
    }
    var all_meshes: render::Mesh[>..] = [];
    all_meshes.append(cached);
    all_meshes.push(grass_mesh);
    all_meshes.push(rail_mesh);
    for far_mesh in horizon::meshes() {
        var distant = far_mesh;
        distant.casts_shadow = false;
        all_meshes.push(distant);
    }
    render::horizon_center = if horizon::ready { horizon::active_center } else { visibility_center() };
    render::draw_scene(all_meshes, dynamic, eye, target, day, seconds, shadows);
}

fn shutdown() {
    release_rail_mesh();
    logistics_buildings.clear();
    logistics_links.clear();
    logistics_visible.clear();
    logistics_edits.clear();
    wire_spans.clear();
    logistics_ready = false;
    render::release(grass_mesh);
    grass_mesh = render::Mesh { .. };
    for i in world::MAX_CHUNKS {
        if cached[i].vertices.id != 0 {
            render::release(cached[i]);
            cached[i] = render::Mesh { .. };
        }
        revisions[i] = 0;
    }
    render::shutdown();
}
