import std;
import os;
import memory from "../src";
import entities from "../src";

fn temporary_payload(size: i64, value: u8) -> i64 {
    var bytes: u8[>..] = [];
    for i in size {
        bytes.push(value);
    }
    var sum: i64 = 0;
    for i in size / 4096 {
        sum += bytes[i * 4096];
    }
    assert(bytes.len == size && bytes[size - 1] == value);
    sum
}

fn main() {
    let keep_pages = args().len > 1 && args()[1] == "--keep-pages";
    let entity = ecs::spawn(9, float3 { 1.0, 2.0, 3.0 });
    ecs::add(entity, 0, 123);
    let slots = ecs::entities.len;
    let cells = ecs::inventories.len;
    let size: i64 = 64 * 1024 * 1024;
    assert(temporary_payload(size, 90) == (size / 4096) * 90);
    print("MEMORY_PHASE released_scope keep_pages=", keep_pages);
    flush_stdout();
    sleep_ms(700);

    memory::service_request();
    assert(memory::requests == 0);
    if !keep_pages {
        // Multiple requests coalesce and run only at an explicit boundary.
        memory::request_trim();
        memory::request_trim();
        memory::service_request();
        assert(memory::requests == 1 && !memory::pending);
        assert(memory::last_ok && memory::failures == 0);
    }
    assert(ecs::valid(entity) && ecs::amount(entity, 0) == 123);
    assert(ecs::entities.len == slots && ecs::inventories.len == cells);
    print("MEMORY_PHASE after_request requests=", memory::requests, " ok=", memory::last_ok);
    flush_stdout();
    sleep_ms(700);

    // Released pages must be usable again without losing persistent values.
    assert(temporary_payload(size, 37) == (size / 4096) * 37);
    assert(ecs::amount(entity, 0) == 123);
    print("PASS memory: scoped scratch, deferred/coalesced trim, live pools preserved, regrowth");
}
