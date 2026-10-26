import std;
import vec;
import math;
import free_flight from "../src";

fn test_camera_footprint() {
    let heights: f32[4] = [12.0, 130.0, 800.0, 4000.0];
    let pitches: f32[5] = [-1.2, -0.1, 0.2, 0.55, 1.4];
    let positions: f32[4] = [-513.0, -0.1, 31.9, 1024.0];
    for height in heights {
        for x in positions {
            flight::eye = float3 { x, height + 1.8, -x };
            for pitch in pitches {
                flight::pitch = pitch;
                for direction in 8 {
                    flight::yaw = direction * 0.785398;
                    let focus = flight::stream_focus(1.8);
                    assert(focus.x == flight::eye.x && focus.z == flight::eye.z);
                    assert(focus.y == 1.8);
                    // Even the smallest detail radius keeps the entire camera
                    // tile inside the opaque part of the chunk fade region.
                    let chunk_x = floor(flight::eye.x / 32.0) * 32.0 + 16.0;
                    let chunk_z = floor(flight::eye.z / 32.0) * 32.0 + 16.0;
                    let distance = max(abs(chunk_x - focus.x), abs(chunk_z - focus.z));
                    assert(distance < 64.0 * 0.55);
                }
            }
        }
    }
}

fn main() {
    test_camera_footprint();
    let anchor = float3 { 0.0, 1.8, 7.0 };
    flight::enter(anchor, 0.873);
    assert(flight::enabled);
    assert(abs(flight::eye.y - 131.8) < 0.001);
    assert(flight::direction().y < -0.5);
    assert(flight::horizon_distance(1.8) == 12288.0);
    flight::eye.y = 2501.8;
    assert(flight::horizon_distance(1.8) == 15360.0);
    flight::eye.y = 10001.8;
    assert(flight::horizon_distance(1.8) == 16384.0);
    flight::enter(anchor, 0.873);
    let initial = flight::eye;
    let focus = flight::stream_focus(1.8);
    assert(focus.x == initial.x && focus.z == initial.z);
    assert(abs(focus.y - 1.8) < 0.01);

    for frame in 120 {
        flight::update(flight::Input { forward: 1.0, .. }, 1.0 / 60.0);
    }
    let travelled = length(flight::eye - initial);
    assert(travelled > 85.0 && travelled < 97.0);
    assert(abs(flight::eye.y - initial.y) < 0.001);
    let horizontal = float3 { flight::velocity.x, 0.0, flight::velocity.z };
    assert(length(horizontal) <= flight::speed + 0.001);

    flight::enter(anchor, 0.873);
    for frame in 120 {
        flight::update(flight::Input { forward: 1.0, right: 1.0, lift: 1.0, boost: true, .. }, 1.0 / 60.0);
    }
    assert(length(flight::velocity) <= flight::speed * 4.0 + 0.001);
    assert(flight::eye.y > initial.y + 150.0);
    flight::update(flight::Input { wheel: 100.0, pitch_delta: 100.0, .. }, 0.1);
    assert(flight::speed == 300.0 && flight::pitch == 1.45);
    flight::update(flight::Input { wheel: -100.0, pitch_delta: -100.0, .. }, 0.1);
    assert(flight::speed == 10.0 && flight::pitch == -1.35);

    flight::leave();
    let stopped = flight::eye;
    flight::update(flight::Input { forward: 1.0, lift: 1.0, .. }, 0.1);
    assert(!flight::enabled && length(flight::eye - stopped) == 0.0);
    assert(length(flight::velocity) == 0.0);
    print("PASS free flight: level movement, altitude, normalized boost, speed/pitch limits, camera-footprint coverage across altitude/pitch/yaw, disabled state");
}
