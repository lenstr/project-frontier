// Deterministic colony planning shared by terrain, simulation and scenery.
namespace estate;
import std;
import math;
import vec;

let CENTER_X: f32 = -123.0;
let CENTER_Z: f32 = -102.0;
let RADIUS: f32 = 312.0;
let RING_RADIUS: f32 = 169.0;
let RING_NODES = 96;
let SPOKE_STEPS = 26;
let ROAD_NODES = RING_NODES + 6 * SPOKE_STEPS;
let RADII: const f32[11] = [100.0, 116.0, 132.0, 148.0, 190.0, 206.0, 222.0, 238.0, 254.0, 270.0, 286.0];
let TAU: f32 = 6.2831853;

struct Cell {
    district: i64,
    ring: i64,
    slot: i64,
    radius: f32,
    angle: f32,
}

fn point(radius: f32, angle: f32) -> float3 {
    float3 { CENTER_X + cos(angle) * radius, 1.8, CENTER_Z + sin(angle) * radius }
}

fn contains(x: f32, z: f32, margin: f32) -> bool {
    let dx = x - CENTER_X;
    let dz = z - CENTER_Z;
    dx * dx + dz * dz <= (RADIUS + margin) * (RADIUS + margin)
}

fn plans() -> Cell[>..] {
    var result: Cell[>..] = [];
    // Grow outward in layers; sectors deliberately have different outlines.
    for ring in RADII.len {
        let radius = RADII[ring];
        let slots = floor(radius * (50.0 * TAU / 360.0) / 16.0) as i64;
        for district in 6 {
            for slot in slots {
                // A broad open plaza, staggered freight yards, and a gate notch.
                if district == 1 && ring < 2 {
                    continue;
                }
                if district == 3 && ring >= 4 && slot % 4 == 2 {
                    continue;
                }
                if district == 5 && ring >= 9 && slot < 3 {
                    continue;
                }
                let twist: f32 = if district == 2 { ring * 0.25 } else { 0.0 };
                let degrees: f32 = district * 60.0 + 5.0 + (slot + 0.5) * 50.0 / slots + twist;
                result.push(Cell { district, ring, slot, radius, degrees * TAU / 360.0 });
            }
        }
    }
    result
}

fn road_point(index: i64) -> float3 {
    if index < RING_NODES {
        return point(RING_RADIUS, index * TAU / RING_NODES);
    }
    let spoke = (index - RING_NODES) / SPOKE_STEPS;
    let step = (index - RING_NODES) % SPOKE_STEPS;
    point((step + 1) * 12.0, spoke * TAU / 6.0)
}

fn road_yaw(index: i64) -> f32 {
    let angle: f32 = if index < RING_NODES {
        index * TAU / RING_NODES
    } else {
        (index - RING_NODES) / SPOKE_STEPS * TAU / 6.0
    };
    if index < RING_NODES { -angle } else { TAU * 0.25 - angle }
}
