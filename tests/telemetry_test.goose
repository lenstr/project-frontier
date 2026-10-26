import telemetry from "../src";
import std;
import os;

fn test_history() {
    stats::reset_history();
    assert(stats::count == 0);
    assert(stats::cursor == 0);
    assert(stats::mean_ms == 0.0 && stats::p99_ms == 0.0);
    stats::record(stats::Frame {
        frame_ms: 10.0,
        simulation_ms: 3.0,
        power_ms: 1.0,
        ..
    });
    assert(stats::count == 1 && stats::total_frames == 1);
    assert(stats::cursor == 1 && stats::latest.simulation_ms == 3.0);
    assert(stats::mean_ms == 10.0 && stats::p50_ms == 10.0);
    for i in 2..301 {
        stats::record(stats::Frame { frame_ms: i, .. });
    }
    stats::refresh();
    assert(stats::count == 240 && stats::cursor == 60);
    assert(stats::total_frames == 300);
    assert(stats::sample(0).frame_ms == 61.0);
    assert(stats::sample(239).frame_ms == 300.0);
    assert(stats::mean_ms == 180.5);
    assert(stats::p50_ms == 180.0);
    assert(stats::p95_ms == 288.0);
    assert(stats::p99_ms == 298.0);

    stats::reset_history();
    for i in 100 {
        stats::record(stats::Frame { frame_ms: 10.0, .. });
    }
    assert(stats::refresh_count >= 3 && stats::refresh_count <= 5);
    assert(abs(stats::uptime - 1.0) < 0.000001);

    stats::reset_history();
    let payload = bytes_of(stats::history).len;
    for i in 5000 {
        stats::record(stats::Frame { frame_ms: 16.0, .. });
    }
    stats::refresh();
    assert(stats::count == 240 && stats::total_frames == 5000);
    assert(stats::cursor == 200);
    assert(stats::mean_ms == 16.0 && stats::p99_ms == 16.0);
    assert(bytes_of(stats::history).len == payload);
}

fn test_counts_and_reuse() {
    sim::init(73129);
    for i in 2 {
        world::stream(0.0, 0.0, 1, 8);
        world::drain();
    }
    stats::reset_history();
    stats::refresh();
    assert(stats::counters.active_entities == ecs::alive_count);
    assert(stats::counters.robots == 1);
    assert(stats::counters.buildings == 2);
    assert(stats::counters.production_machines == 0);
    assert(stats::counters.deposits == 121);
    assert(stats::counters.chunk_live == 9 && stats::counters.chunks_ready == 9);
    assert(stats::counters.terrain_jobs == 0);
    assert(stats::counters.stale_handles_rejected == -1);
    assert(stats::counters.worker_generation_ms == world::generation_total_ms);
    assert(stats::counters.queue_transfer_ms == world::transfer_ms);
    assert(stats::counters.queue_wait_ms == world::wait_ms);

    let store = ecs::spawn(sim::STORAGE, sim::ground(20.0, 0.0));
    let factory = ecs::spawn(sim::SMELTER, sim::ground(24.0, 0.0));
    assert(ecs::add(store, sim::ORE, 7));
    assert(ecs::add(store, sim::CRYSTAL, 3));
    ecs::enqueue(factory, sim::METAL, 1);
    ecs::link(store, factory);
    let packet = sim::packets.alloc_index(sim::Packet {
        alive: true,
        source: store,
        dest: factory,
        kind: sim::ORE,
        count: 1,
        t: 0.25
    });
    stats::refresh();
    assert(stats::counters.buildings == 4);
    assert(stats::counters.production_machines == 1);
    assert(stats::counters.inventory_live == 2);
    assert(stats::counters.queue_live == 1);
    assert(stats::counters.edge_live == 1);
    assert(stats::counters.live_packets == 1);
    assert(stats::counters.payload_estimate_bytes > bytes_of(stats::history).len);
    let entity_slots = stats::counters.entity_slots;
    let inventory_cells = stats::counters.inventory_cells;
    let queue_cells = stats::counters.queue_cells;
    let edge_cells = stats::counters.edge_cells;
    let packet_slots = stats::counters.packet_slots;

    ecs::destroy(store);
    sim::packets[packet].alive = false;
    sim::packets.free(packet);
    stats::refresh();
    assert(stats::counters.free_entity_slots >= 1);
    assert(stats::counters.inventory_live == 0);
    assert(stats::counters.inventory_free == inventory_cells);
    assert(stats::counters.edge_live == 0);
    assert(stats::counters.edge_free == edge_cells);
    assert(stats::counters.live_packets == 0);
    assert(stats::counters.free_packet_slots == packet_slots);
    assert(stats::high_water.inventory_live == 2);
    assert(stats::high_water.live_packets == 1);

    let replacement = ecs::spawn(sim::STORAGE, sim::ground(20.0, 0.0));
    assert(replacement.slot == store.slot && replacement.generation != store.generation);
    assert(!ecs::valid(store));
    assert(ecs::add(replacement, sim::ORE, 7));
    assert(ecs::add(replacement, sim::CRYSTAL, 3));
    ecs::link(replacement, factory);
    let reused_packet = sim::packets.alloc_index(sim::Packet {
        alive: true,
        source: replacement,
        dest: factory,
        kind: sim::ORE,
        count: 1,
        t: 0.25
    });
    assert(reused_packet == packet);
    stats::refresh();
    assert(stats::counters.entity_slots == entity_slots);
    assert(stats::counters.inventory_cells == inventory_cells);
    assert(stats::counters.queue_cells == queue_cells);
    assert(stats::counters.edge_cells == edge_cells);
    assert(stats::counters.packet_slots == packet_slots);
    assert(stats::counters.inventory_live == 2);
    assert(stats::counters.edge_live == 1);
    assert(stats::counters.live_packets == 1);
    sim::clear_packets();
    ecs::clear();
    stats::refresh();
    assert(stats::counters.active_entities == 0);
    assert(stats::counters.free_entity_slots == entity_slots);
    assert(stats::high_water.active_entities > stats::counters.active_entities);
    sim::shutdown();
}

fn test_stage_summaries() {
    stats::reset_history();
    for i in 240 {
        stats::record(stats::Frame {
            frame_ms: 20.0,
            input_ms: 1.0,
            simulation_ms: 4.0,
            power_ms: 1.0,
            production_ms: 2.0,
            transport_ms: 0.5,
            robots_ms: 0.5,
            stream_ms: 3.0,
            mesh_ms: 2.0,
            render_ms: 7.0,
            ui_ms: 2.0,
            gpu_wait_ms: 1.0,
        });
    }
    stats::refresh();
    assert(stats::stage_order[0] == 8);
    assert(stats::stage_summaries[8].average_ms == 7.0);
    assert(stats::stage_summaries[8].p95_ms == 7.0);
    assert(stats::stage_summaries[8].share_percent == 35.0);
    assert(stats::stage_summaries[1].share_percent == 20.0);
    let observations = stats::refresh_count;
    stats::record(stats::Frame { frame_ms: 1.0, render_ms: 70.0, .. });
    assert(stats::latest.render_ms == 70.0);
    assert(stats::refresh_count == observations);
    assert(stats::stage_summaries[8].average_ms == 7.0);
    stats::refresh();
    assert(abs(stats::stage_summaries[8].average_ms - 7.2625) < 0.000001);
    assert(stats::stage_summaries[8].p95_ms == 7.0);
    stats::reset_history();
    stats::refresh();
    for summary in stats::stage_summaries {
        assert(summary.average_ms == 0.0 && summary.p95_ms == 0.0);
        assert(summary.share_percent == 0.0);
    }
}

fn test_system_timings() {
    sim::init(73129);
    assert(sim::robot_path_budget == 2);
    sim::tick(1.0 / 60.0);
    assert(sim::deposit_ms >= 0.0 && sim::power_ms >= 0.0);
    assert(sim::production_ms >= 0.0 && sim::transport_ms >= 0.0 && sim::robots_ms >= 0.0);
    let sections = sim::deposit_ms + sim::power_ms + sim::production_ms
        + sim::transport_ms + sim::robots_ms;
    assert(sections <= sim::simulation_ms + 0.000001);
    sim::robot_path_budget = -10;
    sim::tick(1.0 / 60.0);
    assert(sim::path_budget == 0);
    sim::robot_path_budget = 100;
    sim::tick(1.0 / 60.0);
    assert(sim::path_budget == 16);
    sim::robot_path_budget = 2;
    sim::shutdown();
}

fn main() {
    let start = clock();
    test_history();
    test_stage_summaries();
    test_counts_and_reuse();
    test_system_timings();
    print("telemetry: PASS; bounded 240-frame history, nearest-rank percentiles, 4 Hz snapshots, live/free pools, actual slot reuse, system timings; elapsed_ms=", (clock() - start) * 1000.0);
}
