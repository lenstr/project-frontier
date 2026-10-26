import std;
import vec;
import math;
import os;
import vegetation from "../src";
import entities from "../src";

fn test_shared_positions() {
    for cx in -2..3 {
        for cz in -2..3 {
            for index in 4 {
                let group = flora::grove(cx, cz, index, 1.0);
                let anchor = world::hash(cx * 51 + index, cz * 37 - index * 5, world::seed + 909);
                assert(group.hash == anchor);
                assert(group.x == cx * 32.0 + 6.0 + (anchor & 65535) / 65535.0 * 20.0);
                assert(group.z == cz * 32.0 + 6.0 + ((anchor >> 16) & 65535) / 65535.0 * 20.0);
                for member in group.members {
                    let plant = flora::member(cx, cz, index, member, group);
                    let hash = world::hash(cx * 113 + index * 101 + member, cz * 127 - member * 5, world::seed + 1819);
                    assert(plant.hash == hash);
                    assert(abs(plant.x - group.x) <= 7.5 && abs(plant.z - group.z) <= 7.5);
                    assert(plant.size >= 0.6 && plant.size <= 3.0);
                }
            }
        }
    }
}

fn sample_band(inner: f32, outer: f32, density: f32) -> i64 {
    var vertices: ft::Vertex[>..] = [];
    flora::append(vertices, float3_0, inner, outer, density);
    assert(vertices.len > 0 && vertices.len == flora::last_vertices);
    assert(flora::last_objects > 0 && vertices.len % 3 == 0);
    for vertex in vertices {
        assert(vertex.pos.y == vertex.pos.y);
        assert(vertex.color.w < 0.0 && vertex.color.w > -10.0);
        assert(abs(dot(vertex.normal, vertex.normal) - 1.0) < 0.001);
    }
    flora::last_objects
}

fn main() {
    world::seed = 73129;
    let entities_before = ecs::entities.len;
    let chunks_before = world::chunks.len;
    test_shared_positions();
    let sparse = sample_band(0.0, 256.0, 0.5);
    let dense = sample_band(0.0, 256.0, 2.0);
    assert(dense > sparse);
    let mid = sample_band(1024.0, 1792.0, 1.0);
    let far = sample_band(4096.0, 6144.0, 1.0);
    assert(ecs::entities.len == entities_before && world::chunks.len == chunks_before);
    assert(flora::cleared(-123.0, -102.0, false));
    print("vegetation PASS: shared grove/member positions; finite tagged geometry; density ", sparse, " -> ", dense,
        "; mid canopies=", mid, "; far canopies=", far,
        "; far range=6144 m; entity/chunk residency unchanged");
}
