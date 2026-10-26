namespace hud;
import std;
import vec;
import math;
import gfx;
import ui;
import .entities;
import .world;
import .sim;
import .render;
import .free_flight;

let ROBOTO: const u8[:] = embed_file("../assets/Roboto-Regular.ttf");
let NAMES: const u8[:][9] = [
    "Drill", "Smelter", "Solar", "Relay", "Assembler", "Robot", "Depot", "Beacon", "Tool"
];
let KINDS: i64[9] = [2, 3, 4, 5, 6, 7, 9, 8, 0];
let RESOURCES: const u8[:][5] = ["Ferrite", "Glacite", "Alloy", "Circuits", "Regolith"];
var context: ui::Context;
var mono: ui::Context;
var scale: f32 = 1.0;
var width: f32 = 1280.0;
var height: f32 = 800.0;
var build_menu = false;
var help = false;
var paused = false;
var debug = false;
var developer_mode: i64 = 0;
var developer_requested = false;
var flight_requested = false;
var chosen: i64 = 0;
var clicked_kind: i64 = -1;
var request_save = false;
var request_load = false;
var request_quit = false;
var mouse_over = false;
var fps: f32 = 60.0;
var frame_ms: f32 = 16.7;
var render_ms: f64 = 0.0;
var mesh_ms: f64 = 0.0;
var quality: i64 = 3;
let INK = ui::Color { 27, 35, 64, 223 };
let IVORY = ui::Color { 242, 234, 216, 255 };
let MUTED = ui::Color { 169, 176, 200, 255 };
let ORANGE = ui::Color { 255, 122, 47, 255 };
let CYAN = ui::Color { 95, 242, 224, 255 };
let RED = ui::Color { 255, 77, 94, 255 };
let CLEAR = ui::Color { 0, 0, 0, 0 };

fn init() {
    context = ui::create_from_memory(ROBOTO, 16.0);
    mono = ui::create(13.0);
    assert(context.id != 0 && mono.id != 0);
    var style = ui::style(context);
    style.window.fixed_background = ui::style_item_hide();
    style.window.padding = float2_0;
    ui::set_style(context, style);
    var ms = ui::style(mono);
    ms.window.fixed_background = ui::style_item_hide();
    ms.window.padding = float2_0;
    ui::set_style(mono, ms);
}

fn rect(x: f32, y: f32, w: f32, h: f32) -> ui::Rect {
    ui::rect(x, y, w, h)
}

fn text(x: f32, y: f32, w: f32, t: const u8[:], color: ui::Color) {
    ui::draw_text(context, rect(x, y, w, 22.0), t, ui::font(context), CLEAR, color);
}

fn wrap(t: const u8[:], w: f32) -> u8[][>..] {
    var out: u8[][>..] = [];
    var line: u8[>..<] = [];
    each_split(t, ' ') { word =>
        let candidate = str(line, if line.len > 0 { " " } else { "" }, word);
        if line.len > 0 && ui::text_width(ui::font(context), candidate) > w {
            out.push(copy(line));
            line.clear();
        }
        if line.len > 0 {
            line.push(' ');
        }
        line.append(word);
    };
    if line.len > 0 {
        out.push(copy(line));
    }
    out
}

fn hint(x: f32, y: f32, key: const u8[:], label: const u8[:]) {
    let kw: f32 = if key.len > 4 { 50.0 } else if key.len > 2 { 38.0 } else { 22.0 };
    ui::fill_rect(context, rect(x, y, kw, 22.0), 3.0, ui::Color { 242, 234, 216, 238 });
    text(x + 4.0, y, kw, key, ui::Color { 27, 35, 64, 255 });
    text(x + kw + 6.0, y, 140.0, label, IVORY);
}

fn panel(x: f32, y: f32, w: f32, h: f32) {
    ui::fill_rect(context, rect(x, y, w, h), 6.0, INK);
    ui::stroke_rect(context, rect(x, y, w, h), 6.0, 1.0, ui::Color { 58, 70, 112, 220 });
}

fn inside(x: f32, y: f32, w: f32, h: f32) -> bool {
    let p = gfx::mouse_pos();
    p.x / scale >= x && p.x / scale <= x + w && p.y / scale >= y && p.y / scale <= y + h
}

fn button(x: f32, y: f32, w: f32, h: f32, label: const u8[:]) -> bool {
    let hover = inside(x, y, w, h);
    let fill = if hover { ui::Color { 67, 78, 119, 255 } } else { ui::Color { 43, 58, 102, 255 } };
    ui::fill_rect(context, rect(x, y, w, h), 4.0, fill);
    text(x + 12.0, y + (h - 22.0) / 2.0, w - 16.0, label, IVORY);
    if hover {
        mouse_over = true;
    }
    hover && gfx::mouse_pressed(gfx::MOUSE_LEFT)
}

fn bar(x: f32, y: f32, w: f32, value: f32, color: ui::Color) {
    ui::fill_rect(context, rect(x, y, w, 5.0), 2.0, ui::Color { 43, 58, 102, 255 });
    ui::fill_rect(context, rect(x, y, w * clamp(value, 0.0, 1.0), 5.0), 2.0, color);
}

fn diamond(x: f32, y: f32, r: f32, color: ui::Color) {
    ui::fill_triangle(context, x, (y - r), (x + r), y, x, (y + r), color);
    ui::fill_triangle(context, x, (y - r), x, (y + r), (x - r), y, color);
}

fn resource_color(i: i64) -> ui::Color {
    if i == 0 {
        return ui::Color { 210, 60, 90, 255 };
    }
    if i == 1 {
        return ui::Color { 143, 211, 255, 255 };
    }
    if i == 2 {
        return ui::Color { 211, 200, 176, 255 };
    }
    if i == 3 {
        return CYAN;
    }
    ui::Color { 164, 126, 96, 255 }
}

fn icon(x: f32, y: f32, k: i64, color: ui::Color) {
    ui::fill_circle(context, rect(x - 19.0, y - 19.0, 38.0, 38.0), ui::Color { 43, 58, 102, 255 });
    if k == 0 {
        diamond(x, y, 10.0, color);
        return;
    }
    if k == 4 {
        ui::fill_rect(context, rect(x - 14.0, y - 11.0, 28.0, 18.0), 2.0, color);
        ui::stroke_line(context, (x - 9.0), (y - 9.0), (x - 9.0), (y + 4.0), 1.0, INK);
        ui::stroke_line(context, (x + 1.0), (y - 9.0), (x + 1.0), (y + 4.0), 1.0, INK);
        ui::stroke_line(context, x, (y + 8.0), x, (y + 16.0), 3.0, color);
    } else if k == 7 {
        ui::fill_circle(context, rect(x - 13.0, y - 10.0, 26.0, 20.0), color);
        ui::fill_rect(context, rect(x - 9.0, y - 2.0, 18.0, 5.0), 2.0, INK);
        diamond(x, y, 2.0, CYAN);
    } else if k == 8 || k == 5 {
        ui::stroke_line(context, x, (y + 15.0), x, (y - 15.0), 5.0, color);
        diamond(x, y - 13.0, 6.0, ORANGE);
    } else {
        ui::fill_rect(context, rect(x - 12.0, y - 7.0, 24.0, 19.0), 4.0, color);
        if k == 2 {
            ui::stroke_line(context, x, (y - 16.0), x, (y + 5.0), 4.0, ORANGE);
        }
        if k == 3 {
            ui::fill_rect(context, rect(x + 6.0, y - 16.0, 5.0, 14.0), 1.0, color);
        }
        if k == 6 {
            diamond(x, y - 3.0, 7.0, INK);
        }
    }
}

fn machine_name(kind: i64) -> const u8[:] {
    if kind == 1 {
        return "Landing capsule";
    }
    if kind == 20 {
        return "Ferrite deposit";
    }
    if kind == 21 {
        return "Glacite deposit";
    }
    for i in 9 {
        if KINDS[i] == kind {
            return NAMES[i];
        }
    }
    "Object"
}

fn begin_frame() {
    let size = gfx::screen_size();
    scale = min(size.x / 1280.0, size.y / 800.0);
    width = size.x / scale;
    height = size.y / scale;
    ui::set_scale(context, scale);
    ui::set_scale(mono, scale);
    ui::input_from_gfx(context);
    ui::input_from_gfx(mono);
    clicked_kind = -1;
    request_save = false;
    request_load = false;
    request_quit = false;
    mouse_over = false;
    developer_requested = false;
    flight_requested = false;
}

fn draw_objective() {
    panel(16.0, 16.0, 330.0, 100.0);
    text(30.0, 26.0, 300.0, "PROJECT FRONTIER / DISTRESS SIGNAL", ORANGE);
    var progress: f32 = 0.0;
    var towers: i64 = 0;
    for e in ecs::entities {
        if e.alive && e.kind == 8 {
            progress = max(progress, e.progress);
            towers++;
        }
    }
    let objective = if sim::objective_done {
        "Signal received. Colony established."
    } else if towers > 0 {
        "Keep the beacon powered to transmit."
    } else {
        "Build and power a planetary beacon."
    };
    text(30.0, 53.0, 300.0, objective, IVORY);
    let fill = if towers > 0 { progress } else { min(0.9, (sim::bag[3] as f32) / 8.0) };
    bar(30.0, 86.0, 300.0, fill, if sim::objective_done { CYAN } else { ORANGE });
}

fn draw_clock_and_power() {
    let right = if developer_mode == 1 { width - 466.0 } else { width };
    panel(right - 256.0, 16.0, 240.0, 78.0);
    let cycle = ((sim::day * 24.0 + 6.0) % 24.0) as! i64;
    let clock_text = str(
        "SOL 01   ", cycle, ":",
        if (sim::day * 1440.0) as! i64 % 60 < 10 { "0" } else { "" },
        (sim::day * 1440.0) as! i64 % 60
    );
    text(right - 242.0, 25.0, 220.0, clock_text, MUTED);
    let power_text = str("POWER  ", sim::supply as! i64, " / ", sim::demand as! i64, " kW");
    text(right - 242.0, 48.0, 220.0, power_text, if sim::demand > sim::supply { RED } else { CYAN });
    bar(right - 242.0, 77.0, 212.0, sim::supply / max(1.0, sim::demand), CYAN);
}

fn draw_cargo() {
    panel(16.0, height - 182.0, 224.0, 166.0);
    text(30.0, height - 173.0, 200.0, "EXOSUIT CARGO", ORANGE);
    for r in 5 {
        let y = height - 145.0 + r * 24.0;
        diamond(37.0, y + 10.0, 6.0, resource_color(r));
        text(53.0, y, 128.0, RESOURCES[r], MUTED);
        text(183.0, y, 52.0, str(sim::bag[r]), IVORY);
    }
}

fn draw_hotbar(hx: f32) {
    for i in 9 {
        let x = hx + i * 62.0;
        let y = height - 72.0 - (if KINDS[i] == chosen { 4.0 } else { 0.0 });
        panel(x, y, 56.0, 56.0);
        if KINDS[i] == chosen {
            ui::stroke_rect(context, rect(x, y, 56.0, 56.0), 5.0, 2.0, ORANGE);
        }
        text(x + 4.0, y + 1.0, 18.0, str(i + 1), MUTED);
        let usable = KINDS[i] == 0 || sim::can_build(KINDS[i]);
        icon(x + 29.0, y + 31.0, KINDS[i], if usable { IVORY } else { ui::Color { 94, 103, 136, 255 } });
        if inside(x, y, 56.0, 56.0) {
            mouse_over = true;
            if gfx::mouse_pressed(gfx::MOUSE_LEFT) {
                clicked_kind = KINDS[i];
            }
        }
    }
}

fn draw_hints(hx: f32) {
    panel(hx - 12.0, height - 112.0, 576.0, 32.0);
    if chosen == 0 {
        hint(hx, height - 107.0, "B", "Build");
        hint(hx + 95.0, height - 107.0, "Q", "Route");
        hint(hx + 190.0, height - 107.0, "C/V", "Craft");
        hint(hx + 325.0, height - 107.0, "Tab", "Field guide");
    } else {
        let tool_hints = "Left click  Place     Esc / 9  Tool     Right drag  Orbit";
        text(hx, height - 107.0, 552.0, tool_hints, IVORY);
    }
}

fn draw_flight_controls(hx: f32) {
    panel(hx, height - 128.0, 552.0, 112.0);
    let altitude = max(0.0, flight::eye.y - world::height(flight::eye.x, flight::eye.z));
    text(hx + 12.0, height - 122.0, 530.0,
        str("SURVEY FLIGHT   ", altitude as! i64, " m above ground   /   ", flight::speed as! i64, " m/s"), CYAN);
    hint(hx + 12.0, height - 90.0, "WASD", "Move");
    hint(hx + 190.0, height - 90.0, "Q/E", "Altitude");
    hint(hx + 370.0, height - 90.0, "Shift", "Boost ×4");
    hint(hx + 12.0, height - 58.0, "RMB", "Look");
    hint(hx + 190.0, height - 58.0, "Wheel", "Speed");
    hint(hx + 370.0, height - 58.0, "Home", "Overview");
}

fn draw_construction_cost() {
    panel((width - 420.0) / 2.0, height - 168.0, 420.0, 58.0);
    let title = str("CONSTRUCT / ", machine_name(chosen));
    text((width - 392.0) / 2.0, height - 163.0, 390.0, title, ORANGE);
    var costs: u8[>..] = [];
    for r in 5 {
        let n = sim::cost(chosen, r);
        if n > 0 {
            format(costs, RESOURCES[r], " ", n, "   ");
        }
    }
    let cost_color = if sim::can_build(chosen) { IVORY } else { RED };
    text((width - 392.0) / 2.0, height - 140.0, 390.0, costs, cost_color);
}

fn draw_inspector(selected: ecs::Handle, cx: f32, cy: f32) {
    let e .= ecs::entities[selected.slot];
    panel(cx + 18.0, cy + 12.0, 286.0, if e.kind >= 20 { 76.0 } else { 116.0 });
    text(cx + 30.0, cy + 18.0, 260.0, machine_name(e.kind), ORANGE);
    if e.kind >= 20 {
        text(cx + 30.0, cy + 43.0, 260.0, "Hold left click to mine", IVORY);
        text(cx + 30.0, cy + 64.0, 260.0, str(e.cargo_count, " units remaining"), MUTED);
    } else {
        let status = if e.powered { "Powered / ready" } else { "No power / add solar or relay" };
        text(cx + 30.0, cy + 43.0, 260.0, status, if e.powered { CYAN } else { RED });
        text(cx + 30.0, cy + 65.0, 260.0, "E Collect   F Deposit   Q Route", IVORY);
        var stock: u8[>..] = [];
        for item in e.inventory {
            if item.kind >= 0 && item.kind < 5 {
                format(stock, RESOURCES[item.kind], ":", item.count, " ");
            }
        }
        text(cx + 30.0, cy + 87.0, 260.0, stock, MUTED);
    }
}

fn draw_message() {
    let right = if developer_mode == 1 { width - 466.0 } else { width };
    let rows = wrap(sim::message, 292.0);
    let h: f32 = rows.len * 22.0 + 22.0;
    panel(right - 336.0, 110.0, 320.0, h);
    ui::fill_rect(context, rect(right - 336.0, 116.0, 3.0, h - 12.0), 1.0, ORANGE);
    var row: i64 = 0;
    for line in rows {
        text(right - 322.0, 121.0 + row * 22.0, 292.0, line, IVORY);
        row++;
    }
}

fn draw_field_guide() {
    let x = (width - 620.0) / 2.0;
    let y = (height - 472.0) / 2.0;
    panel(x, y, 620.0, 472.0);
    mouse_over = true;
    let title = if paused { "EXPEDITION PAUSED" } else { "FRONTIER / FIELD GUIDE" };
    text(x + 24.0, y + 18.0, 575.0, title, ORANGE);
    let lines: const u8[:][12] = [
        "Explore  >  Mine  >  Build  >  Automate  >  Transmit",
        "WASD walk. Shift sprint. Space jump. Right drag / arrows orbit.",
        "Mouse wheel zooms. Click red Ferrite or blue Glacite to mine.",
        "Click ground to dig. Hold Left Shift while digging to fill.",
        "C refines 2 Ferrite into Alloy. V crafts Alloy + Glacite into Circuits.",
        "B opens construction. 1-8 select a machine. 9 returns to mining.",
        "Place a Drill within 5 m of ore. Add a Smelter and Solar nearby.",
        "Q on source, Q on destination builds a visible resource conveyor.",
        "Robots carry output automatically. E collects it. F deposits cargo.",
        "Assembler makes Circuits. Beacon costs 20 Alloy, 10 Glacite, 8 Circuits.",
        "Connect sufficient power and charge the beacon to finish the mission.",
        "F5 save. F9 load. F1 developer. G survey flight. Tab closes guide."
    ];
    for i in 12 {
        text(x + 24.0, y + 56.0 + i * 26.0, 580.0, lines[i], if i == 0 { CYAN } else { IVORY });
    }
    if button(x + 24.0, y + 402.0, 132.0, 44.0, "Resume") {
        paused = false;
        help = false;
    }
    if button(x + 170.0, y + 402.0, 132.0, 44.0, "Save F5") {
        request_save = true;
    }
    if button(x + 316.0, y + 402.0, 132.0, 44.0, "Load F9") {
        request_load = true;
    }
    if button(x + 462.0, y + 402.0, 132.0, 44.0, "Save & exit") {
        request_save = true;
        request_quit = true;
    }
}

fn draw_build_menu() {
    let x = (width - 760.0) / 2.0;
    let y = (height - 438.0) / 2.0;
    panel(x, y, 760.0, 438.0);
    mouse_over = true;
    text(x + 24.0, y + 14.0, 700.0, "COLONY CONSTRUCTION / select a blueprint", ORANGE);
    for i in 8 {
        let bx = x + 20.0 + (i % 4) * 183.0;
        let by = y + 54.0 + (i / 4) * 174.0;
        let k = KINDS[i];
        let affordable = sim::can_build(k);
        panel(bx, by, 170.0, 158.0);
        icon(bx + 85.0, by + 34.0, k, if affordable { IVORY } else { MUTED });
        text(bx + 12.0, by + 60.0, 155.0, str(i + 1, "  ", NAMES[i]), IVORY);
        var row: i64 = 0;
        for r in 5 {
            let n = sim::cost(k, r);
            if n > 0 {
                diamond(bx + 17.0, by + 94.0 + row * 20.0, 4.0, resource_color(r));
                let color = if sim::bag[r] >= n { MUTED } else { RED };
                text(bx + 29.0, by + 83.0 + row * 20.0, 135.0, str(n, " ", RESOURCES[r]), color);
                row++;
            }
        }
        if inside(bx, by, 170.0, 158.0) {
            ui::stroke_rect(context, rect(bx, by, 170.0, 158.0), 5.0, 2.0, ORANGE);
            if gfx::mouse_pressed(gfx::MOUSE_LEFT) {
                clicked_kind = k;
                build_menu = false;
            }
        }
    }
    text(
        x + 24.0, y + 409.0, 710.0,
        "B closes     Power links automatically within 14 m     Conveyors: Q then Q", MUTED
    );
}

fn draw_completion() {
    panel((width - 520.0) / 2.0, height - 194.0, 520.0, 68.0);
    text(
        (width - 478.0) / 2.0, height - 185.0, 480.0,
        "TRANSMISSION COMPLETE / YOU ARE NOT ALONE", CYAN
    );
    text(
        (width - 478.0) / 2.0, height - 158.0, 480.0,
        "Mission complete. Keep exploring and expanding your colony.", IVORY
    );
}

fn draw_location() {
    if developer_mode == 1 {
        return;
    }
    panel(width - 244.0, height - 52.0, 228.0, 36.0);
    let position = if flight::enabled { flight::eye } else { sim::player };
    let biome = world::biome(position.x, position.z);
    let biome_name = if biome == 0 { "Meadow" } else if biome == 1 { "Mesas" } else { "Fungal" };
    let location = str(if flight::enabled { "CAM " } else { "XZ " },
        position.x as! i64, " / ", position.z as! i64, "   ", biome_name);
    text(width - 230.0, height - 46.0, 215.0, location, MUTED);
}

fn draw_diagnostics() {
    let bounds = rect(16.0, 132.0, 380.0, 244.0);
    if ui::begin(mono, "Frontier diagnostics", bounds, ui::WINDOW_NO_INPUT | ui::WINDOW_NO_SCROLLBAR) {
        ui::fill_rect(mono, rect(16.0, 132.0, 380.0, 244.0), 4.0, INK);
        var info: u8[>..] = [];
        format(
            info,
            "FRONTIER / GOOSE v2026.3\n",
            fps as! i64, " FPS  ", frame_ms, " ms\n",
            ecs::alive_count, " active / ", ecs::entities.len, " entity slots\n",
            world::loaded, " loaded / ", world::chunks.len, " chunk slots\n",
            "simulation ", sim::simulation_ms, " ms\n",
            "meshes ", mesh_ms, " ms | render ", render_ms, " ms\n",
            world::pending, " terrain jobs / ", world::max_pending, " peak\n",
            render::triangles, " triangles / ", render::draw_calls, " draws\n",
            "GPU upload ", render::upload_ms, " ms\n",
            "pool cells: ", ecs::inventories.len, " / ", ecs::queues.len, " / ", ecs::edges.len, "\n",
            "F2 +1000   F3 -1000   F4 stream\n",
            "F6 robot   F7 network   F8 time   O shadows\n",
            "radius ", quality, "   +/- quality   F5/F9 save/load"
        );
        var row: i64 = 0;
        each_split(info, '\n') { line =>
            let line_rect = rect(28.0, 142.0 + row * 17.0, 360.0, 17.0);
            ui::draw_text(mono, line_rect, line, ui::font(mono), CLEAR, CYAN);
            row++;
        };
    }
    ui::end(mono);
}

fn draw(selected: ecs::Handle, link_source: ecs::Handle, ground: float3) {
    let bounds = rect(0.0, 0.0, width, height);
    if ui::begin(context, "Frontier HUD", bounds, ui::WINDOW_NO_INPUT | ui::WINDOW_NO_SCROLLBAR) {
        draw_objective();
        draw_clock_and_power();
        draw_cargo();
        let hx = if developer_mode == 1 { max(248.0, (width - 1018.0) / 2.0) } else { (width - 552.0) / 2.0 };
        if flight::enabled {
            draw_flight_controls(hx);
        } else {
            draw_hotbar(hx);
            draw_hints(hx);
        }
        if chosen != 0 {
            draw_construction_cost();
        }
        let p = gfx::mouse_pos();
        let cx = p.x / scale;
        let cy = p.y / scale;
        let cursor_color = if ecs::valid(selected) { ORANGE } else { IVORY };
        ui::stroke_circle(context, rect(cx - 6.0, cy - 6.0, 12.0, 12.0), 1.0, cursor_color);
        if ecs::valid(selected) && !build_menu && !paused && !flight::enabled
            && (developer_mode != 1 || cx < width - 480.0)
        {
            draw_inspector(selected, cx, cy);
        }
        if ecs::valid(link_source) {
            panel((width - 460.0) / 2.0, 132.0, 460.0, 42.0);
            text((width - 432.0) / 2.0, 141.0, 435.0, "ROUTE: point at a destination and press Q", CYAN);
        }
        if sim::message_time > 0.0 {
            draw_message();
        }
        if help || paused {
            draw_field_guide();
        }
        if build_menu {
            draw_build_menu();
        }
        if sim::objective_done {
            draw_completion();
        }
        draw_location();
        if developer_mode == 0 {
            if button(width - 128.0, height - 88.0, 112.0, 28.0, "F1 Developer") {
                developer_requested = true;
            }
            if button(width - 128.0, height - 122.0, 112.0, 28.0,
                if flight::enabled { "G Return" } else { "G Free flight" })
            {
                flight_requested = true;
            }
        }
    }
    ui::end(context);
    if debug {
        draw_diagnostics();
    }
}

fn present() {
    ui::render(context);
    if debug {
        ui::render(mono);
    }
    // Goose v2026.3 / SDL 3.4.16 Metal retains upload resources in a static
    // UI scene unless GPU buffer retirement is exercised. Retiring the small
    // index buffer after both contexts bounds memory in measured pipelined
    // and GPU-complete runs. SDL defers destruction until pending draws finish.
    // See GOOSE_EVALUATION.md and tests/ui_memory_probe.goose for the reproducer.
    if ui::renderer.index_buffer.id != 0 {
        gfx::release(ui::renderer.index_buffer);
        ui::renderer.index_buffer = gfx::Buffer { 0 };
        ui::renderer.index_capacity = 0;
    }
}

fn shutdown() {
    ui::destroy(context);
    ui::destroy(mono);
}
