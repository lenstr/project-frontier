// Cached logistics must preserve geometry and live animation while bounding
// owned GPU resources through topology changes, terrain edits and travel.
import std;
import vec;
import math;
import os;
import gfx;
import scene from "../src";

fn same_vertices(a: const ft::Vertex[:], b: const ft::Vertex[:]) -> bool {
    if a.len != b.len {
        return false;
    }
    for i in a.len {
        if a[i].pos != b[i].pos || a[i].normal != b[i].normal || a[i].color != b[i].color {
            return false;
        }
    }
    true
}

// Frozen pre-cache builder: the independent reference includes both static
// support geometry and moving arrows in its original order.
fn reference_conveyor(out: ft::Vertex[>..]&, a: float3, b: float3, seconds: f32) {
    let delta = b - a;
    let distance = length(delta);
    if distance < 0.3 || distance > 64.0 {
        return;
    }
    let side = normalize(cross(delta, float3 { 0.0, 1.0, 0.0 })) * ft::splat(0.25);
    let segments = max(1, ceil(distance / 2.0) as i64);
    for i in segments {
        let p = scene::path_point(a, b, i as f32 / segments);
        let q = scene::path_point(a, b, (i + 1) as f32 / segments);
        render::triangle(out, p - side, q - side, q + side, scene::INK);
        render::triangle(out, p - side, q + side, p + side, scene::INK);
        render::beam(out, p - side, q - side, 0.045, scene::NAVY);
        render::beam(out, p + side, q + side, 0.045, scene::NAVY);
        let rail_lift = float3 { 0.0, 0.07, 0.0 };
        render::beam(out, p - side + rail_lift, q - side + rail_lift, 0.015, scene::IVORY);
        render::beam(out, p + side + rail_lift, q + side + rail_lift, 0.015, scene::IVORY);
        if i % 2 == 0 {
            let foot = float3 { p.x, world::height(p.x, p.z), p.z };
            render::beam(out, foot, p, 0.06, scene::NAVY);
        }
    }
    let direction = normalize(float3 { delta.x, 0.0, delta.z });
    let arrows = max(1, floor(distance / 1.2) as i64);
    for i in arrows {
        let t: f32 = (i * 1.2 + (seconds * 0.9) % 1.2) / distance;
        if t >= 1.0 {
            continue;
        }
        let p = scene::path_point(a, b, t) + float3 { 0.0, 0.035, 0.0 };
        let tip = p + direction * ft::splat(0.2);
        let back = p - direction * ft::splat(0.12);
        let wing = side * ft::splat(0.65);
        render::triangle(out, tip, back + wing, back - wing, scene::ORANGE);
    }
}

fn reference_power_wires(out: ft::Vertex[>..]&) {
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || e.kind < 2 || e.kind > 8 || e.kind == 4 || e.kind == 7 {
            continue;
        }
        if length(e.pos - scene::visibility_center()) > 100.0 {
            continue;
        }
        var nearest: i64 = -1;
        var distance: f32 = 14.0;
        for j in ecs::entities.len {
            let source .= ecs::entities[j];
            if !source.alive || i == j || (source.kind != 1 && source.kind != 4 && source.kind != 5) {
                continue;
            }
            let d = length(source.pos - e.pos);
            if d < distance {
                nearest = j;
                distance = d;
            }
        }
        if nearest < 0 {
            continue;
        }
        let source .= ecs::entities[nearest];
        let a = source.pos + float3 { 0.0, if source.kind == 5 { 4.25 } else { 2.2 }, 0.0 };
        let b = e.pos + float3 { 0.0, if e.kind == 5 { 4.25 } else { 1.7 }, 0.0 };
        let color = if e.powered { float4 { 0.25, 0.64, 0.66, 1.2 } } else { scene::SLATE };
        var prev = a;
        for segment in 6 {
            let t: f32 = (segment + 1) / 6.0;
            let sag = float3 { 0.0, sin(t * PI) * distance * 0.08, 0.0 };
            let p = a * ft::splat(1.0 - t) + b * ft::splat(t) - sag;
            render::beam(out, prev, p, 0.018, color);
            prev = p;
        }
    }
}

fn verify_geometry() {
    var expected: ft::Vertex[>..] = [];
    for e in ecs::entities {
        if !e.alive || !sim::building(e.kind)
            || length(e.pos - scene::visibility_center()) > scene::visible_distance
        {
            continue;
        }
        for link in e.links {
            if !ecs::valid(link) || !sim::building(ecs::entities[link.slot].kind) {
                continue;
            }
            var complete: ft::Vertex[>..] = [];
            reference_conveyor(complete, e.pos, ecs::entities[link.slot].pos, 0.31);
            for vertex in complete {
                if vertex.color != scene::ORANGE {
                    expected.push(vertex);
                }
            }
        }
    }
    let actual = scene::build_rail_geometry();
    assert(same_vertices(expected, actual));
    assert(actual.len == scene::rail_mesh.count);

    var expected_wires: ft::Vertex[>..] = [];
    var actual_wires: ft::Vertex[>..] = [];
    reference_power_wires(expected_wires);
    scene::power_wires(actual_wires);
    assert(same_vertices(expected_wires, actual_wires));
}

fn verify_district_visuals() {
    for u in -120..121 {
        let p = showcase::position(u, 0.0);
        assert(!scene::clear_for_grove(p.x, p.z, false));
    }
    for v in -112..113 {
        let p = showcase::position(0.0, v);
        assert(!scene::clear_for_grove(p.x, p.z, false));
    }
    let axis_x: f32 = -0.77 * 400.0;
    let axis_z: f32 = -0.64 * 400.0;
    assert(!scene::clear_for_grove(axis_x, axis_z, true));
    assert(!scene::clear_for_grove(axis_x, axis_z, false));
    assert(scene::district_light_fade(0.375) == 0.0);
    assert(scene::district_light_fade(0.45) == 0.0);
    assert(scene::district_light_fade(0.49) > 0.0);
    assert(scene::district_light_fade(0.75) == 1.0);

    showcase::enabled = true;
    showcase::tower_position = showcase::position(0.0, 72.0);
    let p = showcase::position(0.0, 0.0);
    scene::district_night_strength = 0.0;
    var dark_windows: ft::Vertex[>..] = [];
    scene::district_windows(dark_windows, sim::SMELTER, p, 0.0);
    assert(dark_windows.len == 0);
    scene::district_night_strength = 1.0;
    for kind in [sim::LANDER, sim::SMELTER, sim::ASSEMBLER, sim::STORAGE] {
        var windows: ft::Vertex[>..] = [];
        scene::district_windows(windows, kind, p, 0.0);
        assert(windows.len > 0);
        for vertex in windows {
            assert(vertex.color.w > 1.0 && vertex.color.w <= 2.5);
        }
    }
    var outside: ft::Vertex[>..] = [];
    scene::district_windows(outside, sim::SMELTER, float3 { 600.0, 1.8, 600.0 }, 0.0);
    assert(outside.len == 0);

    var lit: ft::Vertex[>..] = [];
    var unlit: ft::Vertex[>..] = [];
    scene::district_landmarks(lit, 0.2);
    scene::district_landmarks(unlit, 0.7);
    var top: f32 = 0.0;
    var lit_signal: i64 = 0;
    var unlit_signal: i64 = 0;
    for vertex in lit {
        top = max(top, vertex.pos.y - showcase::tower_position.y);
        if vertex.pos.y - showcase::tower_position.y > 71.0 && vertex.color.x == 1.0 {
            lit_signal++;
        }
    }
    for vertex in unlit {
        if vertex.pos.y - showcase::tower_position.y > 71.0 && vertex.color.x == 1.0 {
            unlit_signal++;
        }
    }
    assert(top > 72.0 && top < 74.0);
    assert(lit_signal > 0 && unlit_signal == 0);
    assert(!sim::objective_done);
    showcase::enabled = false;
}

fn main() {
    world::seed = 73129;
    world::edits.clear();
    ecs::clear();
    sim::player = float3_0;
    let first_source = ecs::spawn(sim::SOLAR, float3 { -4.0, 1.8, 0.0 });
    let second_source = ecs::spawn(sim::SOLAR, float3 { 4.0, 1.8, 0.0 });
    let smelter = ecs::spawn(sim::SMELTER, float3 { 0.0, 1.8, 5.0 });
    let depot = ecs::spawn(sim::STORAGE, float3 { 8.0, 1.8, 5.0 });
    let relay = ecs::spawn(sim::RELAY, float3 { 12.0, 1.8, 0.0 });
    ecs::link(smelter, depot);
    ecs::link(depot, relay);
    ecs::link(relay, smelter);
    assert(gfx::open_headless(128, 96));
    scene::init();
    scene::sync_logistics();
    assert(scene::rail_rebuilds == 1 && scene::rail_uploads == 1);
    assert(scene::rail_live_meshes == 1 && scene::rail_mesh.count > 0);
    assert(scene::rail_buffer_bytes > 0);
    verify_geometry();
    assert(ecs::same(scene::wire_spans[0].source, first_source));

    let original_mesh = scene::rail_mesh.vertices.id;
    for i in 100 {
        world::next_revision++;
        sim::player.x = sin(i * 0.2) as! f32;
        scene::sync_logistics();
    }
    assert(scene::rail_rebuilds == 1 && scene::wire_rebuilds == 1);
    assert(scene::rail_mesh.vertices.id == original_mesh);
    ecs::entities[smelter.slot].powered = true;
    ecs::entities[smelter.slot].progress = 0.8;
    scene::sync_logistics();
    verify_geometry();
    assert(scene::rail_rebuilds == 1 && scene::wire_rebuilds == 1);

    var arrows_before: ft::Vertex[>..] = [];
    var arrows_after: ft::Vertex[>..] = [];
    let a = ecs::entities[smelter.slot].pos;
    let b = ecs::entities[depot.slot].pos;
    scene::conveyor_arrows(arrows_before, a, b, 0.0);
    scene::conveyor_arrows(arrows_after, a, b, 0.31);
    assert(!same_vertices(arrows_before, arrows_after));
    var original: ft::Vertex[>..] = [];
    var split: ft::Vertex[>..] = [];
    reference_conveyor(original, a, b, 0.31);
    scene::conveyor(split, a, b, 0.31);
    assert(same_vertices(original, split));

    world::edit(4.0, 5.0, 2.0);
    scene::sync_logistics();
    verify_geometry();
    let edited_rebuilds = scene::rail_rebuilds;
    world::edit(4.0, 5.0, 0.3);
    scene::sync_logistics();
    assert(scene::rail_rebuilds == edited_rebuilds + 1);
    assert(scene::wire_rebuilds == 1);
    verify_geometry();
    world::seed++;
    scene::sync_logistics();
    assert(scene::rail_rebuilds == edited_rebuilds + 2);

    ecs::entities[second_source.slot].pos.x = 0.0;
    scene::sync_logistics();
    verify_geometry();
    assert(ecs::same(scene::wire_spans[0].source, second_source));
    ecs::entities[second_source.slot].kind = sim::STORAGE;
    scene::sync_logistics();
    verify_geometry();
    assert(ecs::same(scene::wire_spans[0].source, first_source));
    ecs::link(smelter, relay);
    scene::sync_logistics();
    verify_geometry();
    ecs::unlink_all(relay);
    scene::sync_logistics();
    verify_geometry();

    ecs::destroy(depot);
    let replacement = ecs::spawn(sim::STORAGE, b);
    assert(replacement.slot == depot.slot && !ecs::valid(depot));
    ecs::link(smelter, replacement);
    scene::sync_logistics();
    verify_geometry();
    for stamp in scene::logistics_buildings {
        assert(!ecs::same(stamp.handle, depot));
    }

    let wires_before_travel = scene::wire_rebuilds;
    for round in 20 {
        sim::player = float3 { 1000.0, 0.0, 0.0 };
        scene::sync_logistics();
        assert(scene::rail_mesh.count == 0 && scene::rail_live_meshes == 0);
        assert(scene::rail_buffer_bytes == 0);
        verify_geometry();
        sim::player = float3_0;
        scene::sync_logistics();
        assert(scene::rail_mesh.count > 0 && scene::rail_live_meshes == 1);
        verify_geometry();
    }
    assert(scene::wire_rebuilds == wires_before_travel);
    sim::player = float3 { 1000.0, 0.0, 0.0 };
    scene::detached_view = true;
    scene::view_center = float3_0;
    scene::sync_logistics();
    assert(scene::rail_mesh.count > 0);
    verify_geometry();
    scene::view_center = float3 { 2000.0, 0.0, 0.0 };
    scene::sync_logistics();
    assert(scene::rail_mesh.count == 0);
    scene::detached_view = false;
    sim::player = float3_0;
    scene::sync_logistics();
    assert(scene::rail_mesh.count > 0);
    assert(scene::rail_peak_meshes <= 2);
    assert(scene::rail_uploads == scene::rail_releases + 1);
    verify_district_visuals();
    gfx::flush();
    scene::shutdown();
    assert(scene::rail_live_meshes == 0);
    assert(scene::rail_buffer_bytes == 0);
    assert(scene::rail_uploads == scene::rail_releases);
    gfx::close();
    ecs::clear();
    print("render_cache PASS: exact legacy geometry, animation, topology/edit/visibility invalidation; uploads=",
        scene::rail_uploads, " releases=", scene::rail_releases,
        " peak_live_meshes=", scene::rail_peak_meshes,
        " wire_rebuilds=", scene::wire_rebuilds);
}
