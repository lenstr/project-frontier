import vec;
namespace ecs;

// Handles describe logical identity. Goose references remain memory safe after
// pool reuse, but cannot distinguish a replacement entity without this token.
struct Handle { slot: i64 = -1, generation: u32 = 0 }

struct Item { kind: i64, count: i64 }

struct Entity {
    alive: bool,
    generation: u32,
    kind: i64,
    pos: float3,
    yaw: f32,
    progress: f32,
    powered: bool,
    inventory: Item[:],
    queue: Item[:],
    links: Handle[:],
    target: Handle,
    state: i64,
    timer: f32,
    cargo_kind: i64,
    cargo_count: i64, }

// Entity slots have arbitrary lifetimes. Each independently growing collection
// owns a run in its own coalescing slice pool; no per-entity heap is involved.
reusable var entities: Entity[>..] = [];
reusable[] var inventories: Item[>..] = [];
reusable[] var queues: Item[>..] = [];
reusable[] var edges: Handle[>..] = [];
var alive_count: i64 = 0;
var next_generation: u32 = 0;

fn spawn(kind: i64, pos: float3) -> Handle {
    // Fail visibly rather than allowing a handle to become valid after wrap.
    assert(next_generation < 4294967295);
    next_generation++;
    let slot = entities.alloc_index(Entity {
        alive: true, generation: next_generation, kind: kind, pos: pos,
        inventory: inventories.alloc_slice(0), queue: queues.alloc_slice(0),
        links: edges.alloc_slice(0), ..
    });
    alive_count++;
    return Handle { slot: slot, generation: next_generation };
}

fn valid(h: Handle) -> bool {
    h.slot >= 0
        && h.slot < entities.len
        && entities[h.slot].alive
        && entities[h.slot].generation == h.generation
}

fn amount(h: Handle, resource: i64) -> i64 {
    if !valid(h) {
        return 0;
    }
    for item in entities[h.slot].inventory {
        if item.kind == resource {
            return item.count;
        }
    }
    return 0;
}

fn add(h: Handle, resource: i64, count: i64) -> bool {
    if !valid(h) || count < 0 {
        return false;
    }
    if count == 0 {
        return true;
    }
    let e .= entities[h.slot];
    for &item in e.inventory {
        if item.kind == resource {
            if item.count > 9223372036854775807 - count {
                return false;
            }
            item.count += count;
            return true;
        }
    }
    let n = e.inventory.len;
    e.inventory = inventories.realloc_slice(e.inventory, n + 1);
    e.inventory[n] = Item { resource, count };
    return true;
}

fn take(h: Handle, resource: i64, count: i64) -> bool {
    if !valid(h) || count < 0 {
        return false;
    }
    if count == 0 {
        return true;
    }
    let e .= entities[h.slot];
    for i in e.inventory.len {
        if e.inventory[i].kind != resource {
            continue;
        }
        if e.inventory[i].count < count {
            return false;
        }
        e.inventory[i].count -= count;
        if e.inventory[i].count == 0 {
            for j in i..e.inventory.len - 1 {
                e.inventory[j] = e.inventory[j + 1];
            }
            e.inventory = inventories.realloc_slice(e.inventory, e.inventory.len - 1);
        }
        return true;
    }
    return false;
}

fn enqueue(h: Handle, kind: i64, count: i64) {
    if !valid(h) || count <= 0 {
        return;
    }
    let e .= entities[h.slot];
    let n = e.queue.len;
    e.queue = queues.realloc_slice(e.queue, n + 1);
    e.queue[n] = Item { kind, count };
}

fn same(a: Handle, b: Handle) -> bool {
    a.slot == b.slot && a.generation == b.generation
}

// Directed links support conveyor routes. Power callers add both directions.
fn link(a: Handle, b: Handle) {
    if !valid(a) || !valid(b) || same(a, b) {
        return;
    }
    let e .= entities[a.slot];
    for other in e.links {
        if same(other, b) {
            return;
        }
    }
    let n = e.links.len;
    e.links = edges.realloc_slice(e.links, n + 1);
    e.links[n] = b;
}

fn unlink_all(h: Handle) {
    if !valid(h) {
        return;
    }
    let owner .= entities[h.slot];
    owner.links = edges.realloc_slice(owner.links, 0);
    for &e in entities {
        if !e.alive {
            continue;
        }
        var write: i64 = 0;
        for read in e.links.len {
            if !same(e.links[read], h) {
                e.links[write] = e.links[read];
                write++;
            }
        }
        if write != e.links.len {
            e.links = edges.realloc_slice(e.links, write);
        }
        if same(e.target, h) {
            e.target = Handle {};
        }
    }
}

fn destroy(h: Handle) {
    if !valid(h) {
        return;
    }
    unlink_all(h);
    let e .= entities[h.slot];
    inventories.free_slice(e.inventory);
    queues.free_slice(e.queue);
    edges.free_slice(e.links);
    e.inventory = e.inventory[..0];
    e.queue = e.queue[..0];
    e.links = e.links[..0];
    e.alive = false;
    e.target = Handle {};
    entities.free(h.slot);
    alive_count--;
}

fn clear() {
    // Whole-world replacement needs no quadratic incoming-edge cleanup.
    for i in entities.len {
        let e .= entities[i];
        if !e.alive {
            continue;
        }
        inventories.free_slice(e.inventory);
        queues.free_slice(e.queue);
        edges.free_slice(e.links);
        e.inventory = e.inventory[..0];
        e.queue = e.queue[..0];
        e.links = e.links[..0];
        e.alive = false;
        e.target = Handle {};
        entities.free(i);
    }
    alive_count = 0;
}
