import sim from "../src";
import std;
import os;
import math;

fn advance(seconds: f32) {
    let frames = (seconds * 20.0) as! i64;
    for i in frames {
        sim::tick(0.05);
    }
}

fn visit(x: f32, z: f32) {
    sim::player = sim::ground(x, z);
}

fn total_stone() -> i64 {
    var count = sim::bag[sim::STONE];
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive {
            continue;
        }
        count += ecs::amount(sim::handle(i), sim::STONE);
        if e.kind == sim::ROBOT && e.cargo_kind == sim::STONE {
            count += e.cargo_count;
        }
    }
    for p in sim::packets {
        if p.alive && p.kind == sim::STONE {
            count += p.count;
        }
    }
    count
}

fn main() {
    let started = clock();
    sim::init(73129);
    assert(ecs::valid(sim::base));
    assert(sim::bag[sim::METAL] == 18 && sim::bag[sim::CRYSTAL] == 6);
    visit(5.0, 6.0);
    let ore = sim::nearest(sim::player, 6.0, sim::DEPOSIT_ORE);
    assert(ecs::valid(ore));
    let before = ecs::entities[ore.slot].cargo_count;
    for i in 6 {
        assert(sim::mine(ore));
        advance(0.2);
    }
    assert(ecs::entities[ore.slot].cargo_count == before - 6);
    assert(sim::manual_smelt());
    assert(sim::manual_circuit());
    let height = world::height(5.0, 7.0);
    sim::dig(5.0, 7.0, -0.5);
    assert(world::height(5.0, 7.0) < height);
    assert(sim::bag[sim::STONE] == 25);
    sim::stream_deposits(1000.0, 1000.0);
    sim::stream_deposits(0.0, 0.0);
    let revisited = sim::nearest(sim::ground(8.0, 6.0), 1.0, sim::DEPOSIT_ORE);
    assert(ecs::valid(revisited));
    assert(ecs::entities[revisited.slot].cargo_count == before - 6);

    let miner = sim::build(sim::MINER, sim::ground(8.0, 4.0));
    let smelter = sim::build(sim::SMELTER, sim::ground(4.0, 7.0));
    let crystal = sim::build(sim::MINER, sim::ground(-8.0, 8.0));
    let solar = sim::build(sim::SOLAR, sim::ground(-4.0, 0.0));
    assert(ecs::valid(miner) && ecs::valid(smelter) && ecs::valid(crystal) && ecs::valid(solar));
    assert(sim::link(miner, smelter));
    assert(sim::link(smelter, sim::base));
    assert(sim::link(crystal, sim::base));
    assert(!sim::link(miner, smelter));
    visit(0.0, 5.0);
    advance(35.0);
    assert(ecs::entities[miner.slot].powered && ecs::entities[smelter.slot].powered);
    assert(sim::crafted > 2);
    assert(nav::path_calls > nav::path_failed);
    assert(sim::collect(sim::base));
    let assembler = sim::build(sim::ASSEMBLER, sim::ground(-4.0, 6.0));
    assert(ecs::valid(assembler));
    assert(sim::link(smelter, assembler));
    assert(sim::link(crystal, assembler));
    assert(sim::link(assembler, sim::base));
    // All further circuits come from the integrated automatic production line.
    for interval in 12 {
        advance(10.0);
        sim::collect(sim::base);
    }
    sim::collect(assembler);
    assert(sim::bag[sim::METAL] >= 20);
    assert(sim::bag[sim::CRYSTAL] >= 10);
    assert(sim::bag[sim::CIRCUIT] >= 8);
    let tower = sim::build(sim::TOWER, sim::ground(0.0, 14.0));
    assert(ecs::valid(tower));
    advance(46.0);
    assert(ecs::entities[tower.slot].powered);
    assert(sim::objective_done);
    assert(ecs::entities[tower.slot].progress == 1.0);
    print(
        "progression: PASS; automatic craft count=", sim::crafted,
        " paths=", nav::path_calls, " failed_paths=", nav::path_failed,
        " route_ms=", nav::path_ms, " game_seconds=", sim::elapsed
    );

    // Verify transport by autonomous navigation without any logistics rails.
    sim::init(73129);
    let robot_store = ecs::spawn(sim::STORAGE, sim::ground(12.0, 8.0));
    assert(ecs::add(robot_store, sim::STONE, 12));
    advance(30.0);
    assert(ecs::amount(sim::base, sim::STONE) >= 4);

    // Independent brownout and conservation scenarios use a resource-rich
    // fixture after the public gameplay progression has already succeeded.
    sim::init(73129);
    sim::day = 0.75;
    let a = ecs::spawn(sim::SMELTER, sim::ground(6.0, 5.0));
    let b = ecs::spawn(sim::ASSEMBLER, sim::ground(0.0, 9.0));
    let c = ecs::spawn(sim::TOWER, sim::ground(-5.0, 4.0));
    let isolated = ecs::spawn(sim::MINER, sim::ground(100.0, 100.0));
    sim::tick(0.05);
    assert(sim::supply == 8.0 && sim::demand == 16.0);
    let allocated = (if ecs::entities[a.slot].powered { 3 } else { 0 })
        + (if ecs::entities[b.slot].powered { 3 } else { 0 })
        + (if ecs::entities[c.slot].powered { 8 } else { 0 });
    assert(allocated <= 8 && allocated > 0);
    assert(!(
        ecs::entities[a.slot].powered && ecs::entities[b.slot].powered && ecs::entities[c.slot].powered
    ));
    assert(!ecs::entities[isolated.slot].powered);
    for i in ecs::entities.len {
        if ecs::entities[i].alive && ecs::entities[i].kind == sim::ROBOT {
            ecs::destroy(sim::handle(i));
        }
    }
    let store = ecs::spawn(sim::STORAGE, sim::ground(20.0, 0.0));
    let sink = ecs::spawn(sim::STORAGE, sim::ground(24.0, 0.0));
    ecs::link(store, sink);
    assert(ecs::add(store, sim::STONE, 30));
    let original = total_stone();
    sim::dispatch_clock = 0.0;
    sim::tick(0.05);
    assert(total_stone() == original);
    ecs::destroy(sink);
    sim::tick(0.05);
    assert(total_stone() == original);
    let sink2 = ecs::spawn(sim::STORAGE, sim::ground(24.0, 0.0));
    ecs::link(store, sink2);
    sim::dispatch_clock = 0.0;
    sim::tick(0.05);
    visit(20.0, 0.0);
    assert(sim::collect(store));
    ecs::destroy(store);
    advance(2.0);
    assert(total_stone() == original);
    assert(ecs::amount(sink2, sim::STONE) == 1);

    let entities_before = ecs::alive_count;
    sim::stress_spawn(1000);
    assert(ecs::alive_count == entities_before + 1000);
    let slots = ecs::entities.len;
    sim::stress_destroy(1000);
    assert(ecs::alive_count == entities_before);
    sim::stress_spawn(1000);
    assert(ecs::entities.len == slots);
    sim::stress_destroy(1000);
    sim::shutdown();
    print(
        "gameplay: PASS; packet conservation, component brownouts, 1000-object reuse; elapsed_ms=",
        (clock() - started) * 1000.0
    );
}
