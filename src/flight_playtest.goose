// Exercises detached flight through the ordinary application input path.
// The driver reads game state and injects keys; it never moves the suit or camera.
namespace pilot;
import std;
import vec;
import math;
import os;
import gfx;
import .entities;
import .world;
import .sim;
import .free_flight;

var complete = false;
var framecount: i64 = 0;
var initial_player: float3;
var initial_eye: float3;
var generated_before: i64 = 0;
var generated_at_takeoff: i64 = 0;
var generated_after_travel: i64 = 0;
var chunk_slots_peak: i64 = 0;
var pending_peak: i64 = 0;
var distance_m: f32 = 0.0;
var horizontal_m: f32 = 0.0;
var climb_m: f32 = 0.0;
var maximum_altitude_m: f32 = 0.0;
var home_horizontal_m: f32 = 0.0;
var returned_to_suit = false;
var alias_checked = false;

fn key(name: const u8[:], down: bool) {
    assert(gfx::inject_key(name, down));
}

fn horizontal(a: float3, b: float3) -> f32 {
    let x = a.x - b.x;
    let z = a.z - b.z;
    sqrt(x * x + z * z)
}

fn movement_keys(down: bool) {
    key("W", down);
    key("E", down);
    key("Left Shift", down);
}

fn altitude() -> f32 {
    flight::eye.y - world::height(flight::eye.x, flight::eye.z)
}

fn measure_travel() {
    assert(flight::enabled);
    distance_m = length(flight::eye - initial_eye);
    horizontal_m = horizontal(flight::eye, initial_eye);
    climb_m = flight::eye.y - initial_eye.y;
    generated_after_travel = world::generated;
    assert(distance_m > 200.0);
    assert(horizontal_m > 200.0);
    assert(climb_m > 150.0);
    assert(generated_after_travel > generated_at_takeoff);
}

fn verify_home() {
    assert(flight::enabled && ecs::valid(sim::base));
    let base = ecs::entities[sim::base.slot].pos;
    home_horizontal_m = horizontal(flight::eye, base);
    // The overview deliberately sits 80 m behind and 130 m above the base.
    assert(home_horizontal_m > 70.0 && home_horizontal_m < 90.0);
    assert(abs(flight::eye.y - base.y - 130.0) < 0.1);
    assert(altitude() > 100.0);
}

fn finish() {
    assert(!flight::enabled && returned_to_suit && alias_checked);
    assert(length(sim::player - initial_player) < 0.001);
    assert(world::generated > generated_before);
    let result = str(
        "{\n  \"passed\": true,\n  \"frames\": ", framecount,
        ",\n  \"camera_distance_m\": ", distance_m,
        ",\n  \"camera_horizontal_m\": ", horizontal_m,
        ",\n  \"altitude_gain_m\": ", climb_m,
        ",\n  \"maximum_altitude_m\": ", maximum_altitude_m,
        ",\n  \"home_horizontal_m\": ", home_horizontal_m,
        ",\n  \"player_unchanged\": true,\n  \"generated_before\": ", generated_before,
        ",\n  \"generated_at_takeoff\": ", generated_at_takeoff,
        ",\n  \"generated_after_travel\": ", generated_after_travel,
        ",\n  \"generated_final\": ", world::generated,
        ",\n  \"chunk_slots_peak\": ", chunk_slots_peak,
        ",\n  \"chunk_slots_limit\": ", world::MAX_CHUNKS,
        ",\n  \"pending_jobs_peak\": ", pending_peak,
        ",\n  \"f10_alias_checked\": true,\n",
        "  \"actions\": \"G, boosted forward and ascent, Home, G return, F10 enter, F10 return\"\n}\n",
    );
    assert(write_file("artifacts/flight-test.json", result));
    print("FLIGHT INPUT PLAYTEST PASS ", result);
    complete = true;
}

// Called once at the end of an application frame. Injected edges become visible
// to the ordinary camera/hotkey code on the following gfx::frame().
fn update() {
    if complete {
        return;
    }
    framecount++;
    assert(framecount <= 240);
    chunk_slots_peak = max(chunk_slots_peak, world::chunks.len);
    pending_peak = max(pending_peak, world::pending);
    assert(world::chunks.len <= world::MAX_CHUNKS);
    assert(world::pending <= world::MAX_JOBS);
    if framecount == 1 {
        assert(!flight::enabled);
        initial_player = sim::player;
        generated_before = world::generated;
        key("G", true);
    } else {
        assert(length(sim::player - initial_player) < 0.001);
    }
    if flight::enabled {
        maximum_altitude_m = max(maximum_altitude_m, altitude());
    }
    if framecount == 2 {
        key("G", false);
    }
    if framecount == 4 {
        assert(flight::enabled && altitude() > 100.0);
        initial_eye = flight::eye;
        generated_at_takeoff = world::generated;
        movement_keys(true);
    }
    if framecount == 124 {
        movement_keys(false);
    }
    if framecount == 130 {
        measure_travel();
    }
    if framecount == 138 {
        key("Home", true);
    }
    if framecount == 139 {
        key("Home", false);
    }
    if framecount == 142 {
        verify_home();
    }
    if framecount == 148 {
        key("G", true);
    }
    if framecount == 149 {
        key("G", false);
    }
    if framecount == 152 {
        assert(!flight::enabled);
        returned_to_suit = true;
    }
    if framecount == 158 {
        key("F10", true);
    }
    if framecount == 159 {
        key("F10", false);
    }
    if framecount == 162 {
        assert(flight::enabled && altitude() > 100.0);
    }
    if framecount == 168 {
        key("F10", true);
    }
    if framecount == 169 {
        key("F10", false);
    }
    if framecount == 172 {
        assert(!flight::enabled);
        alias_checked = true;
    }
    if framecount == 196 {
        finish();
    }
}
