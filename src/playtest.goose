// Drives the ordinary application through official input injection. No test
// resource grants or direct simulation mutations are used in this scenario.
namespace driver;
import std;
import vec;
import math;
import os;
import gfx;
import .entities;
import .world;
import .sim;
import .hud;
var stage: i64 = 0;
var age: i64 = 0;
var total: i64 = 0;
var complete = false;
var initial: float3;
var saved: float3;
var ore: ecs::Handle;
var before_slots: i64 = 0;
var px: f32 = 0.0;
var py: f32 = 0.0;

fn click(down: bool) {
    gfx::inject_mouse(px, py, gfx::MOUSE_LEFT, down);
}

fn key(name: const u8[:], down: bool) {
    assert(gfx::inject_key(name, down));
}

fn stop() {
    key("W", false);
    key("A", false);
    key("S", false);
    key("D", false);
}

fn advance() {
    stage++;
    age = 0;
}

fn point(p: float3, eye: float3, target: float3) {
    let size = gfx::screen_size();
    let projection = gfx::perspective(0.959931, size.x / (size.y as f32), 0.1, 500.0);
    let view = gfx::look_at(eye, target, float3 { 0.0, 1.0, 0.0 });
    let vp = gfx::mul(projection, view);
    let q = gfx::mul(vp, float4 { p.x, p.y, p.z, 1.0 });
    assert(q.w > 0.0);
    px = (q.x / q.w * 0.5 + 0.5) * size.x;
    py = (0.5 - q.y / q.w * 0.5) * size.y;
    gfx::inject_mouse(px, py, 0, false);
}

fn find_ore() {
    if age > 30 {
        initial = sim::player;
        ore = sim::nearest(float3 { 8.0, world::height(8.0, 6.0), 6.0 }, 2.0, 20);
        assert(ecs::valid(ore));
        advance();
    }
}

fn walk_to_ore(eye: float3, target: float3) {
    let dest = ecs::entities[ore.slot].pos;
    let delta = float3 { dest.x - sim::player.x, 0.0, dest.z - sim::player.z };
    let d = sqrt(dot(delta, delta));
    if d < 4.5 {
        stop();
        advance();
    } else {
        let forward = normalize(float3 { target.x - eye.x, 0.0, target.z - eye.z });
        let right = cross(forward, float3 { 0.0, 1.0, 0.0 });
        let f = dot(delta, forward);
        let r = dot(delta, right);
        key("W", f > 0.4);
        key("S", f < -0.4);
        key("D", r > 0.4);
        key("A", r < -0.4);
    }
}

fn mine_ore(eye: float3, target: float3) {
    point(ecs::entities[ore.slot].pos + float3 { 0.0, 0.8, 0.0 }, eye, target);
    click(true);
    if sim::bag[0] >= 3 {
        click(false);
        advance();
    }
    assert(age < 90);
}

fn choose_drill() {
    if age == 1 {
        key("B", true);
    }
    if age == 2 {
        key("B", false);
    }
    if age == 4 {
        assert(hud::build_menu);
        key("1", true);
    }
    if age == 5 {
        key("1", false);
    }
    if age == 12 {
        assert(hud::chosen == 2 && !hud::build_menu);
        advance();
    }
}

fn place_drill_and_save(eye: float3, target: float3) {
    point(float3 { 8.0, world::height(8.0, 3.5), 3.5 }, eye, target);
    if age == 5 {
        click(true);
    }
    if age == 6 {
        click(false);
    }
    if age == 10 {
        let site = float3 { 8.0, world::height(8.0, 3.5), 3.5 };
        assert(ecs::valid(sim::nearest(site, 2.0, 2)));
        key("9", true);
    }
    if age == 11 {
        key("9", false);
    }
    if age == 15 {
        saved = sim::player;
        key("F5", true);
    }
    if age == 16 {
        key("F5", false);
    }
    if age == 20 {
        assert(file_exists("build/input-test.sav"));
        advance();
    }
}

fn load_and_stress() {
    if age == 1 {
        key("S", true);
    }
    if age == 25 {
        key("S", false);
    }
    if age == 35 {
        assert(sim::distance(saved, sim::player) > 0.5);
        key("F9", true);
    }
    if age == 36 {
        key("F9", false);
    }
    if age == 39 {
        assert(sim::distance(saved, sim::player) < 0.1);
        before_slots = ecs::alive_count;
        key("F2", true);
    }
    if age == 40 {
        key("F2", false);
    }
    if age == 43 {
        assert(ecs::alive_count >= before_slots + 1000);
        key("F3", true);
    }
    if age == 44 {
        key("F3", false);
    }
    if age == 47 {
        assert(ecs::alive_count <= before_slots + 2);
        key("F4", true);
    }
    if age == 48 {
        key("F4", false);
    }
    if age == 180 {
        key("F4", true);
    }
    if age == 181 {
        key("F4", false);
    }
    if age == 185 {
        assert(world::generated > 49);
        key("F9", true);
    }
    if age == 186 {
        key("F9", false);
    }
    if age == 195 {
        assert(sim::distance(initial, saved) > 0.5);
        assert(gfx::screenshot("artifacts/input-test.png"));
        let result = str(
            "{\"passed\":true,\"frames\":", total,
            ",\"mined\":", sim::bag[0],
            ",\"entity_slots\":", ecs::entities.len,
            ",\"chunks_generated\":", world::generated,
            ",\"actions\":\"walk,mine,build menu,place,save,walk,load,spawn1000,destroy1000,stream,load\"}\n",
        );
        assert(write_file("artifacts/input-test.json", result));
        print("INPUT PLAYTEST PASS ", result);
        complete = true;
    }
}

fn tick(eye: float3, target: float3) {
    total++;
    age++;
    assert(total < 900);
    if stage == 0 {
        find_ore();
    } else if stage == 1 {
        walk_to_ore(eye, target);
    } else if stage == 2 {
        mine_ore(eye, target);
    } else if stage == 3 {
        choose_drill();
    } else if stage == 4 {
        place_drill_and_save(eye, target);
    } else if stage == 5 {
        load_and_stress();
    }
}
