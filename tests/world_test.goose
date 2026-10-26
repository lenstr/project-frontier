import std;
import math;
import os;
import world from "../src";

fn settle(x: f32, z: f32, radius: i64) {
    for i in 16 {
        world::stream(x, z, radius, 8);
        world::drain();
    }
}

fn main() {
    let start = clock();
    world::init(73129);
    settle(0.0, 0.0, 2);
    assert(world::loaded == 25);
    assert(world::pending == 0);
    assert(world::chunks.len == 25);
    assert(world::height(0.0, 0.0) == world::base_height(0.0, 0.0));
    let origin = world::find(0, 0);
    for z in 17 {
        for x in 17 {
            let expected = world::generated_height(x * 2.0, z * 2.0, 73129);
            assert(world::chunks[origin].heights[z * 17 + x] == expected);
        }
    }
    let before = world::height(-2.0, -2.0);
    world::edit(-2.0, -2.0, -1.25);
    assert(abs(world::height(-2.0, -2.0) - (before - 1.25)) < 0.0001);
    let s = world::find(-1, -1);
    assert(s >= 0 && world::chunks[s].ready);
    var verts = world::mesh(s);
    assert(verts.len == 1536);
    assert(verts[0].normal.y > 0.0);
    // An edit on a shared vertex must update every chunk meeting there.
    world::edit(0.0, 0.0, -0.5);
    let left = world::find(-1, 0);
    let right = world::find(0, 0);
    assert(world::chunks[left].heights[16] == world::chunks[right].heights[0]);
    let edited = world::height(-2.0, -2.0);
    var checksum: f64 = 0.0;
    for lap in 100 {
        let x: f32 = ((lap * 17) % 31 - 15) * 96.0;
        let z: f32 = ((lap * 13) % 29 - 14) * 96.0;
        settle(x, z, 2);
        assert(world::loaded == 25);
        assert(world::chunks.len == 25);
        assert(world::max_pending <= 8);
        checksum += world::height(x + 1.0, z + 1.0);
    }
    settle(0.0, 0.0, 2);
    assert(abs(world::height(-2.0, -2.0) - edited) < 0.0001);
    let slot = world::find(-1, -1);
    assert(abs(world::chunks[slot].heights[15 * 17 + 15] - edited) < 0.0001);
    // Repeatedly abandon outstanding jobs before their results are collected.
    for lap in 50 {
        world::stream(lap * 128.0, -lap * 96.0, 2, 8);
    }
    world::drain();
    settle(0.0, 0.0, 4);
    assert(world::loaded == 81);
    assert(world::chunks.len == 81);
    settle(-1000.0, -1000.0, 4);
    assert(world::chunks.len == 81);
    world::shutdown();
    assert(world::loaded == 0 && world::pending == 0);
    world::init(73129);
    settle(-2.0, -2.0, 2);
    assert(world::chunks.len == 81);
    assert(abs(world::height(-2.0, -2.0) - edited) < 0.0001);
    world::shutdown();
    print(
        "world: PASS; chunks generated=", world::generated,
        " evicted=", world::evicted, " slots_high_water=", world::chunks.len,
        " edits=", world::edits.len, " max_pending=", world::max_pending,
        " generation_ms_total=", world::generation_total_ms,
        " queue_call_ms=", world::transfer_ms, " blocking_drain_ms=", world::wait_ms,
        " elapsed_ms=", (clock() - start) * 1000.0, " checksum=", checksum
    );
}
