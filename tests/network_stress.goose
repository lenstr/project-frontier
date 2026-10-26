// Deterministic production scaling fixture. Rendering is deliberately absent:
// these times measure simulation, logistics and robot pathfinding only.
import sim from "../src";
import std;
import math;
import os;

let CELLS = 200;
let TICKS = 600;
let WARMUP = 60;
let ROBOTS = 32;
let CHURN = 1000;
let CHURN_ROUNDS = 10;

struct Resources { ferrite: i64, glacite: i64, stone: i64 }

fn account(total: Resources&, kind: i64, count: i64) {
    if kind == sim::ORE {
        total.ferrite += count;
    }
    if kind == sim::METAL {
        total.ferrite += count * 2;
    }
    if kind == sim::CIRCUIT {
        total.ferrite += count * 2;
        total.glacite += count;
    }
    if kind == sim::CRYSTAL {
        total.glacite += count;
    }
    if kind == sim::STONE {
        total.stone += count;
    }
}

fn resources() -> Resources {
    var total = Resources { .. };
    for kind in 5 {
        account(total, kind, sim::bag[kind]);
    }
    for e in ecs::entities {
        if !e.alive {
            continue;
        }
        for item in e.inventory {
            account(total, item.kind, item.count);
        }
        if e.kind == sim::SMELTER || e.kind == sim::ASSEMBLER || e.kind == sim::MINER {
            // The output recipe in the queue owns inputs already consumed.
            for job in e.queue {
                account(total, job.kind, job.count);
            }
        }
        if e.kind == sim::ROBOT && e.cargo_count > 0 {
            account(total, e.cargo_kind, e.cargo_count);
        }
    }
    for p in sim::packets {
        if p.alive {
            account(total, p.kind, p.count);
        }
    }
    total
}

fn same(a: Resources, b: Resources) -> bool {
    a.ferrite == b.ferrite && a.glacite == b.glacite && a.stone == b.stone
}

fn packet_count() -> i64 {
    var count: i64 = 0;
    for p in sim::packets {
        if p.alive {
            count++;
        }
    }
    count
}

fn queue_count() -> i64 {
    var count: i64 = 0;
    for e in ecs::entities {
        if e.alive {
            count += e.queue.len;
        }
    }
    count
}

fn create(kind: i64, x: f32, z: f32) -> ecs::Handle {
    ecs::spawn(kind, sim::ground(x, z))
}

fn verify_power_cache() {
    sim::init(73129);
    sim::update_power();
    var rebuilds = sim::power_rebuilds;
    sim::update_power();
    assert(sim::power_rebuilds == rebuilds);
    let consumer = create(sim::MINER, 100.0, 100.0);
    sim::update_power();
    rebuilds++;
    assert(sim::power_rebuilds == rebuilds && !ecs::entities[consumer.slot].powered);
    let generator = create(sim::SOLAR, 104.0, 100.0);
    sim::update_power();
    rebuilds++;
    assert(sim::power_rebuilds == rebuilds && ecs::entities[consumer.slot].powered);
    // Direct coordinate edits must invalidate; no ECS notification is needed.
    ecs::entities[generator.slot].pos.x = 140.0;
    sim::update_power();
    rebuilds++;
    assert(sim::power_rebuilds == rebuilds && !ecs::entities[consumer.slot].powered);
    ecs::entities[generator.slot].pos.x = 104.0;
    sim::update_power();
    rebuilds++;
    assert(sim::power_rebuilds == rebuilds && ecs::entities[consumer.slot].powered);
    ecs::destroy(generator);
    sim::update_power();
    rebuilds++;
    assert(sim::power_rebuilds == rebuilds && !ecs::entities[consumer.slot].powered);
    let replacement = create(sim::SOLAR, 104.0, 100.0);
    assert(replacement.slot == generator.slot && replacement.generation != generator.generation);
    sim::update_power();
    rebuilds++;
    assert(sim::power_rebuilds == rebuilds && ecs::entities[consumer.slot].powered);
    ecs::entities[replacement.slot].kind = sim::STORAGE;
    sim::update_power();
    rebuilds++;
    assert(sim::power_rebuilds == rebuilds && !ecs::entities[consumer.slot].powered);
    ecs::entities[replacement.slot].kind = sim::SOLAR;
    ecs::entities[consumer.slot].kind = sim::SMELTER;
    sim::update_power();
    rebuilds++;
    assert(ecs::entities[consumer.slot].powered);
    sim::day = 0.75;
    sim::update_power();
    assert(sim::power_rebuilds == rebuilds && !ecs::entities[consumer.slot].powered);
    sim::day = 0.18;
    sim::update_power();
    assert(sim::power_rebuilds == rebuilds && ecs::entities[consumer.slot].powered);
    sim::after_load(73129);
    sim::update_power();
    rebuilds++;
    assert(sim::power_rebuilds == rebuilds && ecs::entities[consumer.slot].powered);
}

fn verify_raster() {
    let ignored = create(sim::SOLAR, 5.35, 2.65);
    create(sim::LANDER, -4.1, -3.9);
    create(sim::RELAY, -7.0, 4.0);
    let robot = sim::spawn_robot(sim::ground(2.3, 3.7));
    for pass in 4 {
        let ox: i64 = if pass < 2 { -12 } else { 22 };
        let oz: i64 = if pass < 2 { -12 } else { -50 };
        let goal = if pass % 2 == 0 { ignored } else { ecs::Handle {} };
        var raster: bool[nav::COUNT] = [false; nav::COUNT];
        nav::rasterize(ox, oz, robot, goal, raster);
        for z in nav::GRID {
            for x in nav::GRID {
                let wx: f32 = (ox + x) * nav::STEP;
                let wz: f32 = (oz + z) * nav::STEP;
                assert(raster[z * nav::GRID + x] == nav::obstacle(wx, wz, robot, goal));
            }
        }
    }
}

fn main() {
    var configuration: u8[>..] = [];
    if arg_count() > 1 {
        arg(1, configuration);
    } else {
        configuration.append("unspecified");
    }
    if configuration == "verify" {
        verify_power_cache();
        verify_raster();
        sim::shutdown();
        print("network optimizations: PASS; exact obstacle raster and power topology invalidation");
        return;
    }
    sim::init(73129);
    // No mineral extraction occurs in this finite-resource fixture. Stream
    // deposits away from the production cells so accidental mining is visible.
    sim::player = sim::ground(-512.0, -512.0);
    sim::stream_deposits(sim::player.x, sim::player.z);
    // The tutorial rover is replaced by exactly ROBOTS fixture workers.
    for i in ecs::entities.len {
        if ecs::entities[i].alive && ecs::entities[i].kind == sim::ROBOT {
            ecs::destroy(sim::handle(i));
        }
    }
    var sources: ecs::Handle[>..] = [];
    for cell in CELLS {
        let x: f32 = 128.0 + (cell % 20) * 32.0;
        let z: f32 = 128.0 + (cell / 20) * 32.0;
        let ore = create(sim::STORAGE, x, z);
        let smelter = create(sim::SMELTER, x + 4.0, z);
        let assembler = create(sim::ASSEMBLER, x + 8.0, z);
        let output = create(sim::STORAGE, x + 12.0, z);
        create(sim::SOLAR, x + 2.0, z + 5.0);
        create(sim::SOLAR, x + 8.0, z + 5.0);
        create(sim::RELAY, x + 14.0, z + 5.0);
        let crystal = create(sim::STORAGE, x, z + 8.0);
        let alloy_output = create(sim::STORAGE, x + 4.0, z + 12.0);
        create(sim::SOLAR, x + 12.0, z + 12.0);
        assert(ecs::add(ore, sim::ORE, 96));
        assert(ecs::add(crystal, sim::CRYSTAL, 64));
        assert(ecs::add(smelter, sim::ORE, 4));
        assert(ecs::add(assembler, sim::METAL, 2));
        assert(ecs::add(assembler, sim::CRYSTAL, 2));
        ecs::link(ore, smelter);
        ecs::link(smelter, assembler);
        ecs::link(smelter, alloy_output);
        ecs::link(crystal, assembler);
        ecs::link(assembler, output);
        sources.push(ore);
        if cell < ROBOTS {
            sim::spawn_robot(sim::ground(x - 3.0, z + 3.0));
        }
    }
    let initial = resources();
    let dt: f32 = 1.0 / 60.0;
    for i in WARMUP {
        sim::tick(dt);
    }
    assert(same(initial, resources()));
    let crafted_before = sim::crafted;
    let paths_before = nav::path_calls;
    let failures_before = nav::path_failed;
    let navigation_before = nav::path_ms;
    let topology_before = sim::power_rebuilds;
    let active = ecs::alive_count;
    var times: f64[>..] = [];
    var sum: f64 = 0.0;
    var peak_packets: i64 = packet_count();
    var peak_queues: i64 = queue_count();
    let start = clock();
    for frame in TICKS {
        let tick_start = clock();
        sim::tick(dt);
        let milliseconds = (clock() - tick_start) * 1000.0;
        times.push(milliseconds);
        sum += milliseconds;
        peak_packets = max(peak_packets, packet_count());
        peak_queues = max(peak_queues, queue_count());
        if frame % 60 == 0 {
            assert(same(initial, resources()));
        }
    }
    let wall_ms = (clock() - start) * 1000.0;
    assert(same(initial, resources()));
    assert(sim::crafted - crafted_before >= CELLS * 4);
    assert(peak_packets >= CELLS);
    assert(ecs::alive_count == active);
    sort(times);
    let mean = sum / TICKS;
    let p50 = times[TICKS / 2];
    let p95 = times[(TICKS * 95) / 100];
    let p99 = times[(TICKS * 99) / 100];
    let maximum = times[times.len - 1];
    let measured_paths = nav::path_calls - paths_before;
    let measured_failures = nav::path_failed - failures_before;
    let measured_navigation_ms = nav::path_ms - navigation_before;
    let measured_topology_rebuilds = sim::power_rebuilds - topology_before;
    assert(measured_topology_rebuilds == 0);
    let production_crafted = sim::crafted - crafted_before;
    let measured_inventory_cells = ecs::inventories.len;
    let measured_queue_cells = ecs::queues.len;
    let measured_edge_cells = ecs::edges.len;
    let measured_entity_slots = ecs::entities.len;
    let measured_packet_slots = sim::packets.len;

    // Churn actual inventory-bearing, linked structures; borrow and return
    // their cargo so resource conservation remains meaningful throughout.
    var slot_plateau: i64 = 0;
    var inventory_plateau: i64 = 0;
    var edge_plateau: i64 = 0;
    let churn_start = clock();
    for round in CHURN_ROUNDS {
        var transient: ecs::Handle[>..] = [];
        for i in CHURN {
            let h = create(sim::STORAGE, -1200.0 + (i % 40) * 3.0, -1200.0 + (i / 40) * 3.0);
            let source = sources[i % sources.len];
            assert(ecs::take(source, sim::ORE, 1));
            assert(ecs::add(h, sim::ORE, 1));
            ecs::link(h, source);
            transient.push(h);
        }
        if round == 0 {
            slot_plateau = ecs::entities.len;
            inventory_plateau = ecs::inventories.len;
            edge_plateau = ecs::edges.len;
        } else {
            assert(ecs::entities.len == slot_plateau);
            assert(ecs::inventories.len == inventory_plateau);
            assert(ecs::edges.len == edge_plateau);
        }
        assert(same(initial, resources()));
        for i in transient.len {
            assert(ecs::take(transient[i], sim::ORE, 1));
            assert(ecs::add(sources[i % sources.len], sim::ORE, 1));
            ecs::destroy(transient[i]);
            assert(!ecs::valid(transient[i]));
        }
        assert(ecs::alive_count == active);
        assert(same(initial, resources()));
    }
    let churn_ms = (clock() - churn_start) * 1000.0;

    verify_power_cache();
    verify_raster();

    assert(make_dir("artifacts"));
    var json: u8[>..] = [];
    format(
        json, "{\n  \"fixture\": \"finite resources, queued recipes, rails, solar grids, robots\",\n",
        "  \"build_configuration\": \"", configuration, "\",\n",
        "  \"rendering\": false,\n  \"seed\": 73129,\n  \"production_cells\": ", CELLS,
        ",\n  \"structures\": ", CELLS * 10 + 2, ",\n  \"robots\": ", ROBOTS,
        ",\n  \"active_entities\": ", active, ",\n  \"active_production_machines\": ", CELLS * 2,
        ",\n  \"warmup_ticks\": ", WARMUP, ",\n  \"measured_ticks\": ", TICKS,
        ",\n  \"tick_dt_seconds\": ", dt, ",\n  \"tick_mean_ms\": ", mean,
        ",\n  \"tick_p50_ms\": ", p50, ",\n  \"tick_p95_ms\": ", p95,
        ",\n  \"tick_p99_ms\": ", p99, ",\n  \"tick_max_ms\": ", maximum,
        ",\n  \"measured_wall_ms\": ", wall_ms, ",\n  \"crafted_outputs\": ", production_crafted,
        ",\n  \"peak_live_packets\": ", peak_packets, ",\n  \"peak_live_queue_entries\": ", peak_queues,
        ",\n  \"path_calls\": ", measured_paths, ",\n  \"path_failures\": ", measured_failures,
        ",\n  \"path_total_ms\": ", measured_navigation_ms,
        ",\n  \"power_topology_rebuilds\": ", measured_topology_rebuilds,
        ",\n  \"entity_slots\": ", measured_entity_slots,
        ",\n  \"inventory_pool_cells\": ", measured_inventory_cells,
        ",\n  \"queue_pool_cells\": ", measured_queue_cells,
        ",\n  \"edge_pool_cells\": ", measured_edge_cells,
        ",\n  \"packet_pool_slots\": ", measured_packet_slots,
        ",\n  \"churn_spawns\": ", CHURN * CHURN_ROUNDS, ",\n  \"churn_destroys\": ", CHURN * CHURN_ROUNDS,
        ",\n  \"churn_ms\": ", churn_ms, ",\n  \"churn_entity_slots_plateau\": ", slot_plateau,
        ",\n  \"churn_inventory_cells_plateau\": ", inventory_plateau,
        ",\n  \"churn_edge_cells_plateau\": ", edge_plateau,
        ",\n  \"conservation_ferrite_units\": ", initial.ferrite,
        ",\n  \"conservation_glacite_units\": ", initial.glacite,
        ",\n  \"conservation_stone_units\": ", initial.stone,
        ",\n  \"resource_conservation\": true,\n  \"pool_plateau\": true\n}\n"
    );
    if configuration == "debug" {
        assert(write_file("artifacts/network-stress-debug.json", json));
    } else {
        assert(write_file("artifacts/network-stress.json", json));
    }
    print(
        "network stress: PASS; ", active, " entities, ", CELLS * 2, " active production machines, ",
        ROBOTS, " robots"
    );
    print("simulation tick ms: mean=", mean, " p50=", p50, " p95=", p95, " p99=", p99, " max=", maximum);
    print(
        "production=", production_crafted, " peak_packets=", peak_packets, " peak_queue_entries=", peak_queues,
        " paths=", measured_paths, " failed_paths=", measured_failures,
        " path_total_ms=", measured_navigation_ms
    );
    print(
        "conservation: ferrite=", initial.ferrite, " glacite=", initial.glacite, " stone=", initial.stone,
        "; churn=", CHURN * CHURN_ROUNDS, " reused structures, plateau slots=", slot_plateau,
        " inventory_cells=", inventory_plateau, " edge_cells=", edge_plateau, " churn_ms=", churn_ms
    );
    sim::shutdown();
}
