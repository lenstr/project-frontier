// CPU-only benchmark of the exact developer colony used by normal gameplay.
// Fixed seed, timestep and tick counts; no rendering, disk I/O or telemetry
// refresh runs inside the timed interval. This is not an FPS measurement.
import showcase from "../src";
import telemetry from "../src";
import std;
import os;

let WARMUP_TICKS = 120;
let MEASURED_TICKS = 600;
let REUSE_ROUNDS = 6;
let SUBSYSTEMS = 6;
let DT: f32 = 1.0 / 60.0;

struct Resources { ferrite: i64, glacite: i64, stone: i64 }
struct Distribution { mean: f64, p50: f64, p95: f64, p99: f64, maximum: f64 }
struct Sample { ms: f64[SUBSYSTEMS] }
struct Case {
    load: i64,
    timings: Distribution[SUBSYSTEMS],
    counts: stats::Counters,
    build_ms: f64,
    crafted: i64,
    paths: i64,
    path_failures: i64,
    path_ms: f64,
    peak_packets: i64,
    peak_route_backlog: i64,
    power_rebuilds: i64,
    injected: i64[5],
}

fn account(total: Resources&, resource: i64, count: i64) {
    if resource == sim::ORE {
        total.ferrite += count;
    } else if resource == sim::METAL {
        total.ferrite += count * 2;
    } else if resource == sim::CIRCUIT {
        total.ferrite += count * 2;
        total.glacite += count;
    } else if resource == sim::CRYSTAL {
        total.glacite += count;
    } else if resource == sim::STONE {
        total.stone += count;
    }
}

fn resource_balance() -> Resources {
    var total = Resources { .. };
    for resource in 5 {
        account(total, resource, sim::bag[resource]);
        account(total, resource, showcase::escrow[resource]);
        account(total, resource, -showcase::injected[resource]);
    }
    for e in ecs::entities {
        if !e.alive {
            continue;
        }
        for item in e.inventory {
            account(total, item.kind, item.count);
        }
        if e.kind == sim::SMELTER || e.kind == sim::ASSEMBLER || e.kind == sim::MINER {
            for job in e.queue {
                account(total, job.kind, job.count);
            }
        }
        if e.kind == sim::ROBOT && e.cargo_count > 0 {
            account(total, e.cargo_kind, e.cargo_count);
        }
    }
    for packet in sim::packets {
        if packet.alive {
            account(total, packet.kind, packet.count);
        }
    }
    total
}

fn same(a: Resources, b: Resources) -> bool {
    a.ferrite == b.ferrite && a.glacite == b.glacite && a.stone == b.stone
}

fn packets() -> i64 {
    var count: i64 = 0;
    for p in sim::packets {
        if p.alive {
            count++;
        }
    }
    count
}

fn route_backlog() -> i64 {
    var count: i64 = 0;
    for e in ecs::entities {
        if e.alive && e.kind == sim::ROBOT && e.state != 0 && e.queue.len == 0
            && e.timer <= 0.0 && ecs::valid(e.target)
        {
            let target = ecs::entities[e.target.slot];
            let arrival: f32 = if target.kind == sim::LANDER { 3.0 } else { 2.6 };
            if sim::distance(e.pos, target.pos) > arrival {
                count++;
            }
        }
    }
    count
}

fn summarize(samples: Sample[:], subsystem: i64) -> Distribution {
    var sorted: f64[..MEASURED_TICKS] = [];
    var sum: f64 = 0.0;
    for sample in samples {
        let ms = sample.ms[subsystem];
        sorted.push(ms);
        sum += ms;
    }
    sort(sorted[..]);
    Distribution {
        mean: sum / sorted.len,
        p50: stats::percentile(sorted[..], 50),
        p95: stats::percentile(sorted[..], 95),
        p99: stats::percentile(sorted[..], 99),
        maximum: sorted[sorted.len - 1],
    }
}

fn measure(requested: i64) -> Case {
    sim::init(73129);
    showcase::forget();
    let initial = resource_balance();
    showcase::set_load(requested);
    assert(showcase::active_count() == requested);
    for frame in WARMUP_TICKS {
        sim::tick(DT);
    }
    assert(same(initial, resource_balance()));
    let crafted = sim::crafted;
    let paths = nav::path_calls;
    let failed = nav::path_failed;
    let path_ms = nav::path_ms;
    let rebuilds = sim::power_rebuilds;
    var peak_packets = packets();
    var peak_backlog = route_backlog();
    var samples: Sample[..MEASURED_TICKS] = [];
    for frame in MEASURED_TICKS {
        let start = clock_ns();
        sim::tick(DT);
        let elapsed_ms = (clock_ns() - start) / 1000000.0;
        samples.push(Sample { ms: [
            elapsed_ms, sim::deposit_ms, sim::power_ms,
            sim::production_ms, sim::transport_ms, sim::robots_ms
        ] });
        // These observations and conservation checks are outside tick timing.
        peak_packets = max(peak_packets, packets());
        peak_backlog = max(peak_backlog, route_backlog());
        if frame % 60 == 0 {
            assert(same(initial, resource_balance()));
        }
    }
    assert(same(initial, resource_balance()));
    assert(sim::crafted > crafted);
    assert(showcase::active_count() == requested);
    assert(sim::power_rebuilds == rebuilds);
    stats::refresh();
    var result = Case {
        load: requested,
        counts: stats::counters,
        build_ms: showcase::build_ms,
        crafted: sim::crafted - crafted,
        paths: nav::path_calls - paths,
        path_failures: nav::path_failed - failed,
        path_ms: nav::path_ms - path_ms,
        peak_packets: peak_packets,
        peak_route_backlog: peak_backlog,
        power_rebuilds: sim::power_rebuilds - rebuilds,
        injected: showcase::injected,
        ..
    };
    for subsystem in SUBSYSTEMS {
        result.timings[subsystem] = summarize(samples[..], subsystem);
    }
    print("showcase load=", requested, " active=", result.counts.active_entities,
        " robots=", result.counts.robots, " crafted=", result.crafted,
        " tick_ms mean=", result.timings[0].mean, " p50=", result.timings[0].p50,
        " p95=", result.timings[0].p95, " p99=", result.timings[0].p99,
        " max=", result.timings[0].maximum, " paths=", result.paths,
        " failed=", result.path_failures, " peak_route_backlog=", peak_backlog);
    result
}

fn write_distribution(out: u8[>..]&, d: Distribution) {
    format(out, "{\"mean_ms\":", d.mean, ",\"p50_ms\":", d.p50,
        ",\"p95_ms\":", d.p95, ",\"p99_ms\":", d.p99,
        ",\"max_ms\":", d.maximum, "}");
}

fn write_case(out: u8[>..]&, c: Case) {
    format(out, "{\"requested_showcase_entities\":", c.load,
        ",\"total_active_entities\":", c.counts.active_entities,
        ",\"buildings\":", c.counts.buildings, ",\"robots\":", c.counts.robots,
        ",\"production_machines\":", c.counts.production_machines,
        ",\"entity_slots\":", c.counts.entity_slots,
        ",\"inventory_live\":", c.counts.inventory_live,
        ",\"inventory_cells\":", c.counts.inventory_cells,
        ",\"queue_live\":", c.counts.queue_live,
        ",\"queue_cells\":", c.counts.queue_cells,
        ",\"edge_live\":", c.counts.edge_live,
        ",\"edge_cells\":", c.counts.edge_cells,
        ",\"packet_slots\":", c.counts.packet_slots,
        ",\"peak_live_packets\":", c.peak_packets,
        ",\"peak_route_backlog\":", c.peak_route_backlog,
        ",\"selected_payload_estimate_bytes\":", c.counts.payload_estimate_bytes,
        ",\"build_ms\":", c.build_ms, ",\"crafted_outputs\":", c.crafted,
        ",\"path_calls\":", c.paths, ",\"path_failures\":", c.path_failures,
        ",\"path_total_ms\":", c.path_ms,
        ",\"power_topology_rebuilds\":", c.power_rebuilds,
        ",\"injected_resource_units\":[");
    for i in 5 {
        if i > 0 {
            format(out, ",");
        }
        format(out, c.injected[i]);
    }
    format(out, "],\"systems\":{");
    let names = ["tick", "deposits", "power", "production", "transport", "robots"];
    for i in SUBSYSTEMS {
        if i > 0 {
            format(out, ",");
        }
        format(out, "\"", names[i], "\":");
        write_distribution(out, c.timings[i]);
    }
    format(out, "}}");
}

fn main() {
    var cases: Case[>..] = [];
    cases.push(measure(32));
    cases.push(measure(512));
    cases.push(measure(2000));
    let balance_before_reuse = resource_balance();
    // Warm allocation patterns before requiring exact reuse. No simulation
    // tick occurs during swaps, so route lengths cannot change the workload.
    showcase::set_load(32);
    showcase::set_load(2000);
    let entity_slots = ecs::entities.len;
    let inventory_cells = ecs::inventories.len;
    let queue_cells = ecs::queues.len;
    let edge_cells = ecs::edges.len;
    let packet_slots = sim::packets.len;
    let reuse_start = clock_ns();
    for round in REUSE_ROUNDS {
        showcase::set_load(32);
        assert(same(balance_before_reuse, resource_balance()));
        showcase::set_load(2000);
        assert(showcase::active_count() == 2000);
        assert(ecs::entities.len == entity_slots);
        assert(ecs::inventories.len == inventory_cells);
        assert(ecs::queues.len == queue_cells);
        assert(ecs::edges.len == edge_cells);
        assert(sim::packets.len == packet_slots);
        assert(same(balance_before_reuse, resource_balance()));
    }
    let reuse_ms = (clock_ns() - reuse_start) / 1000000.0;
    var json: u8[>..] = [];
    format(json, "{\"seed\":73129,\"configuration\":\"release -O2\",",
        "\"scope\":\"CPU simulation only, rendering/input/streaming/disk/telemetry refresh excluded\",",
        "\"same_process_pool_high_water_retained_between_fresh_worlds\":true,",
        "\"finite_fixture_inputs\":true,\"resource_conservation\":true,",
        "\"robot_path_budget_per_tick\":", sim::robot_path_budget,
        ",\"warmup_ticks\":", WARMUP_TICKS,
        ",\"measured_ticks_per_load\":", MEASURED_TICKS,
        ",\"fixed_dt_seconds\":", DT, ",\"cases\":[");
    for i in cases.len {
        if i > 0 {
            format(json, ",");
        }
        write_case(json, cases[i]);
    }
    format(json, "],\"reuse\":{\"rounds_after_warmup\":", REUSE_ROUNDS,
        ",\"sequence\":[32,2000],\"total_ms\":", reuse_ms,
        ",\"entity_slots\":", entity_slots,
        ",\"inventory_cells\":", inventory_cells,
        ",\"queue_cells\":", queue_cells,
        ",\"edge_cells\":", edge_cells,
        ",\"packet_slots\":", packet_slots,
        ",\"all_capacities_plateaued\":true}}\n");
    assert(write_file("build/v2-showcase-benchmark.json", json));
    print("showcase reuse: PASS rounds=", REUSE_ROUNDS, " total_ms=", reuse_ms,
        " entity_slots=", entity_slots, " inventory_cells=", inventory_cells,
        " queue_cells=", queue_cells, " edge_cells=", edge_cells,
        " packet_slots=", packet_slots);
    sim::shutdown();
}
