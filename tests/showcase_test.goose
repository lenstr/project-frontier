import showcase from "../src";
import persistence from "../src";
import std;
import os;

struct Resources { ferrite: i64, glacite: i64, stone: i64 }

fn add_resource(total: Resources&, kind: i64, count: i64) {
    if kind == sim::ORE {
        total.ferrite += count;
    } else if kind == sim::METAL {
        total.ferrite += count * 2;
    } else if kind == sim::CIRCUIT {
        total.ferrite += count * 2;
        total.glacite += count;
    } else if kind == sim::CRYSTAL {
        total.glacite += count;
    } else if kind == sim::STONE {
        total.stone += count;
    }
}

fn resources() -> Resources {
    var total = Resources { .. };
    for kind in 5 {
        add_resource(total, kind, sim::bag[kind]);
        add_resource(total, kind, showcase::escrow[kind]);
    }
    for e in ecs::entities {
        if !e.alive {
            continue;
        }
        for item in e.inventory {
            add_resource(total, item.kind, item.count);
        }
        if e.kind == sim::SMELTER || e.kind == sim::ASSEMBLER || e.kind == sim::MINER {
            for job in e.queue {
                add_resource(total, job.kind, job.count);
            }
        }
        if e.kind == sim::ROBOT && e.cargo_count > 0 {
            add_resource(total, e.cargo_kind, e.cargo_count);
        }
    }
    for p in sim::packets {
        if p.alive {
            add_resource(total, p.kind, p.count);
        }
    }
    total
}

fn balance() -> Resources {
    var total = resources();
    for kind in 5 {
        add_resource(total, kind, -showcase::injected[kind]);
    }
    total
}

fn same(a: Resources, b: Resources) -> bool {
    a.ferrite == b.ferrite && a.glacite == b.glacite && a.stone == b.stone
}

fn robot_count() -> i64 {
    var count: i64 = 0;
    for h in showcase::owned {
        assert(ecs::valid(h));
        if ecs::entities[h.slot].kind == sim::ROBOT {
            count++;
        }
    }
    count
}

fn assert_fixture(target: i64) {
    assert(showcase::load == target);
    assert(showcase::owned.len == target);
    assert(showcase::active_count() == target);
    for h in showcase::owned {
        let e .= ecs::entities[h.slot];
        assert(e.kind >= sim::LANDER && e.kind <= sim::STORAGE);
        assert(e.kind != sim::TOWER && e.kind != sim::MINER);
        for next in e.links {
            assert(ecs::valid(next));
        }
    }
}

fn main() {
    let start = clock();
    sim::init(73129);
    showcase::forget();
    let player_store = ecs::spawn(sim::STORAGE, sim::ground(0.0, 20.0));
    assert(ecs::add(player_store, sim::ORE, 11));
    let base = sim::base;
    let bag = sim::bag;
    let ordinary = ecs::alive_count;
    let initial = balance();
    let edits = world::edits.len;
    let depletion = sim::depleted.len;
    let day = sim::day;
    let elapsed = sim::elapsed;
    showcase::set_load(32);
    assert_fixture(32);
    assert(ecs::alive_count == ordinary + 32);
    assert(ecs::valid(base) && ecs::valid(player_store));
    assert(ecs::amount(player_store, sim::ORE) == 11);
    assert(same(initial, balance()));
    assert(world::edits.len == edits && sim::depleted.len == depletion);
    assert(sim::day == day && sim::elapsed == elapsed);
    for kind in 5 {
        assert(sim::bag[kind] == bag[kind]);
    }

    let produced_before = sim::crafted;
    let injected_before = showcase::injected;
    for frame in 10 {
        sim::tick(0.1);
    }
    assert(sim::crafted > produced_before);
    assert(!sim::objective_done);
    assert(same(initial, balance()));
    for kind in 5 {
        assert(showcase::injected[kind] == injected_before[kind]);
    }

    showcase::set_load(512);
    assert_fixture(512);
    assert(robot_count() >= 32);
    assert(ecs::alive_count == ordinary + 512);
    assert(same(initial, balance()));
    let default_robots = robot_count();
    showcase::set_load(32);
    assert_fixture(32);
    assert(same(initial, balance()));
    showcase::set_load(1024);
    assert_fixture(1024);
    assert(same(initial, balance()));
    let slots = ecs::entities.len;
    let inventory_cells = ecs::inventories.len;
    let queue_cells = ecs::queues.len;
    let edge_cells = ecs::edges.len;
    for round in 3 {
        showcase::set_load(32);
        assert(same(initial, balance()));
        showcase::set_load(1024);
        assert_fixture(1024);
        assert(ecs::entities.len == slots);
        assert(ecs::inventories.len == inventory_cells);
        assert(ecs::queues.len == queue_cells);
        assert(ecs::edges.len == edge_cells);
        assert(same(initial, balance()));
    }

    // Reusing a removed fixture slot for a player entity must never transfer
    // ownership to the replacement. The removed solar has no cargo to lose.
    let solar = showcase::owned[showcase::SPINE_NODES];
    assert(ecs::entities[solar.slot].kind == sim::SOLAR);
    ecs::destroy(solar);
    let replacement = ecs::spawn(sim::STORAGE, sim::ground(1.0, 20.0));
    assert(replacement.slot == solar.slot && replacement.generation != solar.generation);
    assert(!showcase::owns(replacement));
    showcase::set_load(1024);
    assert(ecs::valid(replacement));
    assert_fixture(1024);
    assert(same(initial, balance()));

    // Pending cargo involving player endpoints is settled exactly once.
    let removed_source = showcase::owned[showcase::owned.len - 1];
    assert(ecs::add(player_store, sim::STONE, 3));
    assert(ecs::take(player_store, sim::STONE, 1));
    sim::packets.alloc_index(sim::Packet {
        alive: true, source: player_store, dest: removed_source,
        kind: sim::STONE, count: 1, t: 0.4
    });
    assert(ecs::add(removed_source, sim::STONE, 2));
    assert(ecs::take(removed_source, sim::STONE, 1));
    sim::packets.alloc_index(sim::Packet {
        alive: true, source: removed_source, dest: player_store,
        kind: sim::STONE, count: 1, t: 0.4
    });
    let before_cleanup = balance();
    showcase::set_load(32);
    assert(same(before_cleanup, balance()));
    assert(ecs::amount(player_store, sim::STONE) == 4);
    assert(ecs::valid(replacement) && ecs::valid(base));

    showcase::set_load(2000);
    assert_fixture(2000);
    assert(same(before_cleanup, balance()));
    showcase::clear();
    assert(showcase::owned.len == 0 && showcase::active_count() == 0);
    assert(!showcase::enabled && showcase::load == 0);
    assert(ecs::alive_count == ordinary + 1);
    assert(ecs::valid(replacement) && ecs::valid(player_store) && ecs::valid(base));
    assert(same(before_cleanup, balance()));
    assert(world::edits.len == edits && sim::depleted.len == depletion);
    assert(showcase::flush_escrow());
    for kind in 5 {
        assert(showcase::escrow[kind] == 0);
    }
    assert(same(before_cleanup, balance()));

    // Save-compatible entities keep normal identity; forget never guesses
    // ownership of a restored district or destroys existing structures.
    showcase::set_load(32);
    assert(showcase::flush_escrow());
    var image = save::capture();
    assert(image.len == 1);
    let saved_resources = resources();
    for record in image {
        assert(save::valid_image(record));
        save::restore(record);
    }
    let restored_live = ecs::alive_count;
    showcase::forget();
    showcase::clear();
    assert(ecs::alive_count == restored_live);
    assert(same(saved_resources, resources()));
    sim::shutdown();
    print("showcase: PASS; exact32/512/1024/2000 loads, default_robots=", default_robots,
          ", finite real production, conservation/packet settlement, player ownership, pool plateau, save/forget; elapsed_ms=", (clock() - start) * 1000.0);
}
