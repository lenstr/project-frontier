namespace sim;
import std;
import math;
import os;
import vec;
import .entities;
import .world;
import .navigation;

let ORE = 0;
let CRYSTAL = 1;
let METAL = 2;
let CIRCUIT = 3;
let STONE = 4;
let LANDER = 1;
let MINER = 2;
let SMELTER = 3;
let SOLAR = 4;
let RELAY = 5;
let ASSEMBLER = 6;
let ROBOT = 7;
let TOWER = 8;
let STORAGE = 9;
let DEPOSIT_ORE = 20;
let DEPOSIT_CRYSTAL = 21;
let STRESS = 90;

var player: float3;
var bag: i64[5];
var day: f32 = 0.18;
var elapsed: f32 = 0.0;
var objective_done = false;
var base: ecs::Handle;
var supply: f32 = 0.0;
var demand: f32 = 0.0;
var simulation_ms: f64 = 0.0;
var crafted: i64 = 0;
var message: u8[..180];
var message_time: f32 = 0.0;
var seed: u32 = 73129;
var dispatch_clock: f32 = 0.0;
var mine_clock: f32 = 0.0;
var deposit_cx: i64 = 9223372036854775807;
var deposit_cz: i64 = 9223372036854775807;
var path_budget: i64 = 0;

// Exact stamps detect raw ECS edits and restored snapshots as well as normal
// construction. Component membership changes only when this topology changes.
struct PowerStamp { slot: i64, generation: u32, kind: i64, x: f32, z: f32 }
var power_stamps: PowerStamp[>..<] = [];
var power_components: i64[>..<] = [];
var power_component_count: i64 = 0;
var power_rebuilds: i64 = 0;

struct Depletion { gx: i64, gz: i64, left: i64 }
var depleted: Depletion[>..<] = [];

struct Packet {
    alive: bool, source: ecs::Handle, dest: ecs::Handle,
    kind: i64, count: i64, t: f32, }
reusable var packets: Packet[>..] = [];

fn say(text: const u8[:]) {
    message = text;
    message_time = 5.0;
}

fn distance(a: float3, b: float3) -> f32 {
    nav::distance(a, b)
}

fn ground(x: f32, z: f32) -> float3 {
    float3 { x, world::height(x, z), z }
}

fn handle(slot: i64) -> ecs::Handle {
    ecs::Handle { slot: slot, generation: ecs::entities[slot].generation }
}

fn building(kind: i64) -> bool {
    kind >= LANDER && kind <= STORAGE && kind != ROBOT
}

fn clear_packets() {
    for i in packets.len {
        if packets[i].alive {
            packets[i].alive = false;
            packets.free(i);
        }
    }
}

fn reset() {
    clear_packets();
    ecs::clear();
    depleted.clear();
    bag = [0; 5];
    day = 0.18;
    elapsed = 0.0;
    objective_done = false;
    base = ecs::Handle {};
    supply = 0.0;
    demand = 0.0;
    crafted = 0;
    message = "";
    message_time = 0.0;
    after_load(seed);
}

fn after_load(s: u32) {
    seed = s;
    world::seed = s;
    dispatch_clock = 0.0;
    mine_clock = 0.0;
    deposit_cx = 9223372036854775807;
    deposit_cz = 9223372036854775807;
    power_stamps.clear();
    power_components.clear();
    power_component_count = 0;
}

fn spawn_robot(pos: float3) -> ecs::Handle {
    ecs::spawn(ROBOT, ground(pos.x, pos.z))
}

fn init(s: u32) {
    world::shutdown();
    world::edits.clear();
    reset();
    seed = s;
    world::init(s);
    player = ground(0.0, 7.0);
    bag[METAL] = 18;
    bag[CRYSTAL] = 6;
    bag[STONE] = 24;
    base = ecs::spawn(LANDER, ground(0.0, 0.0));
    ecs::spawn(SOLAR, ground(4.0, 0.0));
    spawn_robot(ground(2.0, 3.0));
    stream_deposits(player.x, player.z);
    say("Welcome to Frontier. Mine Ferrite and Glacite, automate production, and restore the uplink.");
}

fn depletion(gx: i64, gz: i64, initial: i64) -> i64 {
    for d in depleted {
        if d.gx == gx && d.gz == gz {
            return d.left;
        }
    }
    initial
}

fn record_depletion(e: ecs::Entity&) {
    let gx = e.state;
    let gz = e.timer as! i64;
    for &d in depleted {
        if d.gx == gx && d.gz == gz {
            d.left = e.cargo_count;
            return;
        }
    }
    depleted.push(Depletion { gx, gz, e.cargo_count });
}

fn deposit_exists(gx: i64, gz: i64) -> bool {
    for e in ecs::entities {
        if e.alive && (e.kind == DEPOSIT_ORE || e.kind == DEPOSIT_CRYSTAL) && e.state == gx
            && e.timer as! i64 == gz
        {
            return true;
        }
    }
    false
}

fn near_miner(pos: float3) -> bool {
    for e in ecs::entities {
        if e.alive && e.kind == MINER && distance(e.pos, pos) < 7.0 {
            return true;
        }
    }
    false
}

fn stream_deposits(x: f32, z: f32) {
    let cx = floor(x / 16.0) as i64;
    let cz = floor(z / 16.0) as i64;
    if cx == deposit_cx && cz == deposit_cz {
        return;
    }
    deposit_cx = cx;
    deposit_cz = cz;
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || (e.kind != DEPOSIT_ORE && e.kind != DEPOSIT_CRYSTAL) {
            continue;
        }
        if (abs(e.state - cx) > 6 || abs((e.timer as! i64) - cz) > 6) && !near_miner(e.pos) {
            ecs::destroy(handle(i));
        }
    }
    for dz in -5..6 {
        for dx in -5..6 {
            let gx = cx + dx;
            let gz = cz + dz;
            if deposit_exists(gx, gz) {
                continue;
            }
            let hash = world::hash(gx, gz, seed + 919);
            var resource: i64 = if hash % 5 == 0 { CRYSTAL } else { ORE };
            var wx: f32 = gx * 16.0 + 4.0 + (hash & 255) / 32.0;
            var wz: f32 = gz * 16.0 + 4.0 + ((hash >> 8) & 255) / 32.0;
            var total: i64 = 180 + (hash % 160) as i64;
            if gx == 0 && gz == 0 {
                wx = 8.0;
                wz = 6.0;
                resource = ORE;
                total = 640;
            }
            if gx == -1 && gz == 0 {
                wx = -8.0;
                wz = 10.0;
                resource = CRYSTAL;
                total = 240;
            }
            let left = depletion(gx, gz, total);
            if left <= 0 {
                continue;
            }
            let deposit_kind = if resource == CRYSTAL { DEPOSIT_CRYSTAL } else { DEPOSIT_ORE };
            let h = ecs::spawn(deposit_kind, ground(wx, wz));
            let e .= ecs::entities[h.slot];
            e.state = gx;
            e.timer = gz;
            e.cargo_kind = resource;
            e.cargo_count = left;
        }
    }
}

fn nearest(pos: float3, range: f32, kind: i64) -> ecs::Handle {
    var result = ecs::Handle {};
    var best = range;
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive {
            continue;
        }
        if kind == -1 && !building(e.kind) {
            continue;
        }
        if kind == 0 && e.kind != DEPOSIT_ORE && e.kind != DEPOSIT_CRYSTAL {
            continue;
        }
        if kind > 0 && e.kind != kind {
            continue;
        }
        let d = distance(pos, e.pos);
        if d <= best {
            best = d;
            result = handle(i);
        }
    }
    result
}

fn cost(kind: i64, resource: i64) -> i64 {
    if kind == MINER {
        if resource == METAL {
            return 4;
        }
        if resource == STONE {
            return 3;
        }
    }
    if kind == SMELTER {
        if resource == METAL {
            return 4;
        }
        if resource == STONE {
            return 4;
        }
    }
    if kind == SOLAR {
        if resource == METAL {
            return 3;
        }
        if resource == CRYSTAL {
            return 2;
        }
    }
    if kind == RELAY {
        if resource == METAL {
            return 1;
        }
        if resource == STONE {
            return 1;
        }
    }
    if kind == ASSEMBLER {
        if resource == METAL {
            return 6;
        }
        if resource == CRYSTAL {
            return 2;
        }
    }
    if kind == ROBOT {
        if resource == METAL {
            return 5;
        }
        if resource == CIRCUIT {
            return 1;
        }
    }
    if kind == TOWER {
        if resource == METAL {
            return 20;
        }
        if resource == CRYSTAL {
            return 10;
        }
        if resource == CIRCUIT {
            return 8;
        }
    }
    if kind == STORAGE {
        if resource == METAL {
            return 2;
        }
        if resource == STONE {
            return 2;
        }
    }
    0
}

fn can_build(kind: i64) -> bool {
    if kind < MINER || kind > STORAGE {
        return false;
    }
    for resource in 5 {
        if bag[resource] < cost(kind, resource) {
            return false;
        }
    }
    true
}

fn build(kind: i64, pos: float3) -> ecs::Handle {
    if !can_build(kind) {
        say("More resources needed. Mine, collect from machines, or refine with C and V.");
        return ecs::Handle {};
    }
    if abs(pos.x) > 1000000.0 || abs(pos.z) > 1000000.0 {
        return ecs::Handle {};
    }
    for e in ecs::entities {
        if !e.alive || !building(e.kind) {
            continue;
        }
        let radius: f32 = if kind == TOWER || e.kind == LANDER || e.kind == TOWER { 3.2 } else { 2.2 };
        if distance(e.pos, pos) < radius {
            say("Leave some space around that structure.");
            return ecs::Handle {};
        }
    }
    if kind == MINER && !ecs::valid(nearest(pos, 5.0, 0)) {
        say("Place extractors within 5 metres of a red Ferrite or blue Glacite seam.");
        return ecs::Handle {};
    }
    for resource in 5 {
        bag[resource] -= cost(kind, resource);
    }
    let h = ecs::spawn(kind, ground(pos.x, pos.z));
    say("Structure built. Nearby pylons share power; link machines to move resources.");
    h
}

fn mine(h: ecs::Handle) -> bool {
    if !ecs::valid(h) || mine_clock > 0.0 {
        return false;
    }
    let e .= ecs::entities[h.slot];
    if (e.kind != DEPOSIT_ORE && e.kind != DEPOSIT_CRYSTAL) || e.cargo_count <= 0
        || distance(player, e.pos) > 6.0
    {
        return false;
    }
    bag[e.cargo_kind]++;
    e.cargo_count--;
    e.progress = 1.0;
    record_depletion(e);
    mine_clock = 0.14;
    if e.cargo_count == 0 {
        ecs::destroy(h);
        say("Seam depleted. Explore farther for another mineral field.");
    }
    true
}

fn dig(x: f32, z: f32, delta: f32) {
    if distance(player, ground(x, z)) > 8.0 || delta == 0.0 {
        return;
    }
    if delta > 0.0 {
        if bag[STONE] <= 0 {
            say("Terrain fill needs stone.");
            return;
        }
        bag[STONE]--;
    } else {
        bag[STONE]++;
    }
    world::edit(x, z, clamp(delta, -0.7, 0.7));
    for &e in ecs::entities {
        if e.alive && distance(e.pos, ground(x, z)) < 5.0 {
            e.pos.y = world::height(e.pos.x, e.pos.z);
        }
    }
}

fn collect(h: ecs::Handle) -> bool {
    if !ecs::valid(h) || distance(player, ecs::entities[h.slot].pos) > 7.0 {
        return false;
    }
    let e .= ecs::entities[h.slot];
    var any = false;
    for item in e.inventory {
        if item.kind >= 0 && item.kind < 5 && item.count > 0 {
            bag[item.kind] += item.count;
            any = true;
        }
    }
    e.inventory = ecs::inventories.realloc_slice(e.inventory, 0);
    if any {
        say("Cargo collected.");
    } else {
        say("No cargo yet. Check power, mineral seams and logistics connections.");
    }
    any
}

fn manual_smelt() -> bool {
    if bag[ORE] < 2 {
        say("Refining requires 2 Ferrite for 1 Alloy.");
        return false;
    }
    bag[ORE] -= 2;
    bag[METAL]++;
    crafted++;
    say("Refined 2 Ferrite into 1 Alloy.");
    true
}

fn manual_circuit() -> bool {
    if bag[METAL] < 1 || bag[CRYSTAL] < 1 {
        say("A Circuit requires 1 Alloy and 1 Glacite.");
        return false;
    }
    bag[METAL]--;
    bag[CRYSTAL]--;
    bag[CIRCUIT]++;
    crafted++;
    say("Fabricated 1 circuit.");
    true
}

fn reclaim(h: ecs::Handle) -> bool {
    if !ecs::valid(h) || distance(player, ecs::entities[h.slot].pos) > 7.0 {
        return false;
    }
    let e .= ecs::entities[h.slot];
    if e.kind == LANDER || e.kind >= DEPOSIT_ORE {
        return false;
    }
    for item in e.inventory {
        if item.kind >= 0 && item.kind < 5 {
            bag[item.kind] += item.count;
        }
    }
    // A queued production output represents inputs already committed to work.
    if e.kind != ROBOT {
        for item in e.queue {
            if e.kind == SMELTER {
                bag[ORE] += item.count * 2;
            }
            if e.kind == ASSEMBLER {
                bag[METAL] += item.count;
                bag[CRYSTAL] += item.count;
            }
            if e.kind == MINER && item.kind >= 0 && item.kind < 5 {
                bag[item.kind] += item.count;
            }
        }
    }
    if e.cargo_count > 0 && e.kind == ROBOT && e.cargo_kind >= 0 && e.cargo_kind < 5 {
        bag[e.cargo_kind] += e.cargo_count;
    }
    for resource in 5 {
        bag[resource] += cost(e.kind, resource);
    }
    ecs::destroy(h);
    say("Structure reclaimed. Materials and cargo returned.");
    true
}

fn link(a: ecs::Handle, b: ecs::Handle) -> bool {
    if !ecs::valid(a) || !ecs::valid(b) || ecs::same(a, b) {
        return false;
    }
    let source .= ecs::entities[a.slot];
    let dest .= ecs::entities[b.slot];
    if !building(source.kind) || !building(dest.kind) || distance(source.pos, dest.pos) > 24.0 {
        say("Logistics links need two structures within 24 metres.");
        return false;
    }
    for other in source.links {
        if ecs::same(other, b) {
            return false;
        }
    }
    if bag[STONE] < 1 {
        say("A logistics rail costs 1 stone. Dig nearby terrain to collect more.");
        return false;
    }
    bag[STONE]--;
    ecs::link(a, b);
    say("Logistics rail connected. Cargo moves in the direction of the arrows.");
    true
}

fn inventory_total(h: ecs::Handle) -> i64 {
    if !ecs::valid(h) {
        return 0;
    }
    var n: i64 = 0;
    for item in ecs::entities[h.slot].inventory {
        n += item.count;
    }
    n
}

fn inbound(h: ecs::Handle, resource: i64) -> i64 {
    var total: i64 = 0;
    for p in packets {
        if p.alive && ecs::same(p.dest, h) && (resource < 0 || p.kind == resource) {
            total += p.count;
        }
    }
    total
}

fn accepts(h: ecs::Handle, resource: i64) -> bool {
    if !ecs::valid(h) || inventory_total(h) + inbound(h, -1) >= 128 {
        return false;
    }
    let kind = ecs::entities[h.slot].kind;
    if kind == SMELTER {
        return resource == ORE && ecs::amount(h, ORE) + inbound(h, ORE) < 16;
    }
    if kind == ASSEMBLER {
        return (resource == METAL || resource == CRYSTAL)
            && ecs::amount(h, resource) + inbound(h, resource) < 16;
    }
    kind == LANDER || kind == STORAGE
}

fn exports(kind: i64, resource: i64) -> bool {
    (kind == MINER && (resource == ORE || resource == CRYSTAL))
        || (kind == SMELTER && resource == METAL)
        || (kind == ASSEMBLER && resource == CIRCUIT)
        || kind == LANDER
        || kind == STORAGE
}

fn power_use(kind: i64) -> f32 {
    if kind == MINER {
        return 2.0;
    }
    if kind == SMELTER || kind == ASSEMBLER {
        return 3.0;
    }
    if kind == TOWER {
        return 8.0;
    }
    0.0
}

fn power_output(kind: i64) -> f32 {
    if kind == LANDER {
        return 6.0;
    }
    if kind == SOLAR {
        return if sin(day * TAU) > 0.1 { 8.0 } else { 2.0 };
    }
    0.0
}

fn refresh_power_topology() {
    var changed = false;
    var count: i64 = 0;
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || !building(e.kind) {
            continue;
        }
        if count >= power_stamps.len {
            changed = true;
        } else {
            let previous = power_stamps[count];
            if previous.slot != i || previous.generation != e.generation || previous.kind != e.kind
                || previous.x != e.pos.x || previous.z != e.pos.z
            {
                changed = true;
            }
        }
        count++;
    }
    if count != power_stamps.len {
        changed = true;
    }
    if !changed {
        return;
    }
    power_stamps.clear();
    power_components.clear();
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || !building(e.kind) {
            continue;
        }
        power_stamps.push(PowerStamp { i, e.generation, e.kind, e.pos.x, e.pos.z });
        power_components.push(-1);
    }
    var work: i64[>..<] = [];
    var serial: i64 = 0;
    for first in power_stamps.len {
        if power_components[first] >= 0 {
            continue;
        }
        work.clear();
        work.push(first);
        power_components[first] = serial;
        var at: i64 = 0;
        while at < work.len {
            let index = work[at];
            at++;
            let current = power_stamps[index];
            for other in power_stamps.len {
                if power_components[other] >= 0 {
                    continue;
                }
                let candidate = power_stamps[other];
                let dx = current.x - candidate.x;
                let dz = current.z - candidate.z;
                if sqrt(dx * dx + dz * dz) <= 14.0 {
                    power_components[other] = serial;
                    work.push(other);
                }
            }
        }
        serial++;
    }
    power_component_count = serial;
    power_rebuilds++;
}

fn update_power() {
    refresh_power_topology();
    supply = 0.0;
    demand = 0.0;
    var available: f32[>..] = [];
    available.resize(power_component_count, 0.0);
    for i in power_stamps.len {
        let e .= ecs::entities[power_stamps[i].slot];
        let output = power_output(e.kind);
        available[power_components[i]] += output;
        supply += output;
        demand += power_use(e.kind);
    }
    // Stamps are ordered by entity slot, preserving deterministic brownouts.
    for i in power_stamps.len {
        let e .= ecs::entities[power_stamps[i].slot];
        let component = power_components[i];
        let need = power_use(e.kind);
        e.powered = available[component] >= need && (need > 0.0 || available[component] > 0.0);
        if e.powered {
            available[component] -= need;
        }
    }
}

fn finish_job(h: ecs::Handle) {
    let e .= ecs::entities[h.slot];
    if e.queue.len == 0 || inventory_total(h) + e.queue[0].count > 128 {
        return;
    }
    let job = e.queue[0];
    assert(ecs::add(h, job.kind, job.count));
    if e.kind == SMELTER || e.kind == ASSEMBLER {
        crafted += job.count;
    }
    for i in 0..e.queue.len - 1 {
        e.queue[i] = e.queue[i + 1];
    }
    e.queue = ecs::queues.realloc_slice(e.queue, e.queue.len - 1);
    e.progress = 0.0;
}

fn machines(dt: f32) {
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive {
            continue;
        }
        if e.kind == DEPOSIT_ORE || e.kind == DEPOSIT_CRYSTAL {
            e.progress = max(0.0, e.progress - dt * 3.0);
            continue;
        }
        if e.kind == TOWER {
            if e.powered && !objective_done {
                e.progress = min(1.0, e.progress + dt / 45.0);
                if e.progress >= 1.0 {
                    objective_done = true;
                    say("UPLINK RESTORED. Your colony is on the star map. Keep exploring and expanding.");
                }
            }
            continue;
        }
        if e.kind != MINER && e.kind != SMELTER && e.kind != ASSEMBLER {
            continue;
        }
        if !e.powered {
            continue;
        }
        let h = handle(i);
        if e.queue.len == 0 && inventory_total(h) < 128 {
            if e.kind == MINER {
                let node = nearest(e.pos, 5.0, 0);
                if ecs::valid(node) {
                    let d .= ecs::entities[node.slot];
                    if d.cargo_count > 0 {
                        d.cargo_count--;
                        d.progress = 0.6;
                        record_depletion(d);
                        ecs::enqueue(h, d.cargo_kind, 1);
                        e.target = node;
                        if d.cargo_count == 0 {
                            ecs::destroy(node);
                        }
                    }
                }
            } else if e.kind == SMELTER && ecs::take(h, ORE, 2) {
                ecs::enqueue(h, METAL, 1);
            } else if e.kind == ASSEMBLER && ecs::amount(h, METAL) > 0 && ecs::amount(h, CRYSTAL) > 0 {
                assert(ecs::take(h, METAL, 1));
                assert(ecs::take(h, CRYSTAL, 1));
                ecs::enqueue(h, CIRCUIT, 1);
            }
        }
        if e.queue.len > 0 {
            let duration: f32 = if e.kind == MINER { 0.5 } else if e.kind == SMELTER { 2.0 } else { 3.0 };
            e.progress = min(1.0, e.progress + dt / duration);
            if e.progress >= 1.0 {
                finish_job(h);
            }
        }
    }
}

fn refund_packet(p: Packet&) {
    if ecs::valid(p.source) {
        assert(ecs::add(p.source, p.kind, p.count));
    } else if ecs::valid(base) {
        assert(ecs::add(base, p.kind, p.count));
    } else {
        bag[p.kind] += p.count;
    }
}

fn transport(dt: f32) {
    for i in packets.len {
        let p .= packets[i];
        if !p.alive {
            continue;
        }
        if !ecs::valid(p.dest) {
            refund_packet(p);
            p.alive = false;
            packets.free(i);
            continue;
        }
        var length: f32 = 8.0;
        if ecs::valid(p.source) {
            length = distance(ecs::entities[p.source.slot].pos, ecs::entities[p.dest.slot].pos);
        }
        p.t = min(1.0, p.t + dt * 8.0 / max(1.0, length));
        if p.t >= 1.0 && inventory_total(p.dest) + p.count <= 128 {
            assert(ecs::add(p.dest, p.kind, p.count));
            p.alive = false;
            packets.free(i);
        }
    }
    dispatch_clock -= dt;
    if dispatch_clock > 0.0 {
        return;
    }
    dispatch_clock += 0.6;
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || !building(e.kind) {
            continue;
        }
        let source = handle(i);
        var sent = false;
        for offset in e.links.len {
            if sent {
                break;
            }
            let edge = (e.state + offset) % e.links.len;
            let target = e.links[edge];
            if !ecs::valid(target) {
                continue;
            }
            for resource in 5 {
                if !exports(e.kind, resource) || ecs::amount(source, resource) <= 0
                    || !accepts(target, resource)
                {
                    continue;
                }
                assert(ecs::take(source, resource, 1));
                packets.alloc_index(Packet {
                    alive: true, source: source, dest: target, kind: resource, count: 1, t: 0.0
                });
                e.state = (edge + 1) % e.links.len;
                sent = true;
                break;
            }
        }
    }
}

fn robot_destination(source: ecs::Handle, resource: i64, from: float3) -> ecs::Handle {
    var best = ecs::Handle {};
    var best_score: f32 = 100000.0;
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || i == source.slot || !accepts(handle(i), resource) {
            continue;
        }
        // Robots feed production and bring results home. Storage-to-storage
        // shuttling would endlessly undo their own previous deliveries.
        if e.kind != SMELTER && e.kind != ASSEMBLER && e.kind != LANDER {
            continue;
        }
        let range = distance(from, e.pos);
        if range > 34.0 {
            continue;
        }
        let stock = ecs::amount(handle(i), resource) + inbound(handle(i), resource);
        // Consumers get first claim; the lander is the collection hub.
        let penalty: f32 = if e.kind == SMELTER || e.kind == ASSEMBLER {
            stock * 4.0
        } else if e.kind == LANDER {
            60.0
        } else {
            90.0
        };
        let score = range + penalty;
        if score < best_score {
            best = handle(i);
            best_score = score;
        }
    }
    best
}

fn idle_robot(h: ecs::Handle) {
    let robot .= ecs::entities[h.slot];
    var source = ecs::Handle {};
    var dest = ecs::Handle {};
    var resource: i64 = -1;
    var best: f32 = 100000.0;
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || !building(e.kind) || distance(robot.pos, e.pos) > 34.0 {
            continue;
        }
        let candidate = handle(i);
        for item in e.inventory {
            if item.count <= 0 || !exports(e.kind, item.kind) {
                continue;
            }
            let to = robot_destination(candidate, item.kind, e.pos);
            if !ecs::valid(to) {
                continue;
            }
            let score = distance(robot.pos, e.pos) + distance(e.pos, ecs::entities[to.slot].pos);
            if score < best {
                source = candidate;
                dest = to;
                resource = item.kind;
                best = score;
            }
        }
    }
    if !ecs::valid(source) {
        robot.timer = 1.0;
        return;
    }
    robot.target = source;
    robot.state = 1;
    robot.cargo_kind = resource;
    robot.links = ecs::edges.realloc_slice(robot.links, 1);
    robot.links[0] = dest;
    robot.queue = ecs::queues.realloc_slice(robot.queue, 0);
    robot.timer = 0.0;
}

fn abandon_robot(e: ecs::Entity&) {
    e.state = 0;
    e.target = ecs::Handle {};
    e.timer = 0.4;
    e.queue = ecs::queues.realloc_slice(e.queue, 0);
    e.links = ecs::edges.realloc_slice(e.links, 0);
}

fn robots(dt: f32) {
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || e.kind != ROBOT {
            continue;
        }
        let h = handle(i);
        e.pos.y = world::height(e.pos.x, e.pos.z);
        e.timer -= dt;
        if e.state == 0 {
            if e.timer <= 0.0 {
                idle_robot(h);
            }
            continue;
        }
        if !ecs::valid(e.target) {
            if e.cargo_count > 0 && ecs::valid(base) {
                e.target = base;
                e.state = 2;
                e.queue = ecs::queues.realloc_slice(e.queue, 0);
            } else {
                abandon_robot(e);
                continue;
            }
        }
        let target = e.target;
        let position = ecs::entities[target.slot].pos;
        let arrival: f32 = if ecs::entities[target.slot].kind == LANDER { 3.0 } else { 2.6 };
        if distance(e.pos, position) <= arrival {
            if e.state == 1 {
                let dest = if e.links.len > 0 { e.links[0] } else { ecs::Handle {} };
                if !ecs::valid(dest) || !accepts(dest, e.cargo_kind) {
                    abandon_robot(e);
                    continue;
                }
                let free_space = 128 - inventory_total(dest) - inbound(dest, -1);
                let count = min(4, min(ecs::amount(target, e.cargo_kind), free_space));
                if count <= 0 {
                    abandon_robot(e);
                    continue;
                }
                assert(ecs::take(target, e.cargo_kind, count));
                e.cargo_count = count;
                e.target = dest;
                e.state = 2;
                e.links = ecs::edges.realloc_slice(e.links, 0);
                e.queue = ecs::queues.realloc_slice(e.queue, 0);
                e.timer = 0.0;
            } else if inventory_total(target) + e.cargo_count <= 128 {
                assert(ecs::add(target, e.cargo_kind, e.cargo_count));
                e.cargo_count = 0;
                abandon_robot(e);
            } else if !ecs::same(target, base) && ecs::valid(base) {
                e.target = base;
                e.queue = ecs::queues.realloc_slice(e.queue, 0);
                e.timer = 0.0;
            }
            continue;
        }
        if e.queue.len == 0 && e.timer <= 0.0 && path_budget > 0 {
            path_budget--;
            if !nav::plan(h, position, target) {
                e.timer = 2.0;
            }
        }
        nav::walk(h, dt, target);
    }
}

fn tick(dt: f32) {
    let start = clock();
    let step = clamp(dt, 0.0, 0.1);
    elapsed += step;
    day = (day + step / 720.0) % 1.0;
    message_time = max(0.0, message_time - step);
    mine_clock = max(0.0, mine_clock - step);
    path_budget = 2;
    stream_deposits(player.x, player.z);
    update_power();
    machines(step);
    transport(step);
    robots(step);
    simulation_ms = (clock() - start) * 1000.0;
}

fn stress_spawn(n: i64) {
    for i in max(0, min(n, 10000)) {
        let hash = world::hash(i, ecs::alive_count, seed);
        let x = player.x + ((hash & 1023) / 1023.0 - 0.5) * 55.0;
        let z = player.z + (((hash >> 10) & 1023) / 1023.0 - 0.5) * 55.0;
        ecs::spawn(STRESS, ground(x, z));
    }
    say("Stress objects spawned. Watch the entity slots and memory high-water counters.");
}

fn stress_destroy(n: i64) {
    var removed: i64 = 0;
    for i in ecs::entities.len {
        if removed >= n {
            break;
        }
        if ecs::entities[i].alive && ecs::entities[i].kind == STRESS {
            ecs::destroy(handle(i));
            removed++;
        }
    }
    say("Stress objects returned to the reusable pool.");
}

fn network_stress() {
    var nodes: ecs::Handle[>..] = [];
    for i in 20 {
        let x = player.x + 12.0 + (i % 5) * 3.0;
        let z = player.z + (i / 5) * 3.0;
        nodes.push(ecs::spawn(STORAGE, ground(x, z)));
    }
    for i in nodes.len {
        ecs::link(nodes[i], nodes[(i + 1) % nodes.len]);
    }
    ecs::add(nodes[0], ORE, 100);
    say("Network stress: 20 cargo stores on a closed logistics circuit.");
}

fn shutdown() {
    world::shutdown();
}
