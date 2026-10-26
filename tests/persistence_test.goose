import std;
import vec;
import math;
import os;
import persistence from "../src";

fn raw_image(path: const u8[:], image: save::GameImage[>..]&) {
    var payload: u8[>..] = image.to_bytes();
    var envelope: save::Envelope[>..] = [];
    envelope.push(save::Envelope { save::MAGIC, save::VERSION, save::checksum(payload), copy(payload) });
    assert(write_file(path, envelope.to_bytes()));
}

fn main() {
    let path = "/tmp/frontier-persistence-test.sav";
    let badpath = "/tmp/frontier-persistence-bad.sav";
    world::init(73129);
    ecs::clear();
    sim::clear_packets();
    sim::depleted.clear();
    sim::base = ecs::spawn(1, float3 { 0.0, 1.8, 0.0 });
    let miner = ecs::spawn(2, float3 { 8.0, 1.8, 2.0 });
    let hole = ecs::spawn(90, float3_0);
    let smelter = ecs::spawn(3, float3 { 12.0, 1.8, 2.0 });
    let robot = ecs::spawn(7, float3 { 10.0, 1.8, -4.0 });
    ecs::destroy(hole);
    assert(ecs::add(miner, 0, 43));
    assert(ecs::add(smelter, 2, 11));
    ecs::enqueue(smelter, 2, 3);
    ecs::enqueue(robot, -825, 1750);
    ecs::link(miner, smelter);
    ecs::link(smelter, sim::base);
    ecs::entities[robot.slot].target = miner;
    ecs::entities[robot.slot].cargo_kind = 1;
    ecs::entities[robot.slot].cargo_count = 6;
    ecs::entities[robot.slot].state = 2;
    ecs::entities[robot.slot].timer = -0.4;
    ecs::entities[smelter.slot].progress = 0.64;
    ecs::entities[smelter.slot].powered = true;
    sim::packets.alloc_ref(sim::Packet {
        alive: true, source: miner, dest: smelter, kind: 0, count: 2, t: 0.37,
    });
    sim::packets.alloc_ref(sim::Packet {
        alive: true, source: ecs::Handle {}, dest: smelter, kind: 1, count: 3, t: 0.41,
    });
    sim::packets.alloc_ref(sim::Packet {
        alive: true, source: miner, dest: ecs::Handle {}, kind: 0, count: 4, t: 0.73,
    });
    // Generated deposits and stress objects must not leak into save snapshots.
    ecs::spawn(20, float3 { 25.0, 3.0, 20.0 });
    ecs::spawn(90, float3 { 35.0, 3.0, 20.0 });
    world::edit(-2.0, -2.0, -0.75);
    let saved_height = world::height(-2.0, -2.0);
    sim::depleted.push(sim::Depletion { 10, -12, 27 });
    sim::player = float3 { 8.0, 2.0, -4.0 };
    sim::bag = [20, 10, 7, 6, 5];
    sim::day = 0.42;
    sim::elapsed = 123.25;
    sim::crafted = 13;
    sim::objective_done = true;
    let saved_base = sim::base;
    assert(save::write(path));
    assert(ecs::amount(miner, 0) == 43);
    assert(ecs::alive_count == 6);
    let bytes = save::last_bytes;

    // Disturb allocator order and make it larger than the saved slot range.
    ecs::clear();
    for i in 1000 {
        ecs::spawn(90, float3_0);
    }
    ecs::clear();
    sim::clear_packets();
    world::edits.clear();
    sim::bag = [0; 5];
    sim::objective_done = false;
    assert(save::load(path));
    assert(ecs::alive_count == 4);
    assert(ecs::same(saved_base, sim::base));
    assert(ecs::valid(miner) && ecs::valid(smelter) && ecs::valid(robot));
    assert(ecs::amount(miner, 0) == 43 && ecs::amount(smelter, 2) == 11);
    assert(ecs::entities[smelter.slot].progress == 0.64);
    assert(ecs::entities[smelter.slot].powered);
    assert(ecs::entities[smelter.slot].queue.len == 1);
    assert(ecs::entities[smelter.slot].queue[0].count == 3);
    assert(ecs::entities[robot.slot].queue[0].kind == -825);
    assert(ecs::entities[robot.slot].queue[0].count == 1750);
    assert(ecs::entities[robot.slot].cargo_count == 6);
    assert(ecs::entities[robot.slot].timer == -0.4);
    assert(ecs::same(ecs::entities[robot.slot].target, miner));
    assert(ecs::same(ecs::entities[miner.slot].links[0], smelter));
    assert(sim::bag == [20, 10, 7, 6, 5]);
    assert(sim::objective_done && sim::crafted == 13);
    assert(sim::depleted.len == 1 && sim::depleted[0].left == 27);
    assert(abs(world::height(-2.0, -2.0) - saved_height) < 0.0001);
    var packet_count: i64 = 0;
    for p in sim::packets {
        if p.alive {
            packet_count++;
            assert(
                (p.t == 0.37 && p.count == 2 && ecs::same(p.dest, smelter))
                    || (p.t == 0.41 && p.count == 3 && p.source.slot == -1)
                    || (p.t == 0.73 && p.count == 4 && p.dest.slot == -1),
            );
        }
    }
    assert(packet_count == 3);

    var file: u8[>..] = [];
    assert(read_file(path, file));
    file[file.len - 1] = file[file.len - 1] ^ 1;
    assert(write_file(badpath, file));
    assert(!save::load(badpath));
    assert(ecs::amount(miner, 0) == 43 && sim::bag[0] == 20);
    assert(write_file(badpath, file[..file.len - 1]));
    assert(!save::load(badpath));
    assert(ecs::same(sim::base, saved_base));
    // Recompute a correct checksum around invalid semantic data.
    var images = save::capture();
    for image in images {
        image.player.x = 2000000.0;
    }
    raw_image(badpath, images);
    assert(!save::load(badpath));
    assert(sim::player.x == 8.0);
    for image in images {
        image.player.x = 8.0;
        image.base.generation = 0;
    }
    raw_image(badpath, images);
    assert(!save::load(badpath));
    assert(ecs::valid(sim::base));
    // Repeated loads reuse all entity and collection storage.
    let slots = ecs::entities.len;
    let inventory_cells = ecs::inventories.len;
    let queue_cells = ecs::queues.len;
    let edge_cells = ecs::edges.len;
    let packet_slots = sim::packets.len;
    for i in 50 {
        assert(save::load(path));
        assert(
            ecs::entities.len == slots
                && ecs::inventories.len == inventory_cells
                && ecs::queues.len == queue_cells
                && ecs::edges.len == edge_cells
                && sim::packets.len == packet_slots,
        );
    }
    assert(ecs::amount(miner, 0) == 43);
    sim::dispatch_clock = 100.0;
    sim::transport(1.0);
    assert(ecs::amount(miner, 0) == 47);
    assert(ecs::amount(smelter, 0) == 2);
    assert(ecs::amount(smelter, 1) == 3);
    world::shutdown();
    delete_file(path);
    delete_file(badpath);
    print(
        "persistence: PASS; snapshot_bytes=", bytes,
        " preserved_live=", ecs::alive_count, " pool_slots=", slots,
        " repeated_loads=50, checksum/truncation/semantic rejection leave state intact",
    );
}
