// Bounded UI memory regression probe: stdlib graphics/UI, no game state.
import std;
import os;
import gfx;
import ui;
let FONT = embed_file("../assets/Roboto-Regular.ttf");

fn draw_ui(c: ui::Context, mono: ui::Context, frame: i64, scale: f32) {
    assert(ui::set_scale(c, scale));
    assert(ui::set_scale(mono, scale));
    ui::input_from_gfx(c);
    ui::input_from_gfx(mono);
    let bounds = ui::rect(0.0, 0.0, 800.0, 600.0);
    if ui::begin(c, "Memory probe", bounds, ui::WINDOW_NO_INPUT | ui::WINDOW_NO_SCROLLBAR) {
        for i in 30 {
            let y = (i % 15) * 30.0;
            ui::fill_rect(c, ui::rect(10.0, y, 200.0, 25.0), 5.0, ui::Color { 27, 35, 64, 223 });
            ui::draw_text(
                c,
                ui::rect(15.0, y, 190.0, 25.0),
                str("Project Frontier frame ", frame, " row ", i),
                ui::font(c),
                ui::Color { 0, 0, 0, 0 },
                ui::Color { 242, 234, 216, 255 }
            );
        }
    }
    ui::end(c);
    ui::render(c);
}

fn exact_buffers(c: ui::Context) {
    let v = ui::vertices(c);
    let indices = ui::indices(c);
    let vb = bytes_of(v);
    let ib = bytes_of(indices);
    if gfx::buffer_size(ui::renderer.vertex_buffer) != vb.len {
        gfx::release(ui::renderer.vertex_buffer);
        ui::renderer.vertex_buffer = gfx::vertex_buffer(vb);
        ui::renderer.vertex_capacity = vb.len;
    }
    if gfx::buffer_size(ui::renderer.index_buffer) != ib.len {
        gfx::release(ui::renderer.index_buffer);
        ui::renderer.index_buffer = gfx::index_buffer(ib);
        ui::renderer.index_capacity = ib.len;
    }
}

fn main() {
    var count: i64 = 1000;
    let argv = args();
    if argv.len > 1 {
        let n, ok = parse_int(argv[1]);
        if ok {
            count = n;
        }
    }
    let recreate = argv.len > 2 && argv[2] == "recreate";
    let recreate_vertex = argv.len > 2 && argv[2] == "recreate-vertex";
    let recreate_index = argv.len > 2
        && (argv[2] == "recreate-index" || argv[2] == "recreate-index-pipelined");
    let pipelined = argv.len > 2 && argv[2] == "recreate-index-pipelined";
    let exact = argv.len > 2 && argv[2] == "exact";
    let sentinel = argv.len > 2 && argv[2] == "sentinel";
    assert(gfx::open_headless(1920, 1080, gfx::NO_VSYNC));
    let context = ui::create_from_memory(FONT, 16.0);
    let mono = ui::create(13.0);
    for frame in count {
        assert(gfx::frame());
        gfx::begin_screen(float4 { 0.1, 0.2, 0.3, 1.0 });
        gfx::end_pass();
        draw_ui(context, mono, frame, 1.35);
        if !pipelined {
            gfx::flush();
        }
        if exact {
            exact_buffers(context);
        }
        if sentinel {
            let b = gfx::buffer(gfx::BUFFER_VERTEX, 16, "");
            gfx::release(b);
        }
        if recreate || recreate_vertex {
            gfx::release(ui::renderer.vertex_buffer);
            ui::renderer.vertex_buffer = gfx::Buffer { 0 };
            ui::renderer.vertex_capacity = 0;
        }
        if recreate || recreate_index {
            gfx::release(ui::renderer.index_buffer);
            ui::renderer.index_buffer = gfx::Buffer { 0 };
            ui::renderer.index_capacity = 0;
        }
        if pipelined {
            sleep_ms(1);
        }
        if frame % 250 == 0 {
            print(
                "UI_PROBE frame=", frame, " textures=", ui::renderer_textures.len,
                " vb=", ui::renderer.vertex_capacity, " ib=", ui::renderer.index_capacity
            );
        }
    }
    ui::destroy(context);
    ui::destroy(mono);
    gfx::close();
    print("UI_PROBE PASS frames=", count);
}
