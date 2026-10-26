// Standalone integration workload: goose build tests/gpu_stress.goose.
// Exercises actual 1920x1080 Metal/Vulkan/D3D rendering, including GPU waits.
import std;
import vec;
import math;
import os;
import gfx;
import scene from "../src";

let ROUNDS = 2500;
let FRAMES_PER_ROUND = 20;
let WARMUP_ROUNDS = 10;
let CHURN = 1000;

fn gpu_stress_collections() {
    // Three genuinely independent variable collections on each churn object.
    var handles: ecs::Handle[>..] = [];
    for i in ecs::entities.len {
        if !ecs::entities[i].alive || ecs::entities[i].kind != sim::STRESS {
            continue;
        }
        let h = sim::handle(i);
        for kind in 2 + i % 5 {
            assert(ecs::add(h, kind, 1 + (i + kind) % 9));
        }
        for task in 1 + i % 7 {
            ecs::enqueue(h, task, 1);
        }
        handles.push(h);
    }
    for i in handles.len {
        ecs::link(handles[i], handles[(i + 1) % handles.len]);
    }
}

fn main() {
    assert(gfx::open_headless(1920, 1080, gfx::NO_VSYNC));
    let size = gfx::screen_size();
    assert(size.x == 1920 && size.y == 1080);
    sim::init(73129);
    scene::init();
    render::stream_radius = 64.0;
    var frame_ms: f64[>..] = [];
    var cpu_draw_ms: f64[>..] = [];
    var samples: u8[>..] = [];
    var frame_sum: f64 = 0.0;
    var draw_sum: f64 = 0.0;
    var peak_terrain_vertices: i64 = 0;
    var peak_triangles: i64 = 0;
    var peak_live: i64 = 0;
    var entity_warmup: i64 = 0;
    var inventory_warmup: i64 = 0;
    var queue_warmup: i64 = 0;
    var edge_warmup: i64 = 0;
    let start = clock();
    print(
        "GPU_STRESS_BEGIN width=1920 height=1080 driver=", gfx::driver(),
        " rounds=", ROUNDS, " churn=", CHURN
    );
    for round in ROUNDS {
        let round_start = clock();
        // Every destination is > the deposit and chunk diameters away.
        // This forces full eviction instead of retaining overlapping rings.
        let x: f32 = round * 256.0;
        let z: f32 = (round % 3) * 256.0;
        sim::player = sim::ground(x, z);
        sim::stream_deposits(x, z);
        sim::stress_spawn(CHURN);
        gpu_stress_collections();
        peak_live = max(peak_live, ecs::alive_count);
        for batch in 4 {
            world::stream(x, z, 2, 8);
            world::drain();
        }
        assert(world::loaded == 25 && world::pending == 0);
        scene::sync(81);
        var detail_meshes: i64 = 0;
        for mesh in scene::cached {
            if mesh.count > 0 {
                detail_meshes++;
            }
        }
        assert(detail_meshes == 25);
        let grass_meshes: i64 = if scene::grass_mesh.count > 0 { 1 } else { 0 };
        assert(scene::mesh_count == detail_meshes + grass_meshes);
        peak_terrain_vertices = max(peak_terrain_vertices, scene::terrain_vertices);
        scene::burst(sim::player + float3 { 0.0, 1.0, 0.0 }, scene::CYAN);
        for frame in FRAMES_PER_ROUND {
            let frame_start = clock();
            assert(gfx::frame());
            sim::tick(1.0 / 60.0);
            let draw_start = clock();
            scene::draw(
                sim::player + float3 { 24.0, 21.0, 29.0 }, sim::player + float3 { 0.0, 1.0, 0.0 },
                sim::day, sim::elapsed, ecs::Handle {}, 0, float3_0, true, true
            );
            let draw_ms = (clock() - draw_start) * 1000.0;
            // Include submitted GPU work and wait for completion, not just
            // the CPU time needed to enqueue render commands.
            gfx::flush();
            let elapsed_ms = (clock() - frame_start) * 1000.0;
            peak_triangles = max(peak_triangles, render::triangles);
            if round >= WARMUP_ROUNDS {
                frame_ms.push(elapsed_ms);
                cpu_draw_ms.push(draw_ms);
                frame_sum += elapsed_ms;
                draw_sum += draw_ms;
            }
        }
        if round == ROUNDS - 1 {
            assert(gfx::screenshot("artifacts/gpu-stress.png"));
        }
        sim::stress_destroy(CHURN);
        var stress_remaining: i64 = 0;
        for e in ecs::entities {
            if e.alive && e.kind == sim::STRESS {
                stress_remaining++;
            }
        }
        assert(stress_remaining == 0);
        if round == WARMUP_ROUNDS - 1 {
            entity_warmup = ecs::entities.len;
            inventory_warmup = ecs::inventories.len;
            queue_warmup = ecs::queues.len;
            edge_warmup = ecs::edges.len;
        }
        if round >= WARMUP_ROUNDS {
            assert(ecs::entities.len <= entity_warmup + 32);
            assert(ecs::inventories.len <= inventory_warmup + 64);
            assert(ecs::queues.len <= queue_warmup + 64);
            assert(ecs::edges.len <= edge_warmup + 32);
        }
        assert(world::chunks.len == 25);
        if round > 0 {
            samples.push(',');
        }
        format(
            samples, "{\"round\":", round, ",\"elapsed_s\":", clock() - start,
            ",\"round_ms\":", (clock() - round_start) * 1000.0,
            ",\"entity_slots\":", ecs::entities.len, ",\"active_entities_after_destroy\":", ecs::alive_count,
            ",\"inventory_cells\":", ecs::inventories.len, ",\"queue_cells\":", ecs::queues.len,
            ",\"edge_cells\":", ecs::edges.len, ",\"chunk_slots\":", world::chunks.len,
            ",\"mesh_count\":", scene::mesh_count, ",\"terrain_vertices\":", scene::terrain_vertices,
            ",\"dynamic_gpu_capacity_bytes\":", render::dynamic_capacity, "}"
        );
        print(
            "GPU_STRESS_ROUND round=", round, " elapsed_s=", clock() - start,
            " entity_slots=", ecs::entities.len, " active=", ecs::alive_count,
            " inventory_cells=", ecs::inventories.len, " queue_cells=", ecs::queues.len,
            " edge_cells=", ecs::edges.len, " chunks=", world::chunks.len,
            " meshes=", scene::mesh_count, " terrain_vertices=", scene::terrain_vertices,
            " dynamic_capacity=", render::dynamic_capacity
        );
    }
    sort(frame_ms) { a, b => a < b };
    sort(cpu_draw_ms) { a, b => a < b };
    let mean = frame_sum / frame_ms.len;
    let p50 = frame_ms[frame_ms.len / 2];
    let p95 = frame_ms[(frame_ms.len * 95) / 100];
    let p99 = frame_ms[(frame_ms.len * 99) / 100];
    let dynamic_capacity = render::dynamic_capacity;
    var result: u8[>..] = [];
    format(
        result, "{\n\"test\":\"real GPU streaming and entity churn\",\n",
        "\"resolution\":[1920,1080],\"headless\":true,\"shadows\":true,\n",
        "\"rounds\":", ROUNDS, ",\"warmup_rounds\":", WARMUP_ROUNDS,
        ",\"rendered_frames\":", ROUNDS * FRAMES_PER_ROUND, ",\"measured_frames\":", frame_ms.len,
        ",\"entities_created_and_destroyed\":", ROUNDS * CHURN,
        ",\"chunk_generations\":", world::generated, ",\"chunk_evictions\":", world::evicted,
        ",\"peak_live_entities\":", peak_live, ",\"peak_visible_triangles\":", peak_triangles,
        ",\"peak_terrain_vertices\":", peak_terrain_vertices,
        ",\"entity_slots_warmup\":", entity_warmup, ",\"entity_slots_final\":", ecs::entities.len,
        ",\"inventory_cells_warmup\":", inventory_warmup, ",\"inventory_cells_final\":", ecs::inventories.len,
        ",\"queue_cells_warmup\":", queue_warmup, ",\"queue_cells_final\":", ecs::queues.len,
        ",\"edge_cells_warmup\":", edge_warmup, ",\"edge_cells_final\":", ecs::edges.len,
        ",\"chunk_slots_final\":", world::chunks.len,
        ",\"dynamic_gpu_capacity_bytes\":", dynamic_capacity,
        ",\"frame_mean_ms\":", mean, ",\"fps_from_mean\":", 1000.0 / mean,
        ",\"frame_p50_ms\":", p50, ",\"frame_p95_ms\":", p95, ",\"frame_p99_ms\":", p99,
        ",\"cpu_draw_mean_ms\":", draw_sum / cpu_draw_ms.len,
        ",\"cpu_draw_p95_ms\":", cpu_draw_ms[(cpu_draw_ms.len * 95) / 100],
        ",\"elapsed_s\":", clock() - start, ",\"round_samples\":[", samples,
        "],\"notes\":\"Frames include CPU simulation, scene generation, GPU submission and ",
        "synchronous GPU completion. Streaming and entity churn occur between measured frames. ",
        "Pool lengths are high-water storage, not live use. RSS is sampled externally.\"\n}\n"
    );
    assert(write_file("artifacts/gpu-stress-results.json", result));
    print(
        "GPU_STRESS_PASS frames=", ROUNDS * FRAMES_PER_ROUND, " measured=", frame_ms.len,
        " mean_ms=", mean, " p95_ms=", p95, " p99_ms=", p99, " fps=", 1000.0 / mean,
        " entity_slots_warmup=", entity_warmup, " final=", ecs::entities.len,
        " inventory_warmup=", inventory_warmup, " final=", ecs::inventories.len,
        " queue_warmup=", queue_warmup, " final=", ecs::queues.len,
        " edge_warmup=", edge_warmup, " final=", ecs::edges.len
    );
    print("GPU_STRESS_CLEANUP_BEGIN elapsed_s=", clock() - start);
    scene::shutdown();
    print("GPU_STRESS_CLEANUP_SCENE elapsed_s=", clock() - start);
    sim::shutdown();
    sim::reset();
    print("GPU_STRESS_CLEANUP_SIM elapsed_s=", clock() - start);
    gfx::close();
    print("GPU_STRESS_CLEANUP_END elapsed_s=", clock() - start);
}
