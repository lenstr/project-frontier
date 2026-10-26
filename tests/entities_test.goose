import entities from "../src";
import os;

fn main() {
    assert(!ecs::valid(ecs::Handle {}));
    let first = ecs::spawn(1, float3 { 0, 0, 0 });
    assert(ecs::entities[first.slot].target.slot == -1);
    assert(ecs::add(first, 4, 10));
    assert(ecs::add(first, 4, 2));
    assert(ecs::amount(first, 4) == 12);
    assert(!ecs::take(first, 4, 13));
    assert(ecs::take(first, 4, 12));
    assert(ecs::amount(first, 4) == 0);
    assert(ecs::entities[first.slot].inventory.len == 0);
    ecs::destroy(first);
    let second = ecs::spawn(2, float3 { 1, 0, 0 });
    assert(first.slot == second.slot);
    assert(!ecs::valid(first) && ecs::valid(second));
    assert(!ecs::add(first, 4, 99));
    ecs::destroy(first); // A stale handle must not destroy its replacement.
    assert(ecs::valid(second));
    assert(!ecs::add(second, 4, -1));
    assert(!ecs::take(second, 4, -1));
    assert(ecs::add(second, 4, 9223372036854775807));
    assert(!ecs::add(second, 4, 1));
    assert(ecs::amount(second, 4) == 9223372036854775807);
    let destination = ecs::spawn(3, float3 { 2, 0, 0 });
    ecs::link(second, destination);
    ecs::link(second, destination);
    ecs::link(second, second);
    assert(ecs::entities[second.slot].links.len == 1);
    ecs::entities[second.slot].target = destination;
    ecs::destroy(destination);
    assert(ecs::entities[second.slot].links.len == 0);
    assert(ecs::entities[second.slot].target.slot == -1);
    ecs::clear();

    let t0 = clock();
    var slots_peak: i64 = 0;
    var inventory_peak: i64 = 0;
    var queue_peak: i64 = 0;
    var edge_peak: i64 = 0;
    for round in 50 {
        var handles: ecs::Handle[>..] = [];
        for i in 1000 {
            handles.push(ecs::spawn(i % 7, float3 { i, 0, 0 }));
        }
        // Interleaved growth forces independently owned runs to move and merge.
        for kind in 12 {
            for i in handles.len {
                assert(ecs::add(handles[i], kind, i + kind + 1));
                if kind < i % 9 {
                    ecs::enqueue(handles[i], kind, i + 1);
                }
                if kind < 3 {
                    ecs::link(handles[i], handles[(i + kind + 1) % handles.len]);
                }
            }
        }
        assert(ecs::alive_count == 1000);
        for i in handles.len {
            for kind in 12 {
                assert(ecs::amount(handles[i], kind) == i + kind + 1);
            }
            assert(ecs::entities[handles[i].slot].queue.len == i % 9);
            for q in ecs::entities[handles[i].slot].queue.len {
                assert(ecs::entities[handles[i].slot].queue[q].kind == q);
                assert(ecs::entities[handles[i].slot].queue[q].count == i + 1);
            }
            assert(ecs::entities[handles[i].slot].links.len == 3);
        }
        if round == 0 {
            slots_peak = ecs::entities.len;
            inventory_peak = ecs::inventories.len;
            queue_peak = ecs::queues.len;
            edge_peak = ecs::edges.len;
        } else {
            assert(ecs::entities.len == slots_peak);
            assert(ecs::inventories.len == inventory_peak);
            assert(ecs::queues.len == queue_peak);
            assert(ecs::edges.len == edge_peak);
        }
        // Delete every other entity individually; incoming graph edges vanish.
        for i in handles.len / 2 {
            ecs::destroy(handles[i * 2]);
        }
        for i in handles.len {
            assert(ecs::valid(handles[i]) == (i % 2 == 1));
            if ecs::valid(handles[i]) {
                for edge in ecs::entities[handles[i].slot].links {
                    assert(ecs::valid(edge));
                }
            }
        }
        ecs::clear();
        assert(ecs::alive_count == 0);
        for h in handles {
            assert(!ecs::valid(h));
        }
    }
    print("PASS entities: 50000 spawns, stale handles, independent inventories/queues/edges, graph deletion");
    print(
        "pool plateaus: slots=", slots_peak, " inventory=", inventory_peak,
        " queue=", queue_peak, " edges=", edge_peak, " elapsed_ms=", (clock() - t0) * 1000.0,
    );
}
