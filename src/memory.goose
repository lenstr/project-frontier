// Release unused pages after temporary allocations have left their scopes.
// This does not shrink reusable pools or retire native/GPU resources.
namespace memory;
import os;

var pending = false;
var requests: i64 = 0;
var failures: i64 = 0;
var last_ok = false;
var last_ms: f64 = 0.0;

fn request_trim() {
    pending = true;
}

fn service_request() {
    if !pending {
        return;
    }
    pending = false;
    let started = clock_ns();
    last_ok = trim_memory();
    last_ms = (clock_ns() - started) / 1000000.0;
    requests++;
    if !last_ok {
        failures++;
    }
}
