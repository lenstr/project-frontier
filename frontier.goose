import std;
import vec;
import math;
import os;
import gfx;
import src.types;
import src.entities;
import src.world;
import src.sim;
import src.render;
import src.scene;
import src.hud;
import src.persistence;
import src.sound;
import src.playtest;
import src.dev_panel;
import src.telemetry;
import src.horizon;
import src.showcase;
import src.free_flight;
import src.flight_playtest;
import src.memory;

var yaw: f32 = 0.873;
var pitch: f32 = 0.24;
var distance: f32 = 12.0;
var eye = float3 { 10.0, 16.0, 15.0 };
var camera_target = float3 { 0.0, 3.0, 0.0 };
var velocity = float3_0;
var vertical: f32 = 0.0;
var facing: f32 = 0.0;
var selected: ecs::Handle;
var link_source: ecs::Handle;
var ground = float3_0;
var mine_cooldown: f32 = 0.0;
var radius: i64 = 6;
var shadows = true;
var frame_limit: i64 = -1;
var demo = false;
var colony_demo = false;
var initial_load: i64 = 512;
var start_position = false;
var start_x: f32 = 0.0;
var start_z: f32 = 0.0;
var benchmark = false;
var offscreen = false;
var playtest = false;
var flight_test = false;
var victory = false;
var hero = false;
var automated = false;
var start_flight = false;
var rapid_stream = false;
var stream_timer: f32 = 0.0;
var render_frames: i64 = 0;
var screenshot_path: u8[..240] = "artifacts/frontier.png";
var save_path: u8[..240] = "frontier.sav";
var seed: u32 = 73129;
var start_day: f32 = -1.0;
var quit = false;
var completed_sound = false;
var has_ground = false;
var frame_times: f64[>..] = [];
var sim_times: f64[>..] = [];
var draw_times: f64[>..] = [];
var mesh_times: f64[>..] = [];
var ui_times: f64[>..] = [];
var gpu_wait_times: f64[>..] = [];

fn squared(a: float3, b: float3) -> f32 {
    let d = a - b;
    dot(d, d)
}

fn position(x: f32, z: f32) -> float3 {
    float3 { x, world::height(x, z), z }
}

fn camera(dt: f32) {
    if flight::enabled {
        survey_camera(dt);
        return;
    }
    if gfx::mouse_down(gfx::MOUSE_RIGHT) && !hud::build_menu && !hud::help && !hud::paused
        && !dev::wants_mouse()
    {
        gfx::set_mouse_relative(true);
        let d = gfx::mouse_delta();
        yaw -= d.x * 0.003 * dev::settings.camera_speed;
        pitch += d.y * 0.003 * dev::settings.camera_speed;
    } else if gfx::mouse_relative() {
        gfx::set_mouse_relative(false);
    }
    if gfx::key_down("Left") && !dev::wants_keyboard() {
        yaw += dt * 1.7;
    }
    if gfx::key_down("Right") && !dev::wants_keyboard() {
        yaw -= dt * 1.7;
    }
    if gfx::key_down("Up") && !dev::wants_keyboard() {
        pitch -= dt;
    }
    if gfx::key_down("Down") && !dev::wants_keyboard() {
        pitch += dt;
    }
    if !dev::wants_mouse() {
        distance = clamp(distance - gfx::mouse_wheel() * 1.5, 4.0, 28.0);
    }
    pitch = clamp(pitch, if hero && victory { 0.06 } else { 0.17 }, 1.22);
    let build = hud::chosen != 0;
    let d = if hero && victory { 30.0 } else if build { max(16.0, distance) } else { distance };
    let p = if build { max(0.85, pitch) } else { pitch };
    let desired_target = sim::player + float3 { 0.0, 1.2, 0.0 };
    camera_target += (desired_target - camera_target) * ft::splat(1.0 - exp(-dt * 10.0));
    var desired = camera_target + float3 {
        sin(yaw) * cos(p) * d,
        sin(p) * d,
        cos(yaw) * cos(p) * d,
    };
    for i in 1..20 {
        let t: f32 = i / 20.0;
        let sample = camera_target + (desired - camera_target) * ft::splat(t);
        if sample.y < world::height(sample.x, sample.z) + 0.4 {
            desired = camera_target + (desired - camera_target) * ft::splat(max(0.2, t - 0.06));
            break;
        }
    }
    eye += (desired - eye) * ft::splat(1.0 - exp(-dt * 14.0));
}

fn survey_camera(dt: f32) {
    var input = flight::Input { .. };
    let available = !hud::paused && !hud::help && !dev::wants_keyboard();
    if available {
        input.forward = (if gfx::key_down("W") { 1.0 } else { 0.0 })
            - (if gfx::key_down("S") { 1.0 } else { 0.0 });
        input.right = (if gfx::key_down("D") { 1.0 } else { 0.0 })
            - (if gfx::key_down("A") { 1.0 } else { 0.0 });
        input.lift = (if gfx::key_down("E") || gfx::key_down("Space") { 1.0 } else { 0.0 })
            - (if gfx::key_down("Q") || gfx::key_down("Left Ctrl") { 1.0 } else { 0.0 });
        input.boost = gfx::key_down("Left Shift");
        if !dev::wants_mouse() {
            input.wheel = gfx::mouse_wheel();
        }
        if gfx::mouse_down(gfx::MOUSE_RIGHT) && !dev::wants_mouse() {
            gfx::set_mouse_relative(true);
            let delta = gfx::mouse_delta();
            input.yaw_delta = -delta.x * 0.003 * dev::settings.camera_speed;
            input.pitch_delta = delta.y * 0.003 * dev::settings.camera_speed;
        } else if gfx::mouse_relative() {
            gfx::set_mouse_relative(false);
        }
        input.yaw_delta += dt * 1.7 * ((if gfx::key_down("Left") { 1.0 } else { 0.0 })
            - (if gfx::key_down("Right") { 1.0 } else { 0.0 }));
        input.pitch_delta += dt * ((if gfx::key_down("Down") { 1.0 } else { 0.0 })
            - (if gfx::key_down("Up") { 1.0 } else { 0.0 }));
    } else if gfx::mouse_relative() {
        gfx::set_mouse_relative(false);
    }
    flight::speed = dev::settings.flight_speed;
    flight::update(input, if available { dt } else { 0.0 });
    flight::eye.y = clamp(flight::eye.y, world::height(flight::eye.x, flight::eye.z) + 3.0, 1800.0);
    dev::settings.flight_speed = flight::speed;
    eye = flight::eye;
    camera_target = flight::target();
}

fn toggle_flight() {
    hud::chosen = 0;
    hud::build_menu = false;
    hud::help = false;
    link_source = ecs::Handle {};
    velocity = float3_0;
    vertical = 0.0;
    if flight::enabled {
        flight::leave();
        camera_target = sim::player + float3 { 0.0, 1.2, 0.0 };
        eye = camera_target + float3 {
            sin(yaw) * cos(pitch) * distance,
            sin(pitch) * distance,
            cos(yaw) * cos(pitch) * distance,
        };
        sim::say("Returned to your suit. G opens free flight.");
    } else {
        flight::enter(sim::player, yaw);
        eye = flight::eye;
        camera_target = flight::target();
        sim::say("Survey flight: WASD move, Q/E altitude, Shift boost, wheel speed, Home overview, G return.");
    }
    if gfx::mouse_relative() {
        gfx::set_mouse_relative(false);
    }
}

fn reframe_flight() {
    if !flight::enabled {
        toggle_flight();
    }
    let anchor = if ecs::valid(sim::base) { ecs::entities[sim::base.slot].pos } else { sim::player };
    flight::enter(anchor, 0.873);
    eye = flight::eye;
    camera_target = flight::target();
}

fn streaming_focus() -> float3 {
    if !flight::enabled {
        return sim::player;
    }
    let focus = flight::stream_focus(world::height(eye.x, eye.z));
    position(focus.x, focus.z)
}

fn blocked(p: float3) -> bool {
    for e in ecs::entities {
        if !e.alive || e.kind == 7 || e.kind >= 20 {
            continue;
        }
        let r: f32 = if e.kind == 1 { 2.2 } else if e.kind == 5 { 0.65 } else { 1.15 };
        if squared(float3 { p.x, 0.0, p.z }, float3 { e.pos.x, 0.0, e.pos.z }) < r * r {
            return true;
        }
    }
    false
}

fn movement(dt: f32) {
    var forward: f32 = 0.0;
    var right: f32 = 0.0;
    if gfx::key_down("W") {
        forward += 1.0;
    }
    if gfx::key_down("S") {
        forward -= 1.0;
    }
    if gfx::key_down("D") {
        right += 1.0;
    }
    if gfx::key_down("A") {
        right -= 1.0;
    }
    var direction = float3 {
        -sin(yaw) * forward + cos(yaw) * right,
        0.0,
        -cos(yaw) * forward - sin(yaw) * right,
    };
    let len = sqrt(dot(direction, direction));
    if len > 0.01 {
        direction = direction * ft::splat(1.0 / len);
        facing = atan2(-direction.x, -direction.z);
    }
    let speed: f32 = if gfx::key_down("Left Shift") { 9.5 } else { 5.2 };
    velocity += (direction * ft::splat(speed) - velocity) * ft::splat(1.0 - exp(-dt * 12.0));
    let previous = sim::player;
    var next = previous + velocity * ft::splat(dt);
    let gx = world::height(next.x, previous.z);
    let gz = world::height(previous.x, next.z);
    if !blocked(float3 { next.x, previous.y, previous.z }) && gx < previous.y + 1.0 {
        sim::player.x = next.x;
    }
    if !blocked(float3 { sim::player.x, previous.y, next.z }) && gz < previous.y + 1.0 {
        sim::player.z = next.z;
    }
    let floor_y = world::height(sim::player.x, sim::player.z);
    if sim::player.y <= floor_y + 0.04 && gfx::key_pressed("Space") {
        vertical = 7.0;
    }
    vertical -= 18.0 * dt;
    sim::player.y += vertical * dt;
    if sim::player.y < floor_y {
        sim::player.y = floor_y;
        vertical = 0.0;
    }
}

fn aim() {
    let size = gfx::screen_size();
    let cursor = gfx::mouse_pos();
    let forward = normalize(camera_target - eye);
    let right = normalize(cross(forward, float3 { 0.0, 1.0, 0.0 }));
    let up = cross(right, forward);
    let aspect = size.x / (size.y as f32);
    let angle: f32 = 0.959931 * 0.5;
    let factor = tan(angle);
    let mx = if gfx::mouse_relative() { 0.0 } else { cursor.x / size.x * 2.0 - 1.0 };
    let my = if gfx::mouse_relative() { 0.0 } else { 1.0 - cursor.y / size.y * 2.0 };
    let ray = normalize(
        forward + right * ft::splat(mx * factor * aspect) + up * ft::splat(my * factor),
    );
    var depth: f32 = if flight::enabled { 1600.0 } else { 80.0 };
    has_ground = false;
    for i in if flight::enabled { 400 } else { 200 } {
        let step: f32 = if flight::enabled { 4.0 } else { 0.4 };
        let t: f32 = i * step;
        let p = eye + ray * ft::splat(t);
        if p.y <= world::height(p.x, p.z) {
            ground = position(p.x, p.z);
            depth = t;
            has_ground = true;
            break;
        }
    }
    selected = ecs::Handle {};
    var best = depth + 2.0;
    for i in ecs::entities.len {
        let e .= ecs::entities[i];
        if !e.alive || e.kind >= 90 {
            continue;
        }
        let center = e.pos + float3 { 0.0, if e.kind == 1 { 2.2 } else { 1.0 }, 0.0 };
        let t = dot(center - eye, ray);
        if t < 0.0 || t > best {
            continue;
        }
        let r: f32 = if e.kind == 1 { 2.8 } else if e.kind >= 20 { 1.8 } else { 1.5 };
        if squared(center, eye + ray * ft::splat(t)) < r * r {
            selected = ecs::Handle { i, e.generation };
            best = t;
        }
    }
}

fn save_game() {
    showcase::flush_escrow();
    if save::write(save_path) {
        sim::say("Expedition saved.");
    } else {
        sim::say("Save failed. Check the destination directory.");
    }
}

fn default_save() {
    var user_home: u8[>..] = [];
    if !env("HOME", user_home) {
        return;
    }
    if is_dir(str(user_home, "/Library/Application Support")) {
        let directory = str(user_home, "/Library/Application Support/Project Frontier");
        if make_dir(directory) {
            save_path = str(directory, "/frontier.sav");
        }
    } else {
        make_dir(str(user_home, "/.local"));
        make_dir(str(user_home, "/.local/share"));
        let directory = str(user_home, "/.local/share/project-frontier");
        if make_dir(directory) {
            save_path = str(directory, "/frontier.sav");
        }
    }
}

fn load_game() {
    if save::load(save_path) {
        memory::request_trim();
        flight::leave();
        showcase::forget();
        dev::settings.load = 0;
        sim::say("Expedition restored.");
        selected = ecs::Handle {};
        link_source = ecs::Handle {};
        velocity = float3_0;
        vertical = 0.0;
    } else {
        sim::say("No valid save found. Current expedition is safe.");
    }
}

fn deposit() {
    if !ecs::valid(selected) {
        return;
    }
    if squared(sim::player, ecs::entities[selected.slot].pos) > 144.0 {
        sim::say("Move closer to transfer cargo.");
        return;
    }
    for r in 5 {
        let n = min(10, sim::bag[r]);
        if n > 0 && ecs::add(selected, r, n) {
            sim::bag[r] -= n;
        }
    }
    sim::say("Cargo deposited. Production starts when powered.");
}

// Keyboard shortcuts that work in every mode, including menus and pause.
fn hotkeys() {
    if gfx::key_pressed("F1") {
        dev::toggle();
    }
    if gfx::key_pressed("G") || gfx::key_pressed("F10") || hud::flight_requested {
        toggle_flight();
    }
    if gfx::key_pressed("Home") && flight::enabled {
        reframe_flight();
    }
    if gfx::key_pressed("Tab") {
        hud::help = !hud::help;
        hud::paused = false;
    }
    if gfx::key_pressed("B") && !flight::enabled {
        hud::build_menu = !hud::build_menu;
        hud::help = false;
    }
    if gfx::key_pressed("Escape") {
        if hud::build_menu {
            hud::build_menu = false;
        } else if hud::help {
            hud::help = false;
        } else if hud::chosen != 0 {
            hud::chosen = 0;
        } else {
            hud::paused = !hud::paused;
        }
    }
    let keys: const u8[:][9] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"];
    for i in 9 {
        if gfx::key_pressed(keys[i]) && !flight::enabled {
            hud::chosen = hud::KINDS[i];
            hud::build_menu = false;
        }
    }
    if gfx::key_pressed("F5") || hud::request_save {
        save_game();
    }
    if gfx::key_pressed("F9") || hud::request_load {
        load_game();
    }
    if gfx::key_pressed("O") {
        shadows = !shadows;
        dev::settings.shadows = shadows;
    }
    if gfx::key_pressed("=") {
        radius = min(world::MAX_RADIUS, radius + 1);
        dev::settings.detail_radius = radius;
    }
    if gfx::key_pressed("-") {
        radius = max(2, radius - 1);
        dev::settings.detail_radius = radius;
    }
    if gfx::key_pressed("F2") {
        sim::stress_spawn(1000);
    }
    if gfx::key_pressed("F3") {
        sim::stress_destroy(1000);
    }
    if gfx::key_pressed("F4") {
        rapid_stream = !rapid_stream;
        dev::actions.rapid_stream = rapid_stream;
        sim::say(if rapid_stream { "Rapid streaming enabled." } else { "Rapid streaming disabled." });
    }
    if gfx::key_pressed("F6") {
        sim::spawn_robot(sim::player + float3 { 2.0, 0.0, 0.0 });
    }
    if gfx::key_pressed("F7") {
        sim::network_stress();
    }
    if gfx::key_pressed("F8") {
        sim::day = (sim::day + 0.25) % 1.0;
    }
    if dev::wants_keyboard() || flight::enabled {
        return;
    }
    if gfx::key_pressed("C") {
        sim::manual_smelt();
    }
    if gfx::key_pressed("V") {
        sim::manual_circuit();
    }
    if gfx::key_pressed("E") && ecs::valid(selected) {
        sim::collect(selected);
    }
    if gfx::key_pressed("F") {
        deposit();
    }
    if gfx::key_pressed("R") && ecs::valid(selected) {
        if sim::reclaim(selected) {
            scene::burst(ground, ft::rgb(0.37, 0.95, 0.88));
        }
    }
    if gfx::key_pressed("Q") && ecs::valid(selected) {
        if ecs::valid(link_source) {
            if sim::link(link_source, selected) {
                sound::build();
            }
            link_source = ecs::Handle {};
        } else {
            link_source = selected;
            sim::say("Choose a destination and press Q.");
        }
    }
}

fn place_blueprint() {
    if hud::chosen != 0 && gfx::mouse_pressed(gfx::MOUSE_LEFT) {
        if !has_ground {
            return;
        }
        if squared(sim::player, ground) > 900.0 {
            sim::say("Build within 30 m of your suit.");
            return;
        }
        let h = sim::build(hud::chosen, ground);
        if ecs::valid(h) {
            scene::burst(ground, ft::rgb(0.37, 0.95, 0.88));
            sound::build();
        }
    }
}

fn use_terrain_tool() {
    if hud::chosen == 0 && gfx::mouse_down(gfx::MOUSE_LEFT) && mine_cooldown <= 0.0 {
        if !has_ground && !ecs::valid(selected) {
            return;
        }
        if squared(sim::player, ground) > 196.0 {
            sim::say("Move closer to use the terrain tool.");
            mine_cooldown = 0.4;
            return;
        }
        var success = false;
        if ecs::valid(selected) && ecs::entities[selected.slot].kind >= 20 {
            success = sim::mine(selected);
        } else {
            sim::dig(ground.x, ground.z, if gfx::key_down("Left Shift") { 0.5 } else { -0.5 });
            success = true;
        }
        if success {
            scene::burst(ground, ft::rgb(0.83, 0.4, 0.32));
            sound::mine();
        }
        mine_cooldown = 0.18;
    }
}

fn controls(dt: f32) {
    hotkeys();
    if flight::enabled {
        return;
    }
    if hud::paused || hud::help || hud::build_menu || hud::mouse_over
        || dev::wants_mouse() || dev::wants_keyboard()
    {
        return;
    }
    movement(dt);
    mine_cooldown -= dt;
    place_blueprint();
    use_terrain_tool();
}

fn demo_colony() {
    sim::bag = [200, 100, 250, 20, 200];
    let drill = sim::build(2, position(8.0, 6.0));
    let smelter = sim::build(3, position(8.0, 0.0));
    let assembler = sim::build(6, position(13.0, 0.0));
    let depot = sim::build(9, position(13.0, -6.0));
    sim::build(4, position(0.0, -6.0));
    sim::build(4, position(-5.0, -6.0));
    sim::build(5, position(6.0, -6.0));
    sim::link(drill, smelter);
    sim::link(smelter, assembler);
    sim::link(assembler, depot);
    ecs::add(assembler, 1, 40);
    ecs::add(smelter, 0, 40);
    sim::build(7, position(-4.0, 4.0));
    sim::build(7, position(-6.0, 4.0));
    sim::player = position(0.0, 10.0);
    distance = 25.0;
    pitch = 0.40;
    yaw = 0.72;
    sim::say("A working colony. Explore, extend the rails, and build the beacon.");
}

fn percentile(xs: f64[:], p: f64) -> f64 {
    if xs.len == 0 {
        return 0.0;
    }
    xs[min(xs.len - 1, (xs.len * p) as! i64)]
}

fn report() {
    if frame_times.len == 0 {
        return;
    }
    var total: f64 = 0.0;
    for n in frame_times {
        total += n;
    }
    sort(frame_times) { a, b => a < b };
    sort(sim_times) { a, b => a < b };
    sort(draw_times) { a, b => a < b };
    sort(mesh_times) { a, b => a < b };
    sort(ui_times) { a, b => a < b };
    sort(gpu_wait_times) { a, b => a < b };
    let screen = gfx::screen_size();
    let result = str(
        "{\n  \"synchronous_gpu_completion\": true,\n  \"resolution\": [", screen.x, ",", screen.y,
        "],\n  \"frames\": ", frame_times.len,
        ",\n  \"average_fps\": ", frame_times.len * 1000.0 / total,
        ",\n  \"frame_ms_p50\": ", percentile(frame_times, 0.5),
        ",\n  \"frame_ms_p95\": ", percentile(frame_times, 0.95),
        ",\n  \"frame_ms_p99\": ", percentile(frame_times, 0.99),
        ",\n  \"simulation_ms_p95\": ", percentile(sim_times, 0.95),
        ",\n  \"render_cpu_ms_p95\": ", percentile(draw_times, 0.95),
        ",\n  \"mesh_cpu_ms_p95\": ", percentile(mesh_times, 0.95),
        ",\n  \"ui_cpu_ms_p95\": ", percentile(ui_times, 0.95),
        ",\n  \"gpu_completion_wait_ms_p95\": ", percentile(gpu_wait_times, 0.95),
        ",\n  \"entity_slots\": ", ecs::entities.len,
        ",\n  \"active_entities\": ", ecs::alive_count,
        ",\n  \"chunk_slots\": ", world::chunks.len,
        ",\n  \"generated_chunks\": ", world::generated,
        ",\n  \"generation_cpu_total_ms\": ", world::generation_total_ms,
        ",\n  \"queue_calls_total_ms\": ", world::transfer_ms,
        ",\n  \"quality_radius\": ", radius,
        ",\n  \"horizon_meshes\": ", horizon::mesh_count,
        ",\n  \"horizon_triangles\": ", horizon::triangles,
        ",\n  \"submitted_triangles\": ", render::triangles,
        ",\n  \"draw_calls\": ", render::draw_calls,
        ",\n  \"dynamic_gpu_capacity_bytes\": ", render::dynamic_capacity,
        ",\n  \"showcase_load\": ", showcase::load,
        ",\n  \"developer_panel_mode\": ", dev::mode,
        ",\n  \"shadows\": ", shadows,
        "\n}\n",
    );
    print(result);
    write_file("artifacts/benchmark.json", result);
}

// Flags that only affect startup; everything else is stored in globals.
struct LaunchOptions {
    help: bool,
    resume: bool,
    mute: bool,
    headless: bool,
    stress: i64,
    custom_save: bool,
}

fn parse_options() -> LaunchOptions {
    let argv = args();
    var options = LaunchOptions {
        help: false, resume: false, mute: false, headless: false, stress: 0, custom_save: false,
    };
    var i: i64 = 1;
    while i < argv.len {
        let a = argv[i];
        if a == "--help" || a == "-h" {
            print(
                "Project Frontier / Goose v2026.3+git.a108677d300c\n",
                "Usage: ./run.sh [--resume] [--save PATH] [--seed N] [--quality low|medium|high]\n",
                "       ./run.sh --demo [--hero] [--victory] [--time 0..1]\n",
                "       ./run.sh --showcase [--load 32..2000] [--devtools] [--dev-tab 0..4]\n",
                "       ./run.sh --showcase --flight   # Detached strategic overview\n",
                "       ./run.sh --offscreen --frames N [--benchmark] [--screenshot PATH]\n",
                "       Add --rapid-stream for repeatable automatic chunk travel.\n",
                "       ./run.sh --stress N | --playtest | --flight-test\n",
                "WASD walk, Shift sprint, Space jump, right-drag orbit, wheel zoom.\n",
                "G/F10 free flight; WASD move, Q/E altitude, Shift boost, wheel speed, Home overview.\n",
                "Hold left click mine/dig; Shift+click fills terrain. B builds; 1-8 blueprints, 9 tool.\n",
                "Q source then Q destination connects conveyors. E collect, F deposit, R reclaim.\n",
                "C refine Ferrite, V craft Circuits. F5 save, F9 load, Tab field guide, Esc pause.\n",
                "F1 developer panel: full / compact / closed; F2/F3 +/-1000; F4 rapid stream.\n",
                "F6 robot; F7 networks; F8 time. --wireframe and --position X Z are inspection tools.\n",
                "F12 screenshot; +/- streaming quality; O shadows. --mute disables sound.",
            );
            options.help = true;
            return options;
        }
        if a == "--frames" && i + 1 < argv.len {
            let n, ok = parse_int(argv[i + 1]);
            if ok {
                frame_limit = max(1, n);
                automated = true;
            }
            i++;
        } else if a == "--demo" {
            demo = true;
        }
        if a == "--showcase" {
            colony_demo = true;
        }
        if a == "--flight" {
            start_flight = true;
        }
        if a == "--rapid-stream" {
            rapid_stream = true;
            dev::actions.rapid_stream = true;
        }
        if a == "--load" && i + 1 < argv.len {
            let n, ok = parse_int(argv[i + 1]);
            if ok {
                initial_load = clamp(n, 32, 2000);
            }
            i++;
        }
        if a == "--devtools" {
            dev::mode = 1;
            dev::open = true;
        }
        if a == "--dev-tab" && i + 1 < argv.len {
            let value, ok = parse_int(argv[i + 1]);
            if ok {
                dev::tab = clamp(value, 0, 4);
                dev::mode = 1;
                dev::open = true;
            }
            i++;
        }
        if a == "--wireframe" {
            dev::settings.show_wireframe = true;
        }
        if a == "--position" && i + 2 < argv.len {
            let x, x_ok = parse_flt(argv[i + 1]);
            let z, z_ok = parse_flt(argv[i + 2]);
            if x_ok && z_ok {
                start_position = true;
                start_x = x as f32;
                start_z = z as f32;
            }
            i += 2;
        }
        if a == "--benchmark" {
            benchmark = true;
        }
        if a == "--victory" {
            victory = true;
            demo = true;
        }
        if a == "--hero" {
            hero = true;
            demo = true;
        }
        if a == "--debug-overlay" {
            dev::mode = 1;
            dev::open = true;
        }
        if a == "--offscreen" {
            offscreen = true;
        }
        if a == "--playtest" {
            playtest = true;
            offscreen = true;
            automated = true;
            frame_limit = 900;
            save_path = "build/input-test.sav";
            options.custom_save = true;
        }
        if a == "--flight-test" {
            flight_test = true;
            offscreen = true;
            automated = true;
            frame_limit = 240;
        }
        if a == "--resume" {
            options.resume = true;
        }
        if a == "--mute" {
            options.mute = true;
        }
        if a == "--headless" {
            options.headless = true;
        }
        if a == "--stress" && i + 1 < argv.len {
            let n, ok = parse_int(argv[i + 1]);
            if ok {
                options.stress = max(1, n);
            }
            i++;
        }
        if a == "--quality" && i + 1 < argv.len {
            let q = argv[i + 1];
            radius = if q == "low" { 3 } else if q == "high" { 8 } else { 6 };
            shadows = q != "low";
            i++;
        }
        if a == "--seed" && i + 1 < argv.len {
            let n, ok = parse_int(argv[i + 1]);
            if ok {
                seed = n as! u32;
            }
            i++;
        }
        if a == "--time" && i + 1 < argv.len {
            let n, ok = parse_flt(argv[i + 1]);
            if ok {
                start_day = (n as f32) % 1.0;
            }
            i++;
        }
        if a == "--save" && i + 1 < argv.len {
            save_path = argv[i + 1];
            options.custom_save = true;
            i++;
        }
        if a == "--screenshot" && i + 1 < argv.len {
            screenshot_path = argv[i + 1];
            i++;
        }
        i++;
    }
    options
}

// Headless allocation and streaming churn without opening a window.
fn run_stress(stress: i64) {
    let rounds = max(10, stress);
    let start = clock();
    for round in rounds {
        sim::stress_spawn(1000);
        sim::tick(1.0 / 60.0);
        sim::stress_destroy(1000);
        let x = (round % 11) * 160.0 - 800.0;
        let z = (round / 11) * 64.0;
        for n in 4 {
            world::stream(x, z, 2, 8);
            world::drain();
        }
        if round % 20 == 0 {
            print(
                "stress round=", round,
                " entity_slots=", ecs::entities.len,
                " chunk_slots=", world::chunks.len,
                " inv=", ecs::inventories.len,
                " queues=", ecs::queues.len,
                " edges=", ecs::edges.len,
            );
        }
    }
    print(
        "STRESS PASS rounds=", rounds,
        " elapsed_ms=", (clock() - start) * 1000.0,
        " entity_slots=", ecs::entities.len,
        " chunk_slots=", world::chunks.len,
        " generated=", world::generated,
    );
}

// Runs frames until the window closes, the player quits or an automated run ends.
fn developer_actions() {
    if dev::actions.trim_memory {
        memory::request_trim();
    }
    if dev::actions.toggle_flight {
        toggle_flight();
    }
    if dev::actions.reframe_flight {
        reframe_flight();
    }
    if dev::actions.save {
        save_game();
    }
    if dev::actions.load {
        load_game();
    }
    if dev::actions.spawn_objects > 0 {
        sim::stress_spawn(dev::actions.spawn_objects);
    }
    if dev::actions.destroy_objects > 0 {
        sim::stress_destroy(dev::actions.destroy_objects);
    }
    for i in dev::actions.spawn_robots {
        sim::spawn_robot(sim::player + float3 { 3.0 + i % 5, 0.0, 3.0 + i / 5 });
    }
    if dev::actions.churn_rounds > 0 {
        let before = ecs::entities.len;
        let cells_before = ecs::inventories.len + ecs::queues.len + ecs::edges.len;
        let started = clock();
        for round in dev::actions.churn_rounds {
            sim::stress_spawn(1000);
            sim::stress_destroy(1000);
        }
        let elapsed_ms = (clock() - started) * 1000.0;
        dev::last_churn = dev::ChurnResult {
            completed: true,
            elapsed_ms: elapsed_ms,
            slots_before: before,
            slots_after: ecs::entities.len,
            cells_before: cells_before,
            cells_after: ecs::inventories.len + ecs::queues.len + ecs::edges.len,
        };
        sim::say(str("Churn: ", dev::decimal(elapsed_ms, 2), " ms; slots ", before, " -> ", ecs::entities.len));
        stats::refresh();
        memory::request_trim();
    }
    let load_changed = showcase::enabled && dev::settings.load != showcase::load;
    if dev::actions.build_showcase || (load_changed && !gfx::mouse_down(gfx::MOUSE_LEFT)) {
        let previous_load = showcase::load;
        showcase::set_load(dev::settings.load);
        if showcase::load < previous_load {
            memory::request_trim();
        }
        scene::invalidate();
        sim::say(str("Live colony: ", showcase::load, " entities. Inputs and production queues are real."));
    }
    if dev::actions.reset_stats {
        stats::reset_history();
    }
    rapid_stream = dev::actions.rapid_stream;
    radius = clamp(dev::settings.detail_radius, 2, world::MAX_RADIUS);
    shadows = dev::settings.shadows;
    sim::robot_path_budget = dev::settings.robot_budget;
    scene::vegetation = dev::settings.vegetation;
    scene::vegetation_center = eye;
    render::wireframe = dev::settings.show_wireframe;
    render::fog_clear = dev::settings.fog_start;
    render::visibility = dev::settings.fog_distance;
    render::horizon_edge = if flight::enabled {
        flight::horizon_distance(world::height(eye.x, eye.z))
    } else {
        clamp(dev::settings.fog_distance * 1.28, 1536.0, 2432.0)
    };
    scene::inspector_target = dev::pinned;
    scene::detached_view = flight::enabled;
    scene::view_center = streaming_focus();
}

fn advance_simulation(dt: f32) -> stats::Frame {
    var result = stats::Frame { .. };
    if hud::paused || hud::help {
        return result;
    }
    var remaining: f32 = dt * dev::settings.simulation_speed;
    if dev::actions.single_step {
        remaining = 1.0 / 60.0;
    }
    while remaining > 0.000001 {
        let step = min(remaining, 0.05);
        sim::tick(step);
        result.simulation_ms += sim::simulation_ms;
        result.power_ms += sim::power_ms;
        result.production_ms += sim::production_ms;
        result.transport_ms += sim::transport_ms;
        result.robots_ms += sim::robots_ms;
        remaining -= step;
    }
    if dev::settings.lock_time {
        sim::day = dev::settings.day_phase;
    } else {
        dev::settings.day_phase = sim::day;
    }
    return result;
}

// Every sample belongs to the same frame. Presentation waiting is included in
// total time; the CPU rendering and UI columns exclude the explicit GPU wait.
fn run_frames() -> i64 {
    var drawn: i64 = 0;
    while true {
        let frame_started = clock();
        if !gfx::frame() {
            break;
        }
        // Input scripts are frame-based even when collecting wall-clock timings.
        let dt: f32 = if playtest || flight_test || (automated && !benchmark) {
            1.0 / 60.0
        } else {
            clamp(gfx::delta_time() as f32, 0.001, 0.05)
        };
        var sample = stats::Frame { .. };
        let input_started = clock();
        hud::begin_frame();
        dev::begin_frame();
        camera(dt);
        aim();
        let early_input_ms = (clock() - input_started) * 1000.0;
        let ui_build_started = clock();
        hud::developer_mode = dev::mode;
        dev::flight_active = flight::enabled;
        dev::flight_altitude = eye.y - world::height(eye.x, eye.z);
        hud::draw(selected, link_source, ground);
        dev::draw(selected);
        let ui_build_ms = (clock() - ui_build_started) * 1000.0;
        let controls_started = clock();
        if hud::developer_requested {
            dev::toggle();
        }
        if hud::clicked_kind >= 0 {
            hud::chosen = hud::clicked_kind;
        }
        if (dev::pick_armed && gfx::mouse_pressed(gfx::MOUSE_LEFT) && !dev::wants_mouse())
            || (gfx::mouse_pressed(gfx::MOUSE_MIDDLE) && !dev::wants_mouse())
        {
            dev::pinned = selected;
            dev::pick_armed = false;
        } else {
            controls(dt);
        }
        developer_actions();
        sample.input_ms = early_input_ms + (clock() - controls_started) * 1000.0;
        if hud::request_quit {
            quit = true;
        }
        if rapid_stream {
            stream_timer += dt;
            if stream_timer > 1.0 {
                stream_timer = 0.0;
                if flight::enabled {
                    flight::eye.x += 128.0;
                } else {
                    sim::player.x += 128.0;
                    sim::player.y = world::height(sim::player.x, sim::player.z);
                }
            }
        }
        let simulation = advance_simulation(dt);
        sample.simulation_ms = simulation.simulation_ms;
        sample.power_ms = simulation.power_ms;
        sample.production_ms = simulation.production_ms;
        sample.transport_ms = simulation.transport_ms;
        sample.robots_ms = simulation.robots_ms;
        let stream_started = clock();
        let focus = streaming_focus();
        world::stream(focus.x, focus.z, radius, 4);
        sample.stream_ms = (clock() - stream_started) * 1000.0;
        let mesh_started = clock();
        scene::sync(dev::settings.mesh_budget);
        horizon::update(focus, radius * 32.0, render::horizon_edge, 1);
        sample.mesh_ms = (clock() - mesh_started) * 1000.0;
        hud::mesh_ms = sample.mesh_ms;
        render::stream_radius = radius * 32.0;
        hud::quality = radius;
        let render_started = clock();
        scene::draw(
            eye, camera_target, sim::day, sim::elapsed, selected, if flight::enabled { 0 } else { hud::chosen }, ground,
            sim::can_build(hud::chosen), shadows,
        );
        sample.render_ms = (clock() - render_started) * 1000.0;
        let ui_started = clock();
        dev::present();
        hud::present();
        sample.ui_ms = ui_build_ms + (clock() - ui_started) * 1000.0;
        if benchmark {
            let wait_started = clock();
            gfx::flush();
            sample.gpu_wait_ms = (clock() - wait_started) * 1000.0;
        }
        // Geometry/UI scratch has returned by this point. Include the cost
        // in total frame time; the panel attributes it to the remaining work.
        memory::service_request();
        sample.frame_ms = (clock() - frame_started) * 1000.0;
        stats::record(sample);
        hud::render_ms = sample.render_ms;
        hud::frame_ms += ((sample.frame_ms as f32) - hud::frame_ms) * 0.08;
        hud::fps = 1000.0 / max(0.1, hud::frame_ms);
        if sim::objective_done && !completed_sound {
            sound::success();
            completed_sound = true;
        }
        if gfx::key_pressed("F12") {
            gfx::screenshot(screenshot_path);
            sim::say("Screenshot saved to artifacts/frontier.png.");
        }
        if benchmark && drawn > 10 && frame_times.len < 16384 {
            frame_times.push(sample.frame_ms);
            sim_times.push(sample.simulation_ms);
            draw_times.push(sample.render_ms);
            mesh_times.push(sample.mesh_ms);
            ui_times.push(sample.ui_ms);
            gpu_wait_times.push(sample.gpu_wait_ms);
        }
        drawn++;
        render_frames = drawn;
        if playtest {
            driver::tick(eye, camera_target);
        }
        if flight_test {
            pilot::update();
        }
        if driver::complete || pilot::complete || quit || (frame_limit > 0 && drawn >= frame_limit) {
            break;
        }
    }
    return drawn;
}

fn main() {
    let options = parse_options();
    if options.help {
        return;
    }
    if !options.custom_save {
        default_save();
    }
    make_dir("artifacts");
    sim::init(seed);
    if options.stress > 0 || options.headless {
        run_stress(options.stress);
        sim::shutdown();
        return;
    }
    let opened = if offscreen {
        gfx::open_headless(1920, 1080)
    } else {
        gfx::open("Project Frontier — a Goose expedition", 1280, 800, gfx::WINDOW_RESIZABLE)
    };
    guard opened else {
        write_stderr(gfx::error());
        sim::shutdown();
        exit(1);
    }
    scene::init();
    hud::init();
    dev::init();
    horizon::init();
    stats::reset_history();
    dev::settings.detail_radius = radius;
    dev::settings.shadows = shadows;
    if !options.mute {
        sound::init();
    }
    if options.resume {
        load_game();
    }
    if demo {
        demo_colony();
    }
    if !options.resume && !playtest {
        sim::day = 0.375;
    }
    if colony_demo {
        dev::settings.load = initial_load;
        showcase::set_load(initial_load);
        sim::say("A live industrial district. F1 opens the engine inspector and load controls.");
    }
    if start_position {
        sim::player = position(start_x, start_z);
    }
    if start_day >= 0.0 {
        sim::day = start_day;
    }
    if victory {
        sim::build(8, position(-8.0, -4.0));
        for n in 920 {
            sim::tick(0.05);
        }
    }
    if hero {
        pitch = 0.20;
        distance = 18.0;
        yaw = 0.873;
    }
    if hero && victory {
        pitch = 0.06;
        distance = 30.0;
    }
    if playtest {
        yaw = 0.65;
        pitch = 0.56;
        distance = 9.0;
        radius = 3;
        dev::settings.detail_radius = radius;
        dev::open = false;
        dev::mode = 0;
    }
    if start_flight && !playtest {
        reframe_flight();
    }
    let diameter = radius * 2 + 1;
    let preload_batches = (diameter * diameter + world::MAX_JOBS - 1) / world::MAX_JOBS + 2;
    for n in preload_batches {
        let focus = streaming_focus();
        world::stream(focus.x, focus.z, radius, 8);
        world::drain();
    }
    if !flight::enabled {
        camera_target = sim::player + float3 { 0.0, 1.2, 0.0 };
        eye = camera_target + float3 {
            sin(yaw) * cos(pitch) * distance,
            sin(pitch) * distance,
            cos(yaw) * cos(pitch) * distance,
        };
    }
    scene::vegetation_center = eye;
    scene::sync(world::MAX_CHUNKS);
    scene::detached_view = flight::enabled;
    scene::view_center = streaming_focus();
    if flight::enabled {
        render::horizon_edge = flight::horizon_distance(world::height(eye.x, eye.z));
    }
    horizon::update(streaming_focus(), radius * 32.0, render::horizon_edge, 1);
    horizon::drain();
    dev::settings.day_phase = sim::day;
    let drawn = run_frames();
    if automated {
        gfx::screenshot(screenshot_path);
    }
    if benchmark {
        report();
    }
    print(
        "FRONTIER rendered ", drawn, " frames; ",
        ecs::alive_count, " entities; ",
        world::loaded, " chunks; triangles=", render::triangles,
        " screenshot=", if automated { screenshot_path } else { "F12" },
    );
    dev::shutdown();
    hud::shutdown();
    horizon::shutdown();
    scene::shutdown();
    sound::shutdown();
    gfx::close();
    sim::shutdown();
}
