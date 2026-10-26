// Pointer-free, verified snapshots. Runtime slice pools are reconstructed;
// their freelists and native addresses are deliberately never serialized.
namespace save;
import std;
import vec;
import math;
import os;
import .entities;
import .world;
import .sim;

let VERSION: u32 = 1;
let MAGIC: u32 = 0x46524E54;
let MAX_SLOTS = 200000;
let MAX_RECORDS = 100000;
let MAX_FILE = 67108864;

struct SavedEntity {
    slot: i64, generation: u32, kind: i64, pos: float3, yaw: f32,
    progress: f32, powered: bool, target: ecs::Handle, state: i64,
    timer: f32, cargo_kind: i64, cargo_count: i64,
    inventory: ecs::Item[], queue: ecs::Item[], links: ecs::Handle[], }

struct GameImage {
    seed: u32, player: float3, bag: i64[5], day: f32, elapsed: f32,
    objective_done: bool, crafted: i64, base: ecs::Handle,
    next_generation: u32, entity_slots: i64,
    entities: SavedEntity[], packets: sim::Packet[],
    edits: world::Edit[], depleted: sim::Depletion[], }

struct Envelope { magic: u32, version: u32, checksum: u32, payload: u8[] }
var last_bytes: i64 = 0;
var last_ms: f64 = 0.0;
var error: u8[..160];

fn fail(message: const u8[:]) -> bool {
    error.clear();
    error.append(message);
    false
}

fn checksum(data: const u8[:]) -> u32 {
    var value: u32 = 2166136261;
    for b in data {
        value = (value ^ b) * 16777619;
    }
    value
}

fn saved_kind(kind: i64) -> bool {
    kind >= 1 && kind <= 9
}

fn persistent(h: ecs::Handle) -> bool {
    ecs::valid(h) && saved_kind(ecs::entities[h.slot].kind)
}

fn target_or_null(h: ecs::Handle) -> ecs::Handle {
    if persistent(h) { h } else { ecs::Handle {} }
}

fn copy_items(items: const ecs::Item[:]) -> ecs::Item[>..] {
    var out: ecs::Item[>..] = [];
    out.append(items);
    out
}

fn copy_links(links: const ecs::Handle[:]) -> ecs::Handle[>..] {
    var out: ecs::Handle[>..] = [];
    for h in links {
        if persistent(h) {
            out.push(h);
        }
    }
    out
}

fn capture_entities() -> SavedEntity[>..] {
    var out: SavedEntity[>..] = [];
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || !saved_kind(e.kind) {
            continue;
        }
        out.push(SavedEntity {
            slot: i, generation: e.generation, kind: e.kind, pos: e.pos,
            yaw: e.yaw, progress: e.progress, powered: e.powered,
            target: target_or_null(e.target), state: e.state, timer: e.timer,
            cargo_kind: e.cargo_kind, cargo_count: e.cargo_count,
            inventory: copy_items(e.inventory), queue: copy_items(e.queue),
            links: copy_links(e.links),
        });
    }
    out
}

fn capture_packets() -> sim::Packet[>..] {
    var out: sim::Packet[>..] = [];
    for p in sim::packets {
        if p.alive {
            // An orphaned packet still owns withdrawn resources. The next
            // transport tick delivers or refunds it, including after a load.
            out.push(sim::Packet {
                alive: true, source: target_or_null(p.source), dest: target_or_null(p.dest),
                kind: p.kind, count: p.count, t: p.t,
            });
        }
    }
    out
}

fn copy_edits() -> world::Edit[>..] {
    var out: world::Edit[>..] = [];
    out.append(world::edits);
    out
}

fn copy_depletion() -> sim::Depletion[>..] {
    var out: sim::Depletion[>..] = [];
    out.append(sim::depleted);
    out
}

fn capture() -> GameImage[>..] {
    var out: GameImage[>..] = [];
    var slots: i64 = 0;
    for i in ecs::entities.len {
        if ecs::entities[i].alive && saved_kind(ecs::entities[i].kind) {
            slots = i + 1;
        }
    }
    out.push(GameImage {
        seed: world::seed, player: sim::player, bag: sim::bag,
        day: sim::day, elapsed: sim::elapsed, objective_done: sim::objective_done,
        crafted: sim::crafted, base: sim::base,
        next_generation: ecs::next_generation, entity_slots: slots,
        entities: capture_entities(), packets: capture_packets(),
        edits: copy_edits(), depleted: copy_depletion(),
    });
    out
}

fn write(path: const u8[:]) -> bool {
    let start = clock();
    error.clear();
    var image = capture();
    var payload: u8[>..] = image.to_bytes();
    var envelope: Envelope[>..] = [];
    envelope.push(Envelope { MAGIC, VERSION, checksum(payload), copy(payload) });
    var bytes: u8[>..] = envelope.to_bytes();
    last_bytes = bytes.len;
    let ok = bytes.len <= MAX_FILE && write_file_atomic(path, bytes);
    last_ms = (clock() - start) * 1000.0;
    if !ok {
        return fail("Could not write save atomically");
    }
    true
}

fn bounded(value: f32, bound: f32) -> bool {
    value == value && abs(value) <= bound
}

fn position_ok(p: float3) -> bool {
    bounded(p.x, 1000000.0) && bounded(p.y, 1000000.0) && bounded(p.z, 1000000.0)
}

fn count_ok(n: i64) -> bool {
    n >= 0 && n <= 1000000000000
}

fn coordinate_ok(n: i64, bound: i64) -> bool {
    n >= -bound && n <= bound
}

fn handle_ok(h: ecs::Handle, generations: const u32[:]) -> bool {
    if h.slot == -1 {
        return h.generation == 0;
    }
    h.slot >= 0 && h.slot < generations.len && h.generation > 0 && generations[h.slot] == h.generation
}

fn valid_image(image: GameImage&) -> bool {
    if !position_ok(image.player) || !bounded(image.day, 1.0) || image.day < 0.0
        || !bounded(image.elapsed, 1000000000000.0) || image.elapsed < 0.0
        || !count_ok(image.crafted) || image.entity_slots < 1 || image.entity_slots > MAX_SLOTS
        || image.entities.len < 1 || image.entities.len > MAX_RECORDS
        || image.packets.len > MAX_RECORDS || image.edits.len > MAX_RECORDS
        || image.depleted.len > MAX_RECORDS
    {
        return false;
    }
    for count in image.bag {
        if !count_ok(count) {
            return false;
        }
    }
    var generations: u32[>..] = [];
    generations.resize(image.entity_slots, 0);
    var kinds: i64[>..] = [];
    kinds.resize(image.entity_slots, 0);
    var maximum_generation: u32 = 0;
    for e in image.entities {
        if e.slot < 0 || e.slot >= image.entity_slots || e.generation == 0
            || generations[e.slot] != 0 || !saved_kind(e.kind) || !position_ok(e.pos)
            || !bounded(e.yaw, 1000000.0) || !bounded(e.progress, 1000000.0) || e.progress < 0.0
            || !bounded(e.timer, 1000000000.0) || !count_ok(e.cargo_count) || e.cargo_kind < 0
            || e.cargo_kind >= 5 || e.inventory.len > 5 || e.queue.len > 4096 || e.links.len > 512
            || !coordinate_ok(e.state, 1000000000)
        {
            return false;
        }
        generations[e.slot] = e.generation;
        kinds[e.slot] = e.kind;
        maximum_generation = max(maximum_generation, e.generation);
        var seen: bool[5] = [false; 5];
        for item in e.inventory {
            if item.kind < 0 || item.kind >= 5 || !count_ok(item.count) || seen[item.kind] {
                return false;
            }
            seen[item.kind] = true;
        }
        for item in e.queue {
            if e.kind == 7 {
                if !coordinate_ok(item.kind, 100000000) || !coordinate_ok(item.count, 100000000) {
                    return false;
                }
            } else if item.kind < 0 || item.kind >= 5 || !count_ok(item.count) {
                return false;
            }
        }
    }
    if maximum_generation > image.next_generation || image.next_generation == 4294967295
        || !handle_ok(image.base, generations) || image.base.slot < 0 || kinds[image.base.slot] != 1
    {
        return false;
    }
    for e in image.entities {
        if !handle_ok(e.target, generations) {
            return false;
        }
        for h in e.links {
            if h.slot < 0 || !handle_ok(h, generations) {
                return false;
            }
        }
    }
    for p in image.packets {
        if !p.alive || !handle_ok(p.source, generations) || !handle_ok(p.dest, generations)
            || p.kind < 0 || p.kind >= 5 || !count_ok(p.count) || p.count == 0 || !bounded(p.t, 1.0)
            || p.t < 0.0
        {
            return false;
        }
    }
    for e in image.edits {
        if !coordinate_ok(e.gx, 500001) || !coordinate_ok(e.gz, 500001) || !bounded(e.delta, 14.0)
            || e.delta > 10.0
        {
            return false;
        }
    }
    for d in image.depleted {
        if !coordinate_ok(d.gx, 1000000) || !coordinate_ok(d.gz, 1000000) || !count_ok(d.left) {
            return false;
        }
    }
    true
}

fn restore(image: GameImage&) {
    // Allocate all existing slots before returning holes. This preserves every
    // saved slot+generation even if the reusable freelist order has changed.
    world::shutdown();
    sim::clear_packets();
    ecs::clear();
    let slots = max(ecs::entities.len, image.entity_slots);
    for i in slots {
        ecs::entities.alloc_index(ecs::Entity {
            alive: true, inventory: ecs::inventories.alloc_slice(0),
            queue: ecs::queues.alloc_slice(0), links: ecs::edges.alloc_slice(0), ..
        });
    }
    for &e in ecs::entities {
        e.alive = false;
    }
    ecs::alive_count = 0;
    for saved in image.entities {
        let e .= ecs::entities[saved.slot];
        e.alive = true;
        e.generation = saved.generation;
        e.kind = saved.kind;
        e.pos = saved.pos;
        e.yaw = saved.yaw;
        e.progress = saved.progress;
        e.powered = saved.powered;
        e.target = saved.target;
        e.state = saved.state;
        e.timer = saved.timer;
        e.cargo_kind = saved.cargo_kind;
        e.cargo_count = saved.cargo_count;
        e.inventory = ecs::inventories.realloc_slice(e.inventory, saved.inventory.len);
        for i in saved.inventory.len {
            e.inventory[i] = saved.inventory[i];
        }
        e.queue = ecs::queues.realloc_slice(e.queue, saved.queue.len);
        for i in saved.queue.len {
            e.queue[i] = saved.queue[i];
        }
        e.links = ecs::edges.realloc_slice(e.links, saved.links.len);
        for i in saved.links.len {
            e.links[i] = saved.links[i];
        }
        ecs::alive_count++;
    }
    for i in ecs::entities.len {
        if !ecs::entities[i].alive {
            ecs::entities.free(i);
        }
    }
    ecs::next_generation = max(ecs::next_generation, image.next_generation);
    world::edits.clear();
    world::edits.append(image.edits);
    sim::depleted.clear();
    sim::depleted.append(image.depleted);
    for p in image.packets {
        sim::packets.alloc_ref(p);
    }
    sim::player = image.player;
    sim::bag = image.bag;
    sim::day = image.day;
    sim::elapsed = image.elapsed;
    sim::objective_done = image.objective_done;
    sim::crafted = image.crafted;
    sim::base = image.base;
    sim::after_load(image.seed);
    world::init(image.seed);
}

fn load(path: const u8[:]) -> bool {
    let start = clock();
    error.clear();
    var bytes: u8[>..] = [];
    if !read_file(path, bytes) || bytes.len > MAX_FILE {
        return fail("Save missing or too large");
    }
    last_bytes = bytes.len;
    var envelope, ok = from_bytes<Envelope[>..]>(bytes);
    if !ok || envelope.len != 1 {
        return fail("Malformed save envelope");
    }
    for env in envelope {
        if env.magic != MAGIC || env.version != VERSION {
            return fail("Unsupported save version");
        }
        if env.checksum != checksum(env.payload) {
            return fail("Save checksum mismatch");
        }
        var images, valid = from_bytes<GameImage[>..]>(env.payload);
        if !valid || images.len != 1 {
            return fail("Malformed world snapshot");
        }
        for image in images {
            if !valid_image(image) {
                return fail("Invalid world snapshot values");
            }
            restore(image);
        }
    }
    last_ms = (clock() - start) * 1000.0;
    true
}
