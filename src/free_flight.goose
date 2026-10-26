// Detached survey camera. It owns no player, world or simulation state.
namespace flight;
import std;
import vec;
import math;

struct Input {
    forward: f32,
    right: f32,
    lift: f32,
    yaw_delta: f32,
    pitch_delta: f32,
    wheel: f32,
    boost: bool,
}

var enabled = false;
var eye: float3;
var yaw: f32 = 0.873;
var pitch: f32 = 0.55;
var speed: f32 = 48.0;
var velocity: float3;

fn scale(value: f32) -> float3 {
    float3 { value, value, value }
}

fn direction() -> float3 {
    float3 {
        -sin(yaw) * cos(pitch),
        -sin(pitch),
        -cos(yaw) * cos(pitch),
    }
}

fn target() -> float3 {
    eye + direction() * scale(100.0)
}

fn enter(anchor: float3, initial_yaw: f32) {
    enabled = true;
    yaw = initial_yaw;
    pitch = 0.55;
    eye = anchor + float3 { sin(yaw) * 80.0, 130.0, cos(yaw) * 80.0 };
    velocity = float3_0;
}

fn leave() {
    enabled = false;
    velocity = float3_0;
}

fn update(input: Input, delta: f32) {
    if !enabled {
        return;
    }
    let dt = clamp(delta, 0.0, 0.1);
    yaw += input.yaw_delta;
    pitch = clamp(pitch + input.pitch_delta, -1.35, 1.45);
    speed = clamp(speed * exp(input.wheel * 0.18), 10.0, 300.0);
    // WASD remains level for surveying; Q/E independently change altitude.
    var movement = float3 {
        -sin(yaw) * input.forward + cos(yaw) * input.right,
        input.lift,
        -cos(yaw) * input.forward - sin(yaw) * input.right,
    };
    let magnitude = length(movement);
    if magnitude > 1.0 {
        movement *= scale(1.0 / magnitude);
    }
    let multiplier: f32 = if input.boost { 4.0 } else { 1.0 };
    let desired = movement * scale(speed * multiplier);
    velocity += (desired - velocity) * scale(1.0 - exp(-dt * 8.0));
    eye += velocity * scale(dt);
}

// Residency follows the camera's ground footprint, not its center-screen ray.
// Looking toward the horizon must not evict the ground directly below the pilot.
fn stream_focus(terrain_below: f32) -> float3 {
    float3 { eye.x, terrain_below, eye.z }
}

// Coarse terrain expands with survey altitude without growing detailed chunk pools.
fn horizon_distance(terrain_below: f32) -> f32 {
    let altitude = max(eye.y - terrain_below, 0.0);
    let distance = max(12288.0, ceil(altitude * 6.0 / 1024.0) * 1024.0);
    clamp(distance, 12288.0, 16384.0)
}
