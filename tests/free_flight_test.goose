import std;
import vec;
import math;
import free_flight from "../src";

fn main() {
    let anchor = float3 { 0.0, 1.8, 7.0 };
    flight::enter(anchor, 0.873);
    assert(flight::enabled);
    assert(abs(flight::eye.y - 131.8) < 0.001);
    assert(flight::direction().y < -0.5);
    let initial = flight::eye;
    let focus = flight::stream_focus(1.8);
    assert(length(focus - initial) > 200.0);
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
    print("PASS free flight: level movement, altitude, normalized boost, speed/pitch limits, streaming focus, disabled state");
}
