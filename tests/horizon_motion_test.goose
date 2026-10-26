// Sustained survey movement: background generation, complete-set fades and GPU retirement.
import std;
import vec;
import math;
import os;
import gfx;
import horizon from "../src";
import telemetry from "../src";

fn main() {
    assert(gfx::open_headless(1280, 800));
    render::init();
    world::seed = 73129;
    horizon::init();
    render::horizon_edge = 12288.0;
    horizon::update(float3_0, 192.0, render::horizon_edge, 1);
    horizon::drain();
    var dynamic: ft::Vertex[>..] = [];
    var meshes: render::Mesh[>..] = [];
    var frames: i64 = 0;
    var fade_frames: i64 = 0;
    var max_update_ms: f64 = 0.0;
    var max_frame_ms: f64 = 0.0;
    let started = clock();
    while frames < 6000 {
        let frame_started = clock();
        assert(gfx::frame());
        let center = float3 { frames * -2.0, 0.0, frames * -1.5 };
        let eye = center + float3 { 0.0, 800.0, 0.0 };
        let target = eye + float3 { -77.0, -55.0, -64.0 };
        let update_started = clock();
        horizon::update(center, 192.0, render::horizon_edge, 1);
        let update_ms = (clock() - update_started) * 1000.0;
        max_update_ms = max(max_update_ms, update_ms);
        meshes.clear();
        let fade = if horizon::fading { horizon::fade_progress() } else { 0.0 };
        if horizon::fading {
            fade_frames++;
            for source in horizon::previous_meshes() {
                var previous = source;
                previous.dissolve = fade;
                meshes.push(previous);
            }
        }
        for source in horizon::meshes() {
            var current = source;
            current.dissolve = -fade;
            meshes.push(current);
        }
        render::horizon_center = horizon::active_center;
        render::draw_scene(meshes, dynamic, eye, target, 0.18, 0.0, false);
        gfx::flush();
        let frame_ms = (clock() - frame_started) * 1000.0;
        max_frame_ms = max(max_frame_ms, frame_ms);
        stats::record(stats::Frame { frame_ms: frame_ms, mesh_ms: update_ms, .. });
        assert(horizon::live_meshes <= 12);
        frames++;
        // Pace submissions so the isolated renderer cannot outrun worker time.
        // This artificial 4 ms pacing is outside the measured frame cost.
        sleep_ms(4);
        if horizon::rebuilds >= 3 && !horizon::fading {
            break;
        }
    }
    assert(horizon::rebuilds >= 3 && fade_frames > 0);
    assert(gfx::screenshot("build/flight-horizon-motion.png"));
    print("horizon_motion PASS frames=", frames,
        " complete_sets=", horizon::rebuilds,
        " fade_frames=", fade_frames,
        " last240_p50_ms=", stats::p50_ms,
        " last240_p95_ms=", stats::p95_ms,
        " last240_p99_ms=", stats::p99_ms,
        " max_frame_ms=", max_frame_ms,
        " max_update_ms=", max_update_ms,
        " worker_cpu_ms=", horizon::generation_total_ms,
        " queue_ms=", horizon::transfer_ms,
        " gpu_upload_ms=", horizon::upload_ms,
        " elapsed_ms=", (clock() - started) * 1000.0);
    horizon::shutdown();
    assert(horizon::uploaded_meshes == horizon::released_meshes);
    render::shutdown();
    gfx::close();
}
