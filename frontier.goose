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

var yaw: f32 = 0.65;
var pitch: f32 = 0.56;
var distance: f32 = 9.0;
var eye = float3 { 10.0, 16.0, 15.0 };
var camera_target = float3 { 0.0, 3.0, 0.0 };
var velocity = float3_0;
var vertical: f32 = 0.0;
var facing: f32 = 0.0;
var selected: ecs::Handle;
var link_source: ecs::Handle;
var ground = float3_0;
var mine_cooldown: f32 = 0.0;
var radius: i64 = 3;
var shadows = true;
var frame_limit: i64 = -1;
var demo = false;
var benchmark = false;
var offscreen = false;
var playtest = false;
var victory = false;
var hero = false;
var automated = false;
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

fn squared(a: float3, b: float3) -> f32 {
    let d = a - b;
    dot(d, d)
}

fn position(x: f32, z: f32) -> float3 {
    float3 { x, world::height(x, z), z }
}

fn camera(dt: f32) {
    if gfx::mouse_down(gfx::MOUSE_RIGHT) && !hud::build_menu && !hud::help && !hud::paused {
        gfx::set_mouse_relative(true);
        let d = gfx::mouse_delta();
        yaw -= d.x * 0.003;
        pitch += d.y * 0.003;
    } else if gfx::mouse_relative() {
        gfx::set_mouse_relative(false);
    }
    if gfx::key_down("Left") {
        yaw += dt * 1.7;
    }
    if gfx::key_down("Right") {
        yaw -= dt * 1.7;
    }
    if gfx::key_down("Up") {
        pitch -= dt;
    }
    if gfx::key_down("Down") {
        pitch += dt;
    }
    distance = clamp(distance - gfx::mouse_wheel() * 1.5, 4.0, 28.0);
    pitch = clamp(pitch, if hero && victory { 0.06 } else { 0.17 }, 1.22);
    let build = hud::chosen != 0;
    let d = if hero && victory { 30.0 } else if build { max(16.0, distance) } else { distance };
    let p = if build { max(0.85, pitch) } else { pitch };
    let desired_target = sim::player + float3 { 0.0, 1.2, 0.0 };
    camera_target += (desired_target - camera_target) * ft::splat(1.0 - exp(-dt * 10.0));
    var desired = camera_target + float3 {
        sin(yaw) * cos(p) * d,
        sin(p) * d,
        cos(yaw) * cos(p) * d
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
        -cos(yaw) * forward - sin(yaw) * right
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
        forward + right * ft::splat(mx * factor * aspect) + up * ft::splat(my * factor)
    );
    var depth: f32 = 80.0;
    has_ground = false;
    for i in 200 {
        let t: f32 = i * 0.4;
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
        hud::debug = !hud::debug;
    }
    if gfx::key_pressed("Tab") {
        hud::help = !hud::help;
        hud::paused = false;
    }
    if gfx::key_pressed("B") {
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
        if gfx::key_pressed(keys[i]) {
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
    }
    if gfx::key_pressed("=") {
        radius = min(4, radius + 1);
    }
    if gfx::key_pressed("-") {
        radius = max(2, radius - 1);
    }
    if gfx::key_pressed("F2") {
        sim::stress_spawn(1000);
    }
    if gfx::key_pressed("F3") {
        sim::stress_destroy(1000);
    }
    if gfx::key_pressed("F4") {
        rapid_stream = !rapid_stream;
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
    if hud::paused || hud::help || hud::build_menu || hud::mouse_over {
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
        ",\n  \"entity_slots\": ", ecs::entities.len,
        ",\n  \"active_entities\": ", ecs::alive_count,
        ",\n  \"chunk_slots\": ", world::chunks.len,
        ",\n  \"generated_chunks\": ", world::generated,
        ",\n  \"generation_cpu_total_ms\": ", world::generation_total_ms,
        ",\n  \"queue_calls_total_ms\": ", world::transfer_ms,
        ",\n  \"quality_radius\": ", radius,
        ",\n  \"shadows\": ", shadows,
        "\n}\n"
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
        help: false, resume: false, mute: false, headless: false, stress: 0, custom_save: false
    };
    var i: i64 = 1;
    while i < argv.len {
        let a = argv[i];
        if a == "--help" || a == "-h" {
            print(
                "Project Frontier / Goose v2026.3\n",
                "Usage: ./run.sh [--resume] [--save PATH] [--seed N] [--quality low|medium|high]\n",
                "       ./run.sh --demo [--hero] [--victory] [--time 0..1]\n",
                "       ./run.sh --offscreen --frames N [--benchmark] [--screenshot PATH]\n",
                "       ./run.sh --stress N | --playtest\n",
                "WASD walk, Shift sprint, Space jump, right-drag orbit, wheel zoom.\n",
                "Hold left click mine/dig; Shift+click fills terrain. B builds; 1-8 blueprints, 9 tool.\n",
                "Q source then Q destination connects conveyors. E collect, F deposit, R reclaim.\n",
                "C refine Ferrite, V craft Circuits. F5 save, F9 load, Tab field guide, Esc pause.\n",
                "F1 diagnostics; F2/F3 +/-1000; F4 rapid stream; F6 robot; F7 networks; F8 time.\n",
                "F12 screenshot; +/- streaming quality; O shadows. --mute disables sound."
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
            hud::debug = true;
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
            radius = if q == "low" { 2 } else if q == "high" { 4 } else { 3 };
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
                " edges=", ecs::edges.len
            );
        }
    }
    print(
        "STRESS PASS rounds=", rounds,
        " elapsed_ms=", (clock() - start) * 1000.0,
        " entity_slots=", ecs::entities.len,
        " chunk_slots=", world::chunks.len,
        " generated=", world::generated
    );
}

// Runs frames until the window closes, the player quits or an automated run ends.
// Returns the number of rendered frames.
fn run_frames() -> i64 {
    var last = clock();
    var drawn: i64 = 0;
    while gfx::frame() {
        let now = clock();
        let frame_ms = (now - last) * 1000.0;
        last = now;
        let dt: f32 = if automated && !benchmark {
            1.0 / 60.0
        } else {
            clamp(gfx::delta_time() as f32, 0.001, 0.05)
        };
        hud::begin_frame();
        camera(dt);
        aim();
        hud::draw(selected, link_source, ground);
        if hud::clicked_kind >= 0 {
            hud::chosen = hud::clicked_kind;
        }
        controls(dt);
        if hud::request_quit {
            quit = true;
        }
        if rapid_stream {
            stream_timer += dt;
            if stream_timer > 1.0 {
                stream_timer = 0.0;
                sim::player.x += 128.0;
                sim::player.y = world::height(sim::player.x, sim::player.z);
            }
        }
        if !hud::paused && !hud::help {
            sim::tick(dt);
        }
        world::stream(sim::player.x, sim::player.z, radius, 2);
        let mesh_start = clock();
        scene::sync(2);
        hud::mesh_ms = (clock() - mesh_start) * 1000.0;
        render::stream_radius = radius * 32.0;
        hud::quality = radius;
        let draw_start = clock();
        // HUD commands are built before input is applied, then rendered after 3D.
        scene::draw(
            eye, camera_target, sim::day, sim::elapsed, selected, hud::chosen, ground,
            sim::can_build(hud::chosen), shadows
        );
        hud::present();
        hud::render_ms = (clock() - draw_start) * 1000.0;
        // A benchmark frame includes completed GPU work, rather than only
        // command submission throughput. Normal play keeps GPU pipelining.
        if benchmark {
            gfx::flush();
        }
        hud::frame_ms += ((frame_ms as f32) - hud::frame_ms) * 0.08;
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
            frame_times.push(frame_ms);
            sim_times.push(sim::simulation_ms);
            draw_times.push(hud::render_ms);
            mesh_times.push(hud::mesh_ms);
        }
        drawn++;
        render_frames = drawn;
        if playtest {
            driver::tick(eye, camera_target);
        }
        if driver::complete {
            break;
        }
        if quit || (frame_limit > 0 && drawn >= frame_limit) {
            break;
        }
    }
    drawn
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
    if !options.mute {
        sound::init();
    }
    if options.resume {
        load_game();
    }
    if demo {
        demo_colony();
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
    for n in 12 {
        world::stream(sim::player.x, sim::player.z, radius, 8);
        world::drain();
    }
    scene::sync(81);
    eye = sim::player + float3 { 18.0, 20.0, 24.0 };
    camera_target = sim::player + float3 { 0.0, 1.2, 0.0 };
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
        " screenshot=", if automated { screenshot_path } else { "F12" }
    );
    hud::shutdown();
    scene::shutdown();
    sound::shutdown();
    gfx::close();
    sim::shutdown();
}
