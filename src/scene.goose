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
var cached: render::Mesh[81];
var revisions: i64[81];
var terrain_vertices: i64 = 0;
var mesh_count: i64 = 0;
var last_seconds: f32 = 0.0;
var player_previous: float3;
var player_yaw: f32 = 0.0;
var player_moving: bool = false;
var night_strength: f32 = 0.0;

struct Particle { pos: float3, velocity: float3, color: float4, life: f32, initial: f32 }
var particles: Particle[256];
var next_particle: i64 = 0;

fn frustum(
    out: ft::Vertex[>..]&, p: float3, bottom_radius: f32, top_radius: f32,
    height: f32, color: float4, sides: i64
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
            p.y * sin(pitch) + p.z * cos(pitch)
        };
        let pitched_normal = float3 {
            n.x,
            n.y * cos(pitch) - n.z * sin(pitch),
            n.y * sin(pitch) + n.z * cos(pitch)
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
            p + float3 { cos(b) * radius, 0.0, sin(b) * radius }, thickness, color
        );
    }
}

fn clear_of_machines(x: f32, z: f32) -> bool {
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

fn decorate(out: ft::Vertex[>..]&, slot: i64) {
    let c .= world::chunks[slot];
    for i in 32 {
        // Four deterministic grove anchors with eight members each. A broad
        // noise mask leaves open land between groves rather than uniform trees.
        let anchor = world::hash(c.cx * 51 + i / 8, c.cz * 37 - (i / 8) * 5, world::seed + 909);
        let h = world::hash(c.cx * 113 + i, c.cz * 127 - i * 5, world::seed + 1819);
        let ax: f32 = c.cx * 32.0 + 8.0 + (anchor & 65535) / 65535.0 * 16.0;
        let az: f32 = c.cz * 32.0 + 8.0 + ((anchor >> 16) & 65535) / 65535.0 * 16.0;
        if world::noise(ax / 38.0, az / 38.0, world::seed + 1547) < 0.54 {
            continue;
        }
        let x: f32 = ax + ((h & 65535) / 65535.0 - 0.5) * 14.0;
        let z: f32 = az + (((h >> 16) & 65535) / 65535.0 - 0.5) * 14.0;
        if !clear_of_machines(x, z) {
            continue;
        }
        let y = world::height(x, z);
        let p = float3 { x, y, z };
        let biome = world::biome(x, z);
        let scale: f32 = 0.6 + ((h >> 8) & 255) / 255.0 * 0.8;
        if i % 5 == 0 {
            let boulder_size = float3 { 1.7 * scale, 1.0 * scale, 1.4 * scale };
            let boulder_color = ft::rgb(0.337, 0.376, 0.478);
            let boulder = p + float3 { 0.0, 0.45 * scale, 0.0 };
            render::octahedron(out, boulder, boulder_size, boulder_color, i * 0.7);
            continue;
        }
        if biome == 1 {
            if i % 3 != 0 {
                continue;
            }
            if i % 2 == 0 {
                for j in 3 {
                    let layer_color = if j == 1 {
                        ft::rgb(0.788, 0.451, 0.239)
                    } else {
                        ft::rgb(0.941, 0.788, 0.541)
                    };
                    frustum(
                        out,
                        p + float3 { 0.0, (j + 0.5) * 1.4 * scale, 0.0 },
                        (0.9 - j * 0.15) * scale,
                        (0.72 - j * 0.15) * scale,
                        1.4 * scale,
                        layer_color,
                        6
                    );
                }
            } else {
                let trunk_color = ft::rgb(0.851, 0.698, 0.361);
                let trunk = p + float3 { 0.0, 0.8 * scale, 0.0 };
                render::cylinder(out, trunk, 0.5 * scale, 1.6 * scale, trunk_color, 6);
                let crown = p + float3 { 0.0, 1.8 * scale, 0.0 };
                render::octahedron(out, crown, ft::splat(0.55 * scale), ORANGE, i * 0.6);
            }
        } else if biome == 2 {
            let height: f32 = 2.7 * scale;
            let stem_color = ft::rgb(0.929, 0.890, 0.961);
            render::cylinder(out, p + float3 { 0.0, height * 0.5, 0.0 }, 0.22 * scale, height, stem_color, 6);
            let gill_color = float4 { 1.0, 0.62, 0.847, 1.25 };
            let gills = p + float3 { 0.0, height, 0.0 };
            frustum(out, gills, 1.8 * scale, 1.35 * scale, 0.22 * scale, gill_color, 8);
            let cap = p + float3 { 0.0, height + 0.48 * scale, 0.0 };
            frustum(out, cap, 1.85 * scale, 0.25 * scale, 0.9 * scale, ft::rgb(0.788, 0.651, 0.941), 8);
            if i % 3 == 0 {
                for j in 3 {
                    let spore = p + float3 { sin(j * 2.1 as f32) * 1.4, 0.22, cos(j * 2.1 as f32) * 1.4 };
                    let spore_color = ft::rgb(0.718, 0.643, 0.902);
                    render::octahedron(out, spore, float3 { 0.65, 0.45, 0.65 }, spore_color, j * 0.7);
                }
            }
        } else {
            let height: f32 = 3.0 * scale;
            render::cylinder(out, p + float3 { 0.0, height * 0.4, 0.0 }, 0.14 * scale, height * 0.8, NAVY, 6);
            let foliage = if i % 3 == 0 {
                ft::rgb(0.180, 0.549, 0.557)
            } else if i % 3 == 1 {
                ft::rgb(0.227, 0.612, 0.525)
            } else {
                ft::rgb(0.165, 0.478, 0.525)
            };
            render::cone(out, p + float3 { 0.0, height * 0.72, 0.0 }, 1.15 * scale, 2.0 * scale, foliage, 6);
            render::cone(out, p + float3 { 0.0, height * 1.0, 0.0 }, 0.85 * scale, 1.8 * scale, foliage, 6);
            let tip = p + float3 { 0.0, height * 1.34, 0.0 };
            render::octahedron(out, tip, ft::splat(0.4 * scale), IVORY, i * 0.7);
        }
    }
    // Small groups of three triangular grass blades break the broad facets.
    for i in 44 {
        let h = world::hash(c.cx * 67 + i, c.cz * 73 - i, world::seed + 231);
        let x: f32 = c.cx * 32.0 + (h & 65535) / 65535.0 * 32.0;
        let z: f32 = c.cz * 32.0 + ((h >> 16) & 65535) / 65535.0 * 32.0;
        if world::biome(x, z) != 0 || !clear_of_machines(x, z) {
            continue;
        }
        let p = float3 { x, world::height(x, z), z };
        for j in 3 {
            let yaw: f32 = j * 2.1 + i;
            let side = float3 { cos(yaw) * 0.11, 0.0, sin(yaw) * 0.11 };
            let blade_tip = p + float3 { cos(yaw) * 0.18, 0.4 + (h & 255) / 1024.0, sin(yaw) * 0.18 };
            render::triangle(out, p - side, blade_tip, p + side, ft::rgb(0.337, 0.757, 0.627));
            out[out.len - 2].color = ft::rgb(0.608, 0.890, 0.769);
        }
    }
}

fn init() {
    render::init();
    last_seconds = sim::elapsed;
    player_previous = sim::player;
}

fn sync(budget: i64) {
    var built: i64 = 0;
    for slot in 81 {
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
    terrain_vertices = 0;
    mesh_count = 0;
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
            a
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
    let fire = if powered { float4 { 1.0, 0.31 + sin(seconds * 4.4) * 0.06, 0.12, 2.6 } } else { INK };
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
                i + seconds * 0.3
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
                local.y * sin(pitch) + local.z * cos(pitch)
            };
            let rotated = render::turn(tilted, panel_yaw);
            let cell_color = ft::rgb(0.141, 0.212, 0.431);
            tilted_box(out, center + rotated, float3 { 0.69, 0.04, 0.75 }, cell_color, panel_yaw, pitch);
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
    id: i64
) {
    if kind == 1 {
        lander(out, p, seconds);
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
}

fn path_point(a: float3, b: float3, t: f32) -> float3 {
    var p = a * ft::splat(1.0 - t) + b * ft::splat(t);
    p.y = max(p.y + 0.65, world::height(p.x, p.z) + 0.55);
    p
}

fn conveyor(out: ft::Vertex[>..]&, a: float3, b: float3, seconds: f32) {
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

fn power_wires(out: ft::Vertex[>..]&) {
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || e.kind < 2 || e.kind > 8 || e.kind == 4 || e.kind == 7 {
            continue;
        }
        if length(e.pos - sim::player) > 100.0 {
            continue;
        }
        var nearest: i64 = -1;
        var distance: f32 = 14.0;
        for j in ecs::entities.len {
            let source .= ecs::entities[j];
            if !source.alive || i == j || (source.kind != 1 && source.kind != 4 && source.kind != 5) {
                continue;
            }
            let d = length(source.pos - e.pos);
            if d < distance {
                nearest = j;
                distance = d;
            }
        }
        if nearest < 0 {
            continue;
        }
        let source .= ecs::entities[nearest];
        let a = source.pos + float3 { 0.0, if source.kind == 5 { 4.25 } else { 2.2 }, 0.0 };
        let b = e.pos + float3 { 0.0, if e.kind == 5 { 4.25 } else { 1.7 }, 0.0 };
        let color = if e.powered { float4 { 0.25, 0.64, 0.66, 1.2 } } else { SLATE };
        var prev = a;
        for segment in 6 {
            let t: f32 = (segment + 1) / 6.0;
            let sag = float3 { 0.0, sin(t * PI) * distance * 0.08, 0.0 };
            let p = a * ft::splat(1.0 - t) + b * ft::splat(t) - sag;
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
            (((h >> 16) & 255) / 127.5 - 1.0) * 2.0
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
    ghost_kind: i64, ghost_pos: float3, ghost_valid: bool, shadows: bool
) {
    var dynamic: ft::Vertex[>..] = [];
    night_strength = 1.0 - clamp(sin(day * TAU) * 2.2 + 0.23, 0.0, 1.0);
    let dt: f32 = clamp(seconds - last_seconds, 0.0, 0.1);
    last_seconds = seconds;
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || length(e.pos - sim::player) > 120.0 {
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
                conveyor(dynamic, e.pos, ecs::entities[link.slot].pos, seconds);
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
        if length(p - sim::player) > 120.0 {
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
    render::draw_scene(cached, dynamic, eye, target, day, seconds, shadows);
}

fn shutdown() {
    for i in 81 {
        if cached[i].vertices.id != 0 {
            render::release(cached[i]);
            cached[i] = render::Mesh { .. };
        }
        revisions[i] = 0;
    }
    render::shutdown();
}
