// Visual-only grove representations. The same hashes place near and distant plants.
namespace flora;
import std;
import vec;
import math;
import .world;
import .render;
import .types;

let DISTANCE: f32 = 6144.0;
var last_vertices: i64 = 0;
var last_objects: i64 = 0;

struct Grove {
    hash: u32,
    x: f32,
    z: f32,
    biome: i64,
    members: i64,
}

struct Plant { x: f32, z: f32, size: f32, hash: u32 }

fn grove(cx: i64, cz: i64, index: i64, density: f32) -> Grove {
    let anchor = world::hash(cx * 51 + index, cz * 37 - index * 5, world::seed + 909);
    let x: f32 = cx * 32.0 + 6.0 + (anchor & 65535) / 65535.0 * 20.0;
    let z: f32 = cz * 32.0 + 6.0 + ((anchor >> 16) & 65535) / 65535.0 * 20.0;
    Grove { anchor, x, z, world::biome(x, z), max(3, ((6 + anchor % 11) * density) as! i64) }
}

fn member(cx: i64, cz: i64, grove: i64, index: i64, group: Grove) -> Plant {
    let h = world::hash(cx * 113 + grove * 101 + index, cz * 127 - index * 5, world::seed + 1819);
    let x: f32 = group.x + ((h & 65535) / 65535.0 - 0.5) * 15.0;
    let z: f32 = group.z + (((h >> 16) & 65535) / 65535.0 - 0.5) * 15.0;
    let size: f32 = if index == 0 {
        2.2 + ((h >> 8) & 255) / 255.0 * 0.8
    } else {
        0.6 + ((h >> 8) & 255) / 255.0 * 0.8
    };
    Plant { x, z, size, h }
}

fn cleared(x: f32, z: f32, emergent: bool) -> bool {
    let dx = x + 123.0;
    let dz = z + 102.0;
    let u = dx * 0.64 - dz * 0.77;
    let v = -dx * 0.77 - dz * 0.64;
    if abs(u) <= 128.0 && abs(v) <= 120.0 {
        return true;
    }
    let along = -0.77 * x - 0.64 * z;
    let across = 0.64 * x - 0.77 * z;
    if (abs(across) < 12.0 && along > 0.0 && along < 100.0)
        || (emergent && abs(across) <= 20.0 && along >= 0.0 && along <= 480.0)
    {
        return true;
    }
    x * x + z * z < 144.0
}

fn foliage_color(biome: i64, variant: u32) -> float4 {
    if biome == 1 {
        return ft::rgb(0.788, 0.451, 0.239);
    }
    if biome == 2 {
        return ft::rgb(0.788, 0.651, 0.941);
    }
    if variant % 3 == 0 {
        return ft::rgb(0.180, 0.549, 0.557);
    }
    if variant % 3 == 1 {
        return ft::rgb(0.227, 0.612, 0.525);
    }
    ft::rgb(0.165, 0.478, 0.525)
}

fn low_plant(out: ft::Vertex[>..]&, plant: Plant, biome: i64) {
    let p = float3 { plant.x, world::base_height(plant.x, plant.z) - 0.15, plant.z };
    let size = plant.size;
    let color = foliage_color(biome, plant.hash);
    if biome == 1 {
        render::frustum(out, p + float3 { 0.0, 2.0 * size, 0.0 }, 0.8 * size, 0.4 * size, 4.0 * size, color, 4);
    } else if biome == 2 {
        render::cone(out, p + float3 { 0.0, 2.0 * size, 0.0 }, 0.28 * size, 4.0 * size, color, 4);
        render::cone(out, p + float3 { 0.0, 4.2 * size, 0.0 }, 2.0 * size, 1.2 * size, color, 5);
    } else if plant.hash % 4 == 2 {
        render::cone(out, p + float3 { 0.0, 2.0 * size, 0.0 }, 0.18 * size, 4.0 * size, color, 4);
        render::cone(out, p + float3 { 0.0, 4.0 * size, 0.0 }, 1.8 * size, 0.8 * size, color, 5);
    } else {
        render::cone(out, p + float3 { 0.0, 3.2 * size, 0.0 }, 1.2 * size, 4.8 * size, color, 4);
    }
}

fn canopy(out: ft::Vertex[>..]&, group: Grove, width: f32) {
    let p = float3 { group.x, world::base_height(group.x, group.z) - 0.15, group.z };
    let size: f32 = 2.2 + ((group.hash >> 8) & 255) / 255.0 * 0.8;
    let height: f32 = if group.biome == 2 { 4.5 * size } else { 4.8 * size };
    let color = foliage_color(group.biome, group.hash);
    render::cone(out, p + float3 { 0.0, height * 0.5, 0.0 }, width, height, color, 5);
    last_objects++;
}

fn append_band(
    out: ft::Vertex[>..]&, center: float3, inner: f32, outer: f32,
    start: f32, end: f32, stride: i64, density: f32, individuals: bool,
) {
    let lo = max(inner, start);
    let hi = min(outer, end);
    if hi <= lo {
        return;
    }
    let step: f32 = stride * 32.0;
    let first_x = floor((center.x - hi) / step) as i64;
    let first_z = floor((center.z - hi) / step) as i64;
    let diameter = ceil(hi * 2.0 / step) as i64 + 1;
    for zi in diameter {
        for xi in diameter {
            let cx = (first_x + xi) * stride;
            let cz = (first_z + zi) * stride;
            let groups: i64 = if individuals { 4 } else { 1 };
            for index in groups {
                let group = grove(cx, cz, index, density);
                let distance = max(abs(group.x - center.x), abs(group.z - center.z));
                if distance < lo || distance >= hi || world::grove_mask(group.x, group.z) < 0.42
                    || cleared(group.x, group.z, false)
                {
                    continue;
                }
                if individuals {
                    for i in group.members {
                        let plant = member(cx, cz, index, i, group);
                        if !cleared(plant.x, plant.z, i == 0) && (i == 0 || i % 7 != 0) {
                            low_plant(out, plant, group.biome);
                            last_objects++;
                        }
                    }
                } else {
                    canopy(out, group, if stride == 1 { 11.0 } else { 22.0 });
                }
            }
        }
    }
}

fn append(out: ft::Vertex[>..]&, center: float3, inner: f32, outer: f32, density: f32) {
    let before = out.len;
    last_objects = 0;
    append_band(out, center, inner, outer, 0.0, 896.0, 1, density, true);
    append_band(out, center, inner, outer, 896.0, 2560.0, 1, density, false);
    append_band(out, center, inner, outer, 2560.0, DISTANCE, 2, density, false);
    // Negative alpha tags visual-only foliage; the shader restores its material
    // alpha and masks it out where full near-field plants already exist.
    for i in before..out.len {
        out[i].color.w = -out[i].color.w;
    }
    last_vertices = out.len - before;
}
