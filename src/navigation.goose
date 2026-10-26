// Bounded A* over the real edited terrain. Scratch dies with each search;
// the resulting route belongs to the robot's independently growing queue.
namespace nav;
import std;
import math;
import os;
import vec;
import .entities;
import .world;

let GRID = 41;
let COUNT = GRID * GRID;
let STEP: f32 = 2.0;
var path_calls: i64 = 0;
var path_failed: i64 = 0;
var path_ms: f64 = 0.0;
var expanded: i64 = 0;

fn distance(a: float3, b: float3) -> f32 {
    let x = a.x - b.x;
    let z = a.z - b.z;
    sqrt(x * x + z * z)
}

fn obstacle(x: f32, z: f32, robot: ecs::Handle, goal: ecs::Handle) -> bool {
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || e.kind < 1 || e.kind > 9 || e.kind == 7 || e.kind == 5 {
            continue;
        }
        if i == robot.slot || (i == goal.slot && e.generation == goal.generation) {
            continue;
        }
        let r: f32 = if e.kind == 1 { 2.5 } else { 1.35 };
        let dx = e.pos.x - x;
        let dz = e.pos.z - z;
        if dx * dx + dz * dz < r * r {
            return true;
        }
    }
    false
}

fn rasterize(ox: i64, oz: i64, robot: ecs::Handle, goal: ecs::Handle, blocked: bool[:]) {
    assert(blocked.len == COUNT);
    // Visit buildings once, then only the few grid points inside each small
    // footprint. The exact circle test matches obstacle(), including edges.
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || e.kind < 1 || e.kind > 9 || e.kind == 7 || e.kind == 5 {
            continue;
        }
        if i == robot.slot || (i == goal.slot && e.generation == goal.generation) {
            continue;
        }
        let radius: f32 = if e.kind == 1 { 2.5 } else { 1.35 };
        let left = max(0, (floor((e.pos.x - radius) / STEP) as i64) - ox);
        let right = min(GRID - 1, (ceil((e.pos.x + radius) / STEP) as i64) - ox);
        let front = max(0, (floor((e.pos.z - radius) / STEP) as i64) - oz);
        let back = min(GRID - 1, (ceil((e.pos.z + radius) / STEP) as i64) - oz);
        if left > right || front > back {
            continue;
        }
        for z in front..back + 1 {
            for x in left..right + 1 {
                let dx = e.pos.x - (ox + x) * STEP;
                let dz = e.pos.z - (oz + z) * STEP;
                if dx * dx + dz * dz < radius * radius {
                    blocked[z * GRID + x] = true;
                }
            }
        }
    }
}

fn plan(robot: ecs::Handle, destination: float3, goal: ecs::Handle) -> bool {
    if !ecs::valid(robot) {
        return false;
    }
    let start_time = clock();
    path_calls++;
    let e .= ecs::entities[robot.slot];
    e.queue = ecs::queues.realloc_slice(e.queue, 0);
    let ox = (floor(e.pos.x / STEP) as i64) - GRID / 2;
    let oz = (floor(e.pos.z / STEP) as i64) - GRID / 2;
    let tx = (floor(destination.x / STEP + 0.5) as i64) - ox;
    let tz = (floor(destination.z / STEP + 0.5) as i64) - oz;
    if tx < 0 || tz < 0 || tx >= GRID || tz >= GRID {
        path_failed++;
        path_ms += (clock() - start_time) * 1000.0;
        return false;
    }
    let start = (GRID / 2) * GRID + GRID / 2;
    let end = tz * GRID + tx;
    var height: f32[COUNT];
    var blocked: bool[COUNT] = [false; COUNT];
    var closed: bool[COUNT] = [false; COUNT];
    var open: bool[COUNT] = [false; COUNT];
    var costs: f32[COUNT] = [1000000.0; COUNT];
    var parent: i64[COUNT] = [-1; COUNT];
    for z in GRID {
        for x in GRID {
            let i = z * GRID + x;
            let wx: f32 = (ox + x) * STEP;
            let wz: f32 = (oz + z) * STEP;
            height[i] = world::height(wx, wz);
        }
    }
    rasterize(ox, oz, robot, goal, blocked);
    blocked[start] = false;
    blocked[end] = false;
    open[start] = true;
    costs[start] = 0.0;
    var found = false;
    var reached = end;
    for iteration in 900 {
        var current: i64 = -1;
        var best: f32 = 1000000.0;
        for i in COUNT {
            if !open[i] {
                continue;
            }
            let dx: f32 = i % GRID - tx;
            let dz: f32 = i / GRID - tz;
            let score = costs[i] + sqrt(dx * dx + dz * dz);
            if score < best {
                best = score;
                current = i;
            }
        }
        if current < 0 {
            break;
        }
        let goal_dx: f32 = (ox + current % GRID) * STEP - destination.x;
        let goal_dz: f32 = (oz + current / GRID) * STEP - destination.z;
        if current == end || goal_dx * goal_dx + goal_dz * goal_dz <= 5.76 {
            found = true;
            reached = current;
            break;
        }
        open[current] = false;
        closed[current] = true;
        expanded++;
        let cx = current % GRID;
        let cz = current / GRID;
        for dz in -1..2 {
            for dx in -1..2 {
                if dx == 0 && dz == 0 {
                    continue;
                }
                let x = cx + dx;
                let z = cz + dz;
                if x < 0 || z < 0 || x >= GRID || z >= GRID {
                    continue;
                }
                let next = z * GRID + x;
                if closed[next] || blocked[next] {
                    continue;
                }
                // Diagonals may not cut through a corner of a building.
                if dx != 0 && dz != 0 && (blocked[cz * GRID + x] || blocked[z * GRID + cx]) {
                    continue;
                }
                let slope = abs(height[next] - height[current]);
                if slope > 1.8 {
                    continue;
                }
                let step: f32 = if dx == 0 || dz == 0 { 1.0 } else { 1.414214 };
                let candidate = costs[current] + step + slope * 0.4;
                if candidate < costs[next] {
                    costs[next] = candidate;
                    parent[next] = current;
                    open[next] = true;
                }
            }
        }
    }
    if found {
        var reverse: i64[>..<] = [];
        var cursor = reached;
        while cursor != start && cursor >= 0 && reverse.len < COUNT {
            reverse.push(cursor);
            cursor = parent[cursor];
        }
        if cursor != start {
            found = false;
        } else {
            e.queue = ecs::queues.realloc_slice(e.queue, reverse.len);
            for i in reverse.len {
                let cell = reverse[reverse.len - i - 1];
                e.queue[i] = ecs::Item {
                    kind: ((ox + cell % GRID) * STEP * 100.0) as! i64,
                    count: ((oz + cell / GRID) * STEP * 100.0) as! i64 };
            }
        }
    }
    if !found {
        path_failed++;
    }
    path_ms += (clock() - start_time) * 1000.0;
    found
}

fn walk(robot: ecs::Handle, dt: f32, goal: ecs::Handle) {
    if !ecs::valid(robot) {
        return;
    }
    let e .= ecs::entities[robot.slot];
    if e.queue.len == 0 {
        return;
    }
    let x: f32 = e.queue[0].kind / 100.0;
    let z: f32 = e.queue[0].count / 100.0;
    let dx = x - e.pos.x;
    let dz = z - e.pos.z;
    let length = sqrt(dx * dx + dz * dz);
    if length < 0.15 {
        for i in 0..e.queue.len - 1 {
            e.queue[i] = e.queue[i + 1];
        }
        e.queue = ecs::queues.realloc_slice(e.queue, e.queue.len - 1);
        return;
    }
    let step = min(length, 4.4 * dt);
    let nx = e.pos.x + dx / length * step;
    let nz = e.pos.z + dz / length * step;
    let ny = world::height(nx, nz);
    if obstacle(nx, nz, robot, goal) || abs(ny - e.pos.y) > 0.9 {
        e.queue = ecs::queues.realloc_slice(e.queue, 0);
        e.timer = 0.4;
        return;
    }
    e.pos = float3 { nx, ny, nz };
    e.yaw = atan2(dx, dz);
}
