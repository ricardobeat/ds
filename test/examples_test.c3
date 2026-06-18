// examples_test.c3 — snapshot-style render tests for the DS example files.
// 
// We register stub implementations of the TUI host functions so the examples
// can be evaluated without a real terminal.  Each test loads a stripped version
// of the example (without the `run_model(...)` tail), calls the view function
// with a synthetic state, and checks that the rendered output contains expected
// strings.

module engine;
import std::io;
import std::io::file;
import std::core::string;
import std::core::dstring;

// ── Host-stub registration ───────────────────────────────────────

bool g_stubs_registered = false;

// Node constructors: return minimal records the renderer can walk.

fn EvalResult stub_text(Value[] args) {
    Value opts = args.len >= 1 && is_rec(args[0]) ? args[0] : val_rec(new_record());
    Record* r  = as_rec(opts);
    // find "value" field


    uint val_id = intern("value");
    for (int i = 0; i < r.keys.len; i++) {
        if (r.keys[i] == val_id) {
            return { .value = r.values[i] };
        }
    }
    return { .value = mk_str("") };
}

fn EvalResult stub_vstack(Value[] args) {
    // VStack(props, [children]) → join children with newline
    if (args.len < 2 || !is_arr(args[1])) {
        return { .value = mk_str("") };
    }
    Array* kids = as_arr(args[1]);
    DString d   = dstring::temp();
    for (int i = 0; i < kids.items.len; i++) {
        Value c = kids.items[i];
        if (is_str(c)) {
            if (d.len() > 0) d.append_char('\n');
            d.append_string(*as_str(c));
        }
    }
    return { .value = mk_str(d.str_view()) };
}

fn EvalResult stub_hstack(Value[] args) {
    if (args.len < 2 || !is_arr(args[1])) return { .value = mk_str("") };
    Array* kids = as_arr(args[1]);
    DString d   = dstring::temp();
    for (int i = 0; i < kids.items.len; i++) {
        Value c = kids.items[i];
        if (is_str(c)) d.append_string(*as_str(c));
    }
    return { .value = mk_str(d.str_view()) };
}

fn EvalResult stub_box(Value[] args) {
    // Box(props) or Box(props, [child0, child1, ...])
    if (args.len < 2 || !is_arr(args[1])) return { .value = mk_str("") };
    Array* kids = as_arr(args[1]);
    if (kids.items.len == 0) return { .value = mk_str("") };
    Value child = kids.items[0];
    if (is_str(child)) return { .value = child };
    return { .value = mk_str("") };
}

fn EvalResult stub_divider(Value[] args) {
    return {
        .value = mk_str(
            "────────────────────────────────────────"
        )
    };
}
fn EvalResult stub_status(Value[] args) {
    return { .value = mk_str("") };
}
fn EvalResult stub_textinput(Value[] args) {
    return { .value = mk_str("") };
}
fn EvalResult stub_list(Value[] args) {
    return { .value = mk_str("") };
}

fn EvalResult stub_run_model(Value[] args) {
    return { .value = mk_nil() };
}

fn EvalResult stub_progress_bar(Value[] args) {
    if (args.len < 1 || !is_rec(args[0])) return { .value = mk_str("[          ]") };
    Value pct_v = rec_get_field(args[0], "pct");
    int pct     = is_num(pct_v) ? (int)as_num(pct_v) : 0;
    DString d   = dstring::temp();
    d.append_char('[');
    int filled = (38 * pct + 50) / 100;
    for (int i = 0; i < filled; i++) d.append_string("█");
    for (int i = filled; i < 38; i++) d.append_string("░");
    d.append_char(']');
    return { .value = mk_str(d.str_view()) };
}

fn EvalResult stub_str_repeat(Value[] args) {
    if (args.len < 2) return { .value = mk_str("") };
    String s  = is_str(args[0]) ? *as_str(args[0]) : "";
    int n     = is_num(args[1]) ? (int)as_num(args[1]) : 0;
    DString d = dstring::temp();
    for (int i = 0; i < n; i++) d.append_string(s);
    return { .value = mk_str(d.str_view()) };
}

fn EvalResult stub_num_to_str(Value[] args) {
    if (args.len < 1 || !is_num(args[0])) return { .value = mk_str("0") };
    double d = as_num(args[0]);
    long i   = (long)d;
    if ((double)i == d) return { .value = mk_str(string::tformat("%d", (int)i)) };
    return { .value = mk_str(string::tformat("%g", d)) };
}

fn EvalResult stub_str_pad_left(Value[] args) {
    if (args.len < 2) return { .value = mk_str("") };
    String s    = is_str(args[0]) ? *as_str(args[0]) : "";
    int width   = is_num(args[1]) ? (int)as_num(args[1]) : 0;
    String pad  = args.len >= 3 && is_str(args[2]) ? *as_str(args[2]) : " ";
    DString d   = dstring::temp();
    int deficit = width - (int)s.len;
    for (int i = 0; i < deficit; i++) d.append_string(pad);
    d.append_string(s);
    return { .value = mk_str(d.str_view()) };
}

fn EvalResult stub_str_pad_right(Value[] args) {
    if (args.len < 2) return { .value = mk_str("") };
    String s   = is_str(args[0]) ? *as_str(args[0]) : "";
    int width  = is_num(args[1]) ? (int)as_num(args[1]) : 0;
    String pad = args.len >= 3 && is_str(args[2]) ? *as_str(args[2]) : " ";
    DString d  = dstring::temp();
    d.append_string(s);
    int deficit = width - (int)s.len;
    for (int i = 0; i < deficit; i++) d.append_string(pad);
    return { .value = mk_str(d.str_view()) };
}

fn EvalResult stub_not(Value[] args) {
    if (args.len < 1) return { .value = mk_bool(true) };
    return { .value = mk_bool(!as_bool(args[0])) };
}

fn EvalResult stub_floor(Value[] args) {
    if (args.len < 1 || !is_num(args[0])) return { .value = mk_num(0) };
    double d = as_num(args[0]);
    return { .value = mk_num((double)(long)d) };
}
fn EvalResult stub_ceil(Value[] args) {
    if (args.len < 1 || !is_num(args[0])) return { .value = mk_num(0) };
    double d = as_num(args[0]);
    long i   = (long)d;
    return { .value = mk_num((double)(d > (double)i ? i + 1 : i)) };
}
fn EvalResult stub_round(Value[] args) {
    if (args.len < 1 || !is_num(args[0])) return { .value = mk_num(0) };
    return { .value = mk_num((double)(long)(as_num(args[0]) + 0.5)) };
}
fn EvalResult stub_abs(Value[] args) {
    if (args.len < 1 || !is_num(args[0])) return { .value = mk_num(0) };
    double d = as_num(args[0]);
    return { .value = mk_num(d < 0 ? -d : d) };
}
fn EvalResult stub_max(Value[] args) {
    if (args.len < 2) return { .value = mk_num(0) };
    double a = is_num(args[0]) ? as_num(args[0]) : 0;
    double b = is_num(args[1]) ? as_num(args[1]) : 0;
    return { .value = mk_num(a > b ? a : b) };
}
fn EvalResult stub_min(Value[] args) {
    if (args.len < 2) return { .value = mk_num(0) };
    double a = is_num(args[0]) ? as_num(args[0]) : 0;
    double b = is_num(args[1]) ? as_num(args[1]) : 0;
    return { .value = mk_num(a < b ? a : b) };
}

fn EvalResult stub_string_width(Value[] args) {
    if (args.len < 1 || !is_str(args[0])) return { .value = mk_num(0) };
    return { .value = mk_num((double)(*as_str(args[0])).len) };
}

fn EvalResult stub_str_slice(Value[] args) {
    if (args.len < 3 || !is_str(args[0])) return { .value = mk_str("") };
    String s  = *as_str(args[0]);
    int start = (int)as_num(args[1]);
    int end   = (int)as_num(args[2]);
    if (start < 0) start = 0;
    if (end > (int)s.len) end = (int)s.len;
    if (end < start) end = start;
    return { .value = mk_str(s[(sz)start:(sz)(end - start)]) };
}

fn EvalResult stub_str_concat(Value[] args) {
    if (args.len < 2) return { .value = mk_str("") };
    String a  = is_str(args[0]) ? *as_str(args[0]) : "";
    String b  = is_str(args[1]) ? *as_str(args[1]) : "";
    DString d = dstring::temp();
    d.append_string(a);
    d.append_string(b);
    return { .value = mk_str(d.str_view()) };
}

fn EvalResult stub_join_v(Value[] args) {
    if (args.len < 2) return { .value = mk_str("") };
    String a = is_str(args[0]) ? *as_str(args[0]) : "";
    String b = is_str(args[1]) ? *as_str(args[1]) : "";
    return { .value = mk_str(string::tformat("%s\n%s", a, b)) };
}

fn EvalResult stub_join_h(Value[] args) {
    if (args.len < 2) return { .value = mk_str("") };
    String a = is_str(args[0]) ? *as_str(args[0]) : "";
    String b = is_str(args[1]) ? *as_str(args[1]) : "";
    return { .value = mk_str(string::tformat("%s%s", a, b)) };
}

fn EvalResult stub_style_render(Value[] args) {
    if (args.len < 2) return { .value = mk_str("") };
    return { .value = is_str(args[1]) ? args[1] : mk_str("") };
}

// Helper: get a field from a record value
fn Value rec_get_field(Value rec, String field) {
    if (!is_rec(rec)) return mk_nil();
    Record* r = as_rec(rec);
    uint want = intern(field);
    for (int i = 0; i < r.keys.len; i++) {
        if (r.keys[i] == want) return r.values[i];
    }
    return mk_nil();
}

fn void register_stubs() {
    if (g_stubs_registered) return;
    g_stubs_registered = true;

    register_host_fn("run_model", &stub_run_model);
    register_host_fn("run", &stub_run_model);

    register_host_fn("Text", &stub_text);
    register_host_fn("VStack", &stub_vstack);
    register_host_fn("HStack", &stub_hstack);
    register_host_fn("Box", &stub_box);
    register_host_fn("Divider", &stub_divider);
    register_host_fn("StatusBar", &stub_status);
    register_host_fn("TextInput", &stub_textinput);
    register_host_fn("List", &stub_list);

    register_host_fn("progress_bar", &stub_progress_bar);
    register_host_fn("str_repeat", &stub_str_repeat);
    register_host_fn("num_to_str", &stub_num_to_str);
    register_host_fn("str_pad_left", &stub_str_pad_left);
    register_host_fn("str_pad_right", &stub_str_pad_right);
    register_host_fn("string_width", &stub_string_width);
    register_host_fn("floor", &stub_floor);
    register_host_fn("ceil", &stub_ceil);
    register_host_fn("round", &stub_round);
    register_host_fn("abs", &stub_abs);
    register_host_fn("max", &stub_max);
    register_host_fn("min", &stub_min);
    register_host_fn("not", &stub_not);
    register_host_fn("str_slice", &stub_str_slice);
    register_host_fn("str_concat", &stub_str_concat);
    register_host_fn("join_vertical", &stub_join_v);
    register_host_fn("join_horizontal", &stub_join_h);
    register_host_fn("style_render", &stub_style_render);

    engine::engine_init();

    // Register built-in modules accessible via `from mod import { X }`.
    register_module("signals", engine_mk_record(
        { "get", "set", "signal", "derived", "effect" },
        { mk_prim("signal_get"), mk_prim("signal_set"), mk_prim("signal"),
          mk_prim("derived"), mk_prim("effect") }
    ));
    register_module("milktea", engine_mk_record(
        { "run", "run_model" },
        { mk_prim("run"), mk_prim("run_model") }
    ));
    register_module("keys", engine_mk_record(
        { "UP", "DOWN", "LEFT", "RIGHT", "ENTER", "BACKSPACE", "ESC", "RUNE", "CTRL_C", "DELETE" },
        {
            mk_num(65),
            mk_num(66),
            mk_num(68),
            mk_num(67),
            mk_num(10),
            mk_num(127),
            mk_num(27),
            mk_num(0),
            mk_num(3),
            mk_num(127),
        }
    ));
}

// Evaluate a DS source string, returning the result value.
fn Value eval_ds(String src) {
    register_stubs();
    g_element_slot = 0;
    g_element_slots = { };
    // Build env from builtins + all registered host functions
    Env* env = make_builtin_env();
    // Extend env with host functions registered by stubs


    int extra   = g_host_fn_count;
    int base    = (int)env.count;
    Binding* bp = mem::talloc_array(Binding, (sz)(base + extra));
    for (int i = 0; i < base; i++) bp[i] = env.data.bindings_ptr[i];
    for (int i = 0; i < extra; i++) {
        String name = g_host_fn_names[i];
        bp[base + i] = { .name_id = intern(name), .value = mk_prim(name) };
    }
    env.data.bindings_ptr = bp;
    env.count = (uint)(base + extra);
    ParseResult pr = parse_source(src);
    if (pr.error) {
        io::printfn("parse error: %s", pr.message);
        return mk_nil();
    }
    AstNode* kernel = desugar(pr.root, null);
    EvalResult r    = eval(kernel, env);
    if (r.thrown) {
        Value s = show(r.value);
        io::printfn("threw: %s", *as_str(s));
        return mk_nil();
    }
    return r.value;
}

// Load a DS file, strip the trailing run()/run_model() call, append extra suffix.
fn String load_example(String path, String suffix) {
    char[]? bytes = file::load_temp(path);
    if (catch err = bytes) {
        io::printfn("error loading %s", path);
        return suffix;
    }
    String src = (String)bytes;
    // Find last occurrence of "run(" or "run_model("


    sz last = src.len;
    for (sz i = src.len; i > 0; i--) {
        if (src[i - 1..].starts_with("run(") || src[i - 1..].starts_with("run_model(")) {
            last = i - 1;
            break;
        }
    }
    DString d = dstring::temp();
    d.append_string(src[:last]);
    d.append_string(suffix);
    return d.str_view();
}

// ── Tests ────────────────────────────────────────────────────────

fn void test_counter_view_renders_value() @test {
    String src   = load_example("examples/counter.ds", "\nview({ value: 42, width: 80, height: 24 })");
    Value result = eval_ds(src);
    // View returns a string containing "42"


    assert(is_str(result));
    assert((*as_str(result)).contains("42"));
}

fn void test_counter_init_state() @test {
    String src   = load_example("examples/counter.ds", "\nstate");
    Value result = eval_ds(src);
    assert(is_rec(result));
    Value v = rec_get_field(result, "value");
    assert(is_num(v) && as_num(v) == 0.0);
}

fn void test_spinner_frame_advances() @test {
    String src = load_example(
        "examples/spinner.ds",
        "\nlet s1 = update(state, { __tag: \"Tick\", __val: nil })\ns1.frame"
    );
    Value result = eval_ds(src);
    assert(is_num(result));
    assert(as_num(result) == 1.0);
}

fn void test_spinner_view_renders_frame() @test {
    String src   = load_example("examples/spinner.ds", "\nview({ frame: 0 })");
    Value result = eval_ds(src);
    assert(is_str(result));
    // Should contain Loading text
    assert((*as_str(result)).contains("Loading"));
}

fn void test_progress_init() @test {
    String src   = load_example("examples/progress.ds", "\nstate");
    Value result = eval_ds(src);
    assert(is_rec(result));
    Value pct = rec_get_field(result, "pct");
    assert(is_num(pct) && as_num(pct) == 0.0);
}

fn void test_progress_tick_advances() @test {
    String src = load_example(
        "examples/progress.ds",
        "\nlet s2 = update(state, { __tag: \"Tick\", __val: nil })\ns2.pct"
    );
    Value result = eval_ds(src);
    assert(is_num(result));
    assert(as_num(result) == 1.0);
}

fn void test_progress_fast_key() @test {
    String src = load_example(
        "examples/progress.ds",
        "\nlet k = { code: 0, rune: \"f\", ctrl: false }\nlet s2 = update(state, { __tag: \"Key\", __val: k })\ns2.speed"
    );
    Value result = eval_ds(src);
    assert(is_num(result));
    assert(as_num(result) == 5.0);
}

fn void test_timer_format() @test {
    String src   = load_example("examples/timer.ds", "\nformat_time(90)");
    Value result = eval_ds(src);
    assert(is_str(result));
    assert((*as_str(result)) == "01:30");
}

fn void test_timer_countdown() @test {
    String src = load_example(
        "examples/timer.ds",
        "\nlet s2 = update(state, { __tag: \"Tick\", __val: nil })\ns2.remaining"
    );
    Value result = eval_ds(src);
    assert(is_num(result));
    assert(as_num(result) == 59.0);
}

fn void test_tabs_initial_tab() @test {
    String src   = load_example("examples/tabs.ds", "\nstate.tab");
    Value result = eval_ds(src);
    assert(is_num(result) && as_num(result) == 0.0);
}

fn void test_tabs_navigate_right() @test {
    String src = load_example(
        "examples/tabs.ds",
        "\nlet k = { code: RIGHT, rune: \"\", ctrl: false }\nlet s2 = update(state, { __tag: \"Key\", __val: k })\ns2.tab"
    );
    Value result = eval_ds(src);
    assert(is_num(result));
    assert(as_num(result) == 1.0);
}

fn void test_repl_enter_adds_history() @test {
    String src = load_example(
        "examples/repl.ds",
        "\nlet s2 = { ...state, input: \"hello\" }\nlet k = { code: ENTER, rune: \"\", ctrl: false }\nlet s3 = update(s2, { __tag: \"Key\", __val: k })\nlen(s3.history)"
    );
    Value result = eval_ds(src);
    assert(is_num(result));
    assert(as_num(result) == 4.0); // 3 initial + 1 submitted
}

fn void test_repl_q_quits_when_empty() @test {
    String src = load_example(
        "examples/repl.ds",
        "\nlet k = { code: RUNE, rune: \"q\", ctrl: false }\nlet s2 = update(state, { __tag: \"Key\", __val: k })\nhas_field(s2, \"quit\")"
    );
    Value result = eval_ds(src);
    assert(is_bool(result) && as_bool(result));
}