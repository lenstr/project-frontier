// Runtime observations of the actual game. This module owns no gameplay state
// and never changes entity, collection, packet or chunk storage.
namespace stats;
import std;
import .entities;
import .sim;
import .world;
import .navigation;

let HISTORY = 240;
let REFRESH_SECONDS: f64 = 0.25;
let STAGE_COUNT = 11;

struct StageSummary {
    average_ms: f64,
    p95_ms: f64,
    share_percent: f64,
}

struct Frame {
    frame_ms: f64,
    input_ms: f64,
    simulation_ms: f64,
    power_ms: f64,
    production_ms: f64,
    transport_ms: f64,
    robots_ms: f64,
    stream_ms: f64,
    mesh_ms: f64,
    render_ms: f64,
    ui_ms: f64,
    gpu_wait_ms: f64,
}

struct Counters {
    active_entities: i64,
    entity_slots: i64,
    free_entity_slots: i64,
    robots: i64,
    buildings: i64,
    production_machines: i64,
    deposits: i64,
    live_packets: i64,
    packet_slots: i64,
    free_packet_slots: i64,
    inventory_live: i64,
    inventory_cells: i64,
    inventory_free: i64,
    queue_live: i64,
    queue_cells: i64,
    queue_free: i64,
    edge_live: i64,
    edge_cells: i64,
    edge_free: i64,
    chunk_live: i64,
    chunk_slots: i64,
    free_chunk_slots: i64,
    chunks_ready: i64,
    terrain_jobs: i64,
    terrain_generated: i64,
    terrain_evicted: i64,
    terrain_edits: i64,
    depletion_records: i64,
    crafted: i64,
    path_calls: i64,
    path_failed: i64,
    path_expanded: i64,
    power_components: i64,
    power_topology_rebuilds: i64,
    payload_estimate_bytes: i64,
    // ecs::valid is intentionally a pure predicate and has no rejection
    // counter. -1 means unavailable, rather than an invented zero observation.
    stale_handles_rejected: i64 = -1,
    worker_generation_ms: f64,
    worker_generation_last_ms: f64,
    queue_transfer_ms: f64,
    queue_wait_ms: f64,
    path_total_ms: f64,
}

var history: Frame[HISTORY];
var latest: Frame;
var cursor: i64 = 0;
var count: i64 = 0;
var total_frames: i64 = 0;
var uptime: f64 = 0.0;
var mean_ms: f64 = 0.0;
var p50_ms: f64 = 0.0;
var p95_ms: f64 = 0.0;
var p99_ms: f64 = 0.0;
var counters: Counters;
// Peaks of observations, sampled at refresh time. Pool lengths themselves
// retain their true storage high-water marks between observations.
var high_water: Counters;
var refresh_count: i64 = 0;
var last_refresh_uptime: f64 = -1.0;
var stage_summaries: StageSummary[STAGE_COUNT];
var stage_order: i64[STAGE_COUNT] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

fn reset_history() {
    history = [Frame { .. }; HISTORY];
    latest = Frame { .. };
    cursor = 0;
    count = 0;
    total_frames = 0;
    uptime = 0.0;
    mean_ms = 0.0;
    p50_ms = 0.0;
    p95_ms = 0.0;
    p99_ms = 0.0;
    counters = Counters { .. };
    high_water = Counters { .. };
    refresh_count = 0;
    last_refresh_uptime = -1.0;
    stage_summaries = [StageSummary { .. }; STAGE_COUNT];
    stage_order = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
}

// Chronological access: sample(0) is the oldest retained frame, independent
// of the physical ring position. A Frame is a small fixed-size value.
fn sample(index: i64) -> Frame {
    assert(index >= 0 && index < count);
    let oldest: i64 = if count == HISTORY { cursor } else { 0 };
    history[(oldest + index) % HISTORY]
}

// Nearest-rank percentiles over the retained window, not lifetime averages.
fn percentile(sorted: f64[:], percent: i64) -> f64 {
    if sorted.len == 0 {
        return 0.0;
    }
    assert(percent >= 1 && percent <= 100);
    let rank = (sorted.len * percent + 99) / 100;
    sorted[rank - 1]
}

fn refresh_percentiles() {
    var scratch: f64[..HISTORY] = [];
    var sum: f64 = 0.0;
    for i in count {
        let milliseconds = history[i].frame_ms;
        scratch.push(milliseconds);
        sum += milliseconds;
    }
    sort(scratch[..]);
    mean_ms = if count > 0 { sum / count } else { 0.0 };
    p50_ms = percentile(scratch[..], 50);
    p95_ms = percentile(scratch[..], 95);
    p99_ms = percentile(scratch[..], 99);
}

fn stage_value(frame: Frame, stage: i64) -> f64 {
    if stage == 0 {
        return frame.input_ms;
    }
    if stage == 1 {
        return frame.simulation_ms;
    }
    if stage == 2 {
        return frame.power_ms;
    }
    if stage == 3 {
        return frame.production_ms;
    }
    if stage == 4 {
        return frame.transport_ms;
    }
    if stage == 5 {
        return frame.robots_ms;
    }
    if stage == 6 {
        return frame.stream_ms;
    }
    if stage == 7 {
        return frame.mesh_ms;
    }
    if stage == 8 {
        return frame.render_ms;
    }
    if stage == 9 {
        return frame.ui_ms;
    }
    if stage == 10 {
        return frame.gpu_wait_ms;
    }
    abort("invalid telemetry stage");
}

fn refresh_stage_summaries() {
    for stage in STAGE_COUNT {
        var scratch: f64[..HISTORY] = [];
        var sum: f64 = 0.0;
        for i in count {
            let value = stage_value(history[i], stage);
            scratch.push(value);
            sum += value;
        }
        sort(scratch[..]);
        let average = if count > 0 { sum / count } else { 0.0 };
        stage_summaries[stage] = StageSummary {
            average_ms: average,
            p95_ms: percentile(scratch[..], 95),
            share_percent: if mean_ms > 0.0 { average / mean_ms * 100.0 } else { 0.0 },
        };
        stage_order[stage] = stage;
    }
    // Eleven entries: stable insertion sorting is bounded and keeps ties from
    // shuffling. Simulation children remain explicitly labelled as nested.
    for i in 1..STAGE_COUNT {
        let stage = stage_order[i];
        var at = i;
        while at > 0 && stage_summaries[stage_order[at - 1]].average_ms
            < stage_summaries[stage].average_ms
        {
            stage_order[at] = stage_order[at - 1];
            at--;
        }
        stage_order[at] = stage;
    }
}

fn refresh_counts() {
    counters = Counters { .. };
    counters.entity_slots = ecs::entities.len;
    for e in ecs::entities {
        if !e.alive {
            continue;
        }
        counters.active_entities++;
        counters.inventory_live += e.inventory.len;
        counters.queue_live += e.queue.len;
        counters.edge_live += e.links.len;
        if e.kind == sim::ROBOT {
            counters.robots++;
        }
        if sim::building(e.kind) {
            counters.buildings++;
        }
        if e.kind == sim::MINER || e.kind == sim::SMELTER || e.kind == sim::ASSEMBLER {
            counters.production_machines++;
        }
        if e.kind == sim::DEPOSIT_ORE || e.kind == sim::DEPOSIT_CRYSTAL {
            counters.deposits++;
        }
    }
    counters.free_entity_slots = counters.entity_slots - counters.active_entities;
    counters.packet_slots = sim::packets.len;
    for packet in sim::packets {
        if packet.alive {
            counters.live_packets++;
        }
    }
    counters.free_packet_slots = counters.packet_slots - counters.live_packets;
    counters.inventory_cells = ecs::inventories.len;
    counters.inventory_free = counters.inventory_cells - counters.inventory_live;
    counters.queue_cells = ecs::queues.len;
    counters.queue_free = counters.queue_cells - counters.queue_live;
    counters.edge_cells = ecs::edges.len;
    counters.edge_free = counters.edge_cells - counters.edge_live;
    counters.chunk_slots = world::chunks.len;
    for chunk in world::chunks {
        if chunk.active {
            counters.chunk_live++;
            if chunk.ready {
                counters.chunks_ready++;
            }
        }
    }
    counters.free_chunk_slots = counters.chunk_slots - counters.chunk_live;
    counters.terrain_jobs = world::pending;
    counters.terrain_generated = world::generated;
    counters.terrain_evicted = world::evicted;
    counters.terrain_edits = world::edits.len;
    counters.depletion_records = sim::depleted.len;
    counters.crafted = sim::crafted;
    counters.path_calls = nav::path_calls;
    counters.path_failed = nav::path_failed;
    counters.path_expanded = nav::expanded;
    counters.power_components = sim::power_component_count;
    counters.power_topology_rebuilds = sim::power_rebuilds;
    counters.worker_generation_ms = world::generation_total_ms;
    counters.worker_generation_last_ms = world::generation_ms;
    // transfer_ms measures queue API time: memcpy plus synchronization and
    // call overhead. wait_ms additionally includes blocking for worker results.
    counters.queue_transfer_ms = world::transfer_ms;
    counters.queue_wait_ms = world::wait_ms;
    counters.path_total_ms = nav::path_ms;
    // Estimate of selected game payloads, NOT RSS or committed memory. Entity
    // headers use a rounded 128-byte budget; flat array element bytes below
    // are actual bytes_of views, with no copies or temporary serialization.
    // Excluded: freelists/array headers, call and scratch stacks, native
    // libraries, GPU buffers, driver allocations and virtual reservations.
    counters.payload_estimate_bytes = counters.entity_slots * 128
        + bytes_of(ecs::inventories).len
        + bytes_of(ecs::queues).len
        + bytes_of(ecs::edges).len
        + bytes_of(sim::packets).len
        + bytes_of(sim::depleted).len
        + bytes_of(sim::power_stamps).len
        + bytes_of(sim::power_components).len
        + bytes_of(world::chunks).len
        + bytes_of(world::edits).len
        + bytes_of(history).len;
    const for <N, A> in fields<Counters> {
        high_water.A = max(high_water.A, counters.A);
    }
}

// Explicit calls force a fresh observation. record() calls this at about
// 4 Hz; callers can request an immediate update after a developer action.
fn refresh() {
    refresh_percentiles();
    refresh_stage_summaries();
    refresh_counts();
    last_refresh_uptime = uptime;
    refresh_count++;
}

fn record(frame: Frame) {
    latest = frame;
    history[cursor] = frame;
    cursor = (cursor + 1) % HISTORY;
    count = min(count + 1, HISTORY);
    total_frames++;
    uptime += max(0.0, frame.frame_ms) / 1000.0;
    if total_frames == 1 || uptime - last_refresh_uptime >= REFRESH_SECONDS {
        refresh();
    }
}
