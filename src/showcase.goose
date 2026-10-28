// Explicit developer workload, built from the same machines and simulation
// as player construction. Inputs are finite and injected only on construction;
// nothing is manufactured by a per-frame showcase update.
namespace showcase;
import std;
import math;
import os;
import vec;
import .entities;
import .sim;
import .world;
import .colony_layout;

let MAX_LOAD = 12000;
let SPINE_NODES = 8;
let CELL_PARTS = 20;
let ROAD_START = SPINE_NODES + CELL_PARTS;
let ROAD_END = ROAD_START + estate::ROAD_NODES;

var cells: estate::Cell[>..<] = [];
let ORE_FEED = 4096;
let CRYSTAL_FEED = 2048;
let FORWARD_X: f32 = -0.77;
let FORWARD_Z: f32 = -0.64;

var enabled = false;
var load: i64 = 0;
var created: i64 = 0;
var removed: i64 = 0;
var build_ms: f64 = 0.0;
var owned: ecs::Handle[>..<] = [];
var hub: ecs::Handle;
var tower_position: float3;
// Removed cargo stays here until reused or explicitly flushed for saving.
// This avoids flooding the player's inventory whenever a slider is reduced.
var escrow: i64[5];
var injected: i64[5];

fn position(u: f32, v: f32) -> float3 {
    let x = -123.0 + 0.64 * u - 0.77 * v;
    let z = -102.0 - 0.77 * u - 0.64 * v;
    sim::ground(x, z)
}

fn owns(h: ecs::Handle) -> bool {
    if !ecs::valid(h) {
        return false;
    }
    for candidate in owned {
        if ecs::same(candidate, h) {
            return true;
        }
    }
    false
}

fn active_count() -> i64 {
    var count: i64 = 0;
    for h in owned {
        if ecs::valid(h) {
            count++;
        }
    }
    count
}

fn at(index: i64) -> ecs::Handle {
    if index >= 0 && index < owned.len && ecs::valid(owned[index]) {
        return owned[index];
    }
    ecs::Handle {}
}

fn cell_index(cell: i64, part: i64) -> i64 {
    if cell == 0 { SPINE_NODES + part } else { ROAD_END + (cell - 1) * CELL_PARTS + part }
}

fn cell_entity(cell: i64, part: i64) -> ecs::Handle {
    at(cell_index(cell, part))
}

fn part_kind(part: i64) -> i64 {
    if part == 7 || part == 13 || part == 17 || part == 19 {
        return sim::ROBOT;
    }
    if part == 0 || part == 5 || part == 10 || part == 14 || part == 16 || part == 18 {
        return sim::SOLAR;
    }
    if part == 2 || part == 8 {
        return sim::SMELTER;
    }
    if part == 3 || part == 9 {
        return sim::ASSEMBLER;
    }
    if part == 11 {
        return sim::RELAY;
    }
    sim::STORAGE
}

fn cell_count() -> i64 {
    if owned.len <= SPINE_NODES {
        return 0;
    }
    if owned.len <= ROAD_END {
        return 1;
    }
    1 + (owned.len - ROAD_END + CELL_PARTS - 1) / CELL_PARTS
}

fn road(index: i64) -> ecs::Handle {
    at(ROAD_START + index)
}

fn cell_for_index(index: i64) -> i64 {
    if index < ROAD_START { 0 } else { 1 + (index - ROAD_END) / CELL_PARTS }
}

fn part_for_index(index: i64) -> i64 {
    if index < ROAD_START { index - SPINE_NODES } else { (index - ROAD_END) % CELL_PARTS }
}

fn part_position(cell: i64, part: i64) -> float3 {
    let plan = cells[cell];
    var du: f32 = 0.0;
    var dv: f32 = 0.0;
    if part == 7 {
        du = -3.0;
        dv = -7.0;
    } else if part == 13 {
        du = 3.0;
        dv = 7.0;
    } else if part == 17 {
        du = -7.0;
        dv = 3.0;
    } else if part == 19 {
        du = 7.0;
        dv = -3.0;
    } else {
        var pad_index = part;
        if part > 7 {
            pad_index--;
        }
        if part > 13 {
            pad_index--;
        }
        if part > 17 {
            pad_index--;
        }
        du = (pad_index % 4) * 3.0 - 4.5;
        dv = (pad_index / 4) * 3.0 - 4.5;
    }
    let center = estate::point(plan.radius + dv, plan.angle);
    sim::ground(center.x - sin(plan.angle) * du, center.z + cos(plan.angle) * du)
}

fn supply(h: ecs::Handle, resource: i64, amount: i64) {
    let reused = min(escrow[resource], amount);
    escrow[resource] -= reused;
    injected[resource] += amount - reused;
    assert(ecs::add(h, resource, amount));
}

fn start_recipe(h: ecs::Handle, kind: i64) {
    // A reserved job makes a newly enabled district visibly mid-production.
    // Its inputs really leave inventory and remain owned by the job queue.
    if kind == sim::SMELTER {
        supply(h, sim::ORE, 4);
        assert(ecs::take(h, sim::ORE, 2));
        ecs::enqueue(h, sim::METAL, 1);
    } else if kind == sim::ASSEMBLER {
        supply(h, sim::METAL, 2);
        supply(h, sim::CRYSTAL, 2);
        assert(ecs::take(h, sim::METAL, 1));
        assert(ecs::take(h, sim::CRYSTAL, 1));
        ecs::enqueue(h, sim::CIRCUIT, 1);
    }
    ecs::entities[h.slot].progress = 0.8;
}

fn spawn_index(index: i64) -> ecs::Handle {
    var kind: i64 = sim::STORAGE;
    var point: float3 = position(0.0, -76.0);
    var yaw = atan2(FORWARD_X, FORWARD_Z);
    let is_road = index >= ROAD_START && index < ROAD_END;
    if index == 0 {
        kind = sim::LANDER;
    } else if index < SPINE_NODES {
        point = position(0.0, -76.0 + index * 12.0);
    } else if is_road {
        let planned = estate::road_point(index - ROAD_START);
        point = sim::ground(planned.x, planned.z);
        yaw = estate::road_yaw(index - ROAD_START);
    } else {
        let cell = cell_for_index(index);
        let part = part_for_index(index);
        kind = part_kind(part);
        point = part_position(cell, part);
        yaw = -cells[cell].angle;
    }
    let h = ecs::spawn(kind, point);
    ecs::entities[h.slot].yaw = yaw;
    if index >= SPINE_NODES && !is_road {
        let part = part_for_index(index);
        if part == 1 {
            supply(h, sim::ORE, ORE_FEED);
        } else if part == 4 {
            supply(h, sim::CRYSTAL, CRYSTAL_FEED);
        } else if kind == sim::SMELTER || kind == sim::ASSEMBLER {
            start_recipe(h, kind);
        }
        if kind == sim::ROBOT {
            // Spread the first assignment wave across one second.
            ecs::entities[h.slot].timer = (index % 60) / 60.0;
        }
    }
    created++;
    h
}

fn connect(a: ecs::Handle, b: ecs::Handle) {
    if !ecs::valid(a) || !ecs::valid(b) || ecs::same(a, b) {
        return;
    }
    if sim::distance(ecs::entities[a.slot].pos, ecs::entities[b.slot].pos) <= 24.0 {
        ecs::link(a, b);
    }
}

fn connect_cells() {
    for i in SPINE_NODES - 1 {
        connect(at(i + 1), at(i));
    }
    // Every street segment is a real storage/transport/power node.
    for i in estate::RING_NODES {
        connect(road(i), road((i + 1) % estate::RING_NODES));
    }
    for spoke in 6 {
        let first = estate::RING_NODES + spoke * estate::SPOKE_STEPS;
        for step in estate::SPOKE_STEPS - 1 {
            connect(road(first + step + 1), road(first + step));
        }
        connect(road(first + 13), road(spoke * estate::RING_NODES / 6));
        connect(road(spoke * estate::RING_NODES / 6), road(first + 14));
        connect(road(first), at(SPINE_NODES - 1));
    }
    for cell in cell_count() {
        let ore = cell_entity(cell, 1);
        let crystal = cell_entity(cell, 4);
        let furnace_a = cell_entity(cell, 2);
        let furnace_b = cell_entity(cell, 8);
        let assembler_a = cell_entity(cell, 3);
        let assembler_b = cell_entity(cell, 9);
        let output_a = cell_entity(cell, 6);
        let output_b = cell_entity(cell, 12);
        let alloy_buffer = cell_entity(cell, 15);
        connect(ore, furnace_a);
        connect(ore, furnace_b);
        connect(crystal, assembler_a);
        connect(crystal, assembler_b);
        connect(furnace_a, assembler_a);
        connect(furnace_a, assembler_b);
        connect(furnace_a, alloy_buffer);
        connect(furnace_b, assembler_b);
        connect(furnace_b, assembler_a);
        connect(furnace_b, alloy_buffer);
        connect(alloy_buffer, assembler_a);
        connect(alloy_buffer, assembler_b);
        connect(assembler_a, output_a);
        connect(assembler_b, output_b);
        connect(output_b, output_a);
        // Ring neighbours and radial neighbours form loops, rather than a tree.
        let plan = cells[cell];
        var radial: i64 = -1;
        var radial_distance: f32 = 24.0;
        for other in cell {
            let previous = cells[other];
            if previous.district != plan.district {
                continue;
            }
            if previous.ring == plan.ring && previous.slot + 1 == plan.slot {
                connect(output_a, cell_entity(other, 6));
            }
            if previous.ring + 1 == plan.ring {
                let distance = sim::distance(part_position(cell, 6), part_position(other, 6));
                if distance < radial_distance {
                    radial = other;
                    radial_distance = distance;
                }
            }
        }
        if radial >= 0 {
            connect(output_a, cell_entity(radial, 6));
        }
        var nearest: i64 = -1;
        var best: f32 = 24.0;
        let output_position = part_position(cell, 6);
        for node in estate::ROAD_NODES {
            let distance = sim::distance(output_position, estate::road_point(node));
            if distance < best && ecs::valid(road(node)) {
                best = distance;
                nearest = node;
            }
        }
        if nearest >= 0 {
            connect(output_a, road(nearest));
        }
    }
}

fn removing(h: ecs::Handle, flags: bool[:]) -> bool {
    ecs::valid(h) && h.slot < flags.len && flags[h.slot]
}

fn settle_packets(flags: bool[:]) {
    for i in sim::packets.len {
        let packet .= sim::packets[i];
        if !packet.alive {
            continue;
        }
        let source_removed = removing(packet.source, flags);
        let dest_removed = removing(packet.dest, flags);
        if !source_removed && !dest_removed {
            continue;
        }
        // Settle each withdrawn item exactly once, including player-owned
        // endpoints. Cleanup prioritizes conservation over buffer capacity.
        if dest_removed && !source_removed && ecs::valid(packet.source) {
            assert(ecs::add(packet.source, packet.kind, packet.count));
        } else if !dest_removed && ecs::valid(packet.dest) {
            assert(ecs::add(packet.dest, packet.kind, packet.count));
        } else {
            escrow[packet.kind] += packet.count;
        }
        packet.alive = false;
        sim::packets.free(i);
    }
}

fn retain_cargo(e: ecs::Entity&) {
    for item in e.inventory {
        if item.kind >= 0 && item.kind < 5 {
            escrow[item.kind] += item.count;
        }
    }
    if e.kind == sim::ROBOT {
        if e.cargo_count > 0 && e.cargo_kind >= 0 && e.cargo_kind < 5 {
            escrow[e.cargo_kind] += e.cargo_count;
        }
        return;
    }
    for job in e.queue {
        if e.kind == sim::SMELTER {
            escrow[sim::ORE] += job.count * 2;
        } else if e.kind == sim::ASSEMBLER {
            escrow[sim::METAL] += job.count;
            escrow[sim::CRYSTAL] += job.count;
        } else if e.kind == sim::MINER && job.kind >= 0 && job.kind < 5 {
            escrow[job.kind] += job.count;
        }
    }
}

fn shrink(target: i64) {
    var flags: bool[>..] = [];
    flags.resize(ecs::entities.len, false);
    for i in target..owned.len {
        if ecs::valid(owned[i]) {
            flags[owned[i].slot] = true;
        }
    }
    settle_packets(flags);
    var index = owned.len;
    while index > target {
        index--;
        let h = owned[index];
        if ecs::valid(h) {
            retain_cargo(ecs::entities[h.slot]);
            ecs::destroy(h);
            removed++;
        }
    }
    owned.resize(target, ecs::Handle {});
    hub = at(0);
}

fn clear() {
    let start = clock_ns();
    shrink(0);
    enabled = false;
    load = 0;
    build_ms = (clock_ns() - start) / 1000000.0;
}

fn set_load(requested: i64) {
    if requested <= 0 {
        clear();
        return;
    }
    let start = clock_ns();
    let target = clamp(requested, 32, MAX_LOAD);
    if cells.len == 0 {
        cells.append(estate::plans());
    }
    assert(target <= ROAD_END + (cells.len - 1) * CELL_PARTS);
    if target < owned.len {
        shrink(target);
    }
    for i in owned.len {
        if !ecs::valid(owned[i]) {
            owned[i] = spawn_index(i);
        }
    }
    while owned.len < target {
        owned.push(spawn_index(owned.len));
    }
    hub = at(0);
    tower_position = position(0.0, 0.0);
    connect_cells();
    sim::update_power();
    enabled = true;
    load = target;
    build_ms = (clock_ns() - start) / 1000000.0;
}

fn flush_escrow() -> bool {
    var destination = hub;
    if !ecs::valid(destination) {
        destination = sim::base;
    }
    if !ecs::valid(destination) {
        return false;
    }
    for resource in 5 {
        if escrow[resource] > 0 {
            assert(ecs::add(destination, resource, escrow[resource]));
            escrow[resource] = 0;
        }
    }
    true
}

// Call only after changing worlds. Restored structures belong to that save;
// ownership is never guessed from matching positions or kinds.
fn forget() {
    owned.clear();
    hub = ecs::Handle {};
    enabled = false;
    load = 0;
    created = 0;
    removed = 0;
    build_ms = 0.0;
    escrow = [0; 5];
    injected = [0; 5];
    tower_position = position(0.0, 0.0);
}
