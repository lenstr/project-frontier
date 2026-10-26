import std;
import vec;
import os;
import gfx;
import visual_detail from "../src";

fn finish(center: float3) {
    for batch in 12 {
        detail::stream(center, 512.0, true, detail::MAX_JOBS);
        detail::drain();
    }
    assert(detail::loaded == 81 && detail::live_meshes == 81);
    assert(detail::pending == 0 && detail::tiles.len <= 81);
}

fn main() {
    assert(gfx::open_headless(128, 96));
    world::seed = 73129;
    detail::init();
    finish(float3_0);
    let first_slots = detail::tiles.len;
    for lap in 3 {
        finish(float3 { lap * -256.0, 0.0, lap * 128.0 });
    }
    detail::stream(float3 { 4096.0, 0.0, 0.0 }, 512.0, true, 8);
    detail::stream(float3 { -4096.0, 0.0, 0.0 }, 512.0, true, 8);
    detail::drain();
    assert(detail::stale_results > 0);
    let center = float3 { -4096.0, 0.0, 0.0 };
    finish(center);
    let generated_before = detail::generated;
    world::edits.push(world::Edit { gx: -2048, gz: 0, delta: -3.0 });
    detail::stream(center, 512.0, true, 8);
    detail::drain();
    assert(detail::generated > generated_before && detail::generated <= generated_before + 4);
    assert(detail::live_meshes == 81);
    let edit_generated = detail::generated - generated_before;
    detail::stream(center, 512.0, false, 8);
    detail::drain();
    assert(detail::live_meshes == 0 && detail::loaded == 0);
    finish(float3_0);
    assert(detail::tiles.len == first_slots);
    assert(world::chunks.len == 0);
    detail::shutdown();
    assert(detail::uploaded == detail::released);
    gfx::close();
    print("visual_detail PASS slots=", detail::tiles.len,
        " uploads=", detail::uploaded, " releases=", detail::released,
        " stale_rejected=", detail::stale_results,
        " local_edit_regeneration=", edit_generated,
        " worker_ms=", detail::generation_ms,
        " queue_ms=", detail::queue_ms, " upload_ms=", detail::upload_ms);
}
