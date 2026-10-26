// Visual-only high-detail tiles preserve geometry and lighting without sim residency.
import std;
import vec;
import math;
import os;
import visual_detail from "../src";

fn vertex_at(x: f32, z: f32) -> i64 {
    let xi = ((x + 128.0) / 2.0) as i64;
    let zi = ((z + 128.0) / 2.0) as i64;
    (zi * 64 + xi) * 6
}

fn main() {
    world::seed = 73129;
    assert(detail::tile_radius(512.0) == 4);
    assert(detail::tile_radius(1024.0) == 8);
    assert(detail::tile_radius(2048.0) == 16);
    world::edits.push(world::Edit { gx: -1, gz: -1, delta: -3.0 });
    var snapshot = detail::Job { edits: copy(world::edits), .. };
    let started = clock();
    var vertices = horizon::build_detail_tile(-1, -1);
    assert(vertices.len == 26112);
    let origin = vertices[vertex_at(-2.0, -2.0)].pos;
    assert(abs(origin.y - (world::height(-2.0, -2.0) - 0.15)) < 0.0001);
    let index = vertex_at(-124.0, -104.0);
    let center = (vertices[index].pos + vertices[index + 1].pos + vertices[index + 2].pos) * ft::splat(1.0 / 3.0);
    let expected = world::color(center.x, center.z, 1.8, float3 { 0.0, 1.0, 0.0 });
    let actual = vertices[index].color;
    assert(abs(actual.x - expected.x) < 0.001);
    assert(abs(actual.y - expected.y) < 0.001);
    assert(abs(actual.z - expected.z) < 0.001);
    world::edits[0].delta = -6.0;
    assert(snapshot.edits[0].delta == -3.0);
    assert(world::chunks.len == 0);
    print("survey_detail PASS: 2 m tile grid, default coverage=2176 m, edits and flat-pad lighting preserved, gameplay chunks=0; generation_ms=",
        (clock() - started) * 1000.0);
}
