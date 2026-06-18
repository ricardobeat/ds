// ============================================================================
// EMBEDDING API — call the engine from a host C3 program.
// 
// Usage:
//   import engine;
//   engine::engine_init();
//   engine::engine_register("my_fn", my_fn);
//   Value result = engine::engine_eval("1 + 2");
// 
// Host functions receive Value[] args and return EvalResult.
// Use engine_is_*/engine_as_*/engine_mk_* to marshal values.
// ============================================================================

module engine;
import std::io;

// ── Lifecycle ────────────────────────────────────────────────────

fn void engine_init() {
    intern_init();
    builtin_env = make_builtin_env();
}

// ── Host function registration ───────────────────────────────────

fn bool engine_register(String name, HostFn func) {
    bool ok = register_host_fn(name, func);
    if (ok && builtin_env != null) {
        // Add to the builtin env so the tree-walker can resolve it
        uint id             = intern(name);
        Binding new_binding = { .name_id = id, .value = mk_prim(name) };
        Binding* old        = builtin_env.data.bindings_ptr;
        uint n              = builtin_env.count;
        Binding* grown      = mem::talloc_array(Binding, (sz)(n + 1));
        for (uint i = 0; i < n; i++) grown[i] = old[i];
        grown[n] = new_binding;
        builtin_env.data.bindings_ptr = grown;
        builtin_env.count = n + 1;
    }
    return ok;
}

// Register a pre-built Value directly into the builtin env (e.g. a namespace record).
fn void engine_register_value(String name, Value v) {
    if (builtin_env == null) return;
    uint id             = intern(name);
    Binding new_binding = { .name_id = id, .value = v };
    Binding* old        = builtin_env.data.bindings_ptr;
    uint n              = builtin_env.count;
    Binding* grown      = mem::new_array(Binding, (sz)(n + 1));
    for (uint i = 0; i < n; i++) grown[i] = old[i];
    grown[n] = new_binding;
    builtin_env.data.bindings_ptr = grown;
    builtin_env.count = n + 1;
}

// ── Evaluation ───────────────────────────────────────────────────

fn EvalResult engine_eval_result(String source) {
    ParseResult pr = parse_source(source);
    if (pr.error) {
        return { .thrown = true, .value = mk_str(pr.message) };
    }
    AstNode* kernel = desugar(pr.root, null);
    return eval(kernel, builtin_env);
}

fn Value engine_eval(String source) {
    EvalResult r = engine_eval_result(source);
    if (r.thrown) {
        Value s = show(r.value);
        io::printfn("threw: %s", *as_str(s));
        return mk_nil();
    }
    return r.value;
}

// ── Value type checks ────────────────────────────────────────────

fn bool engine_is_num(Value v) => is_num(v);
fn bool engine_is_str(Value v) => is_str(v);
fn bool engine_is_bool(Value v) => is_bool(v);
fn bool engine_is_nil(Value v) => is_nil(v);
fn bool engine_is_array(Value v) => is_arr(v);
fn bool engine_is_record(Value v) => is_rec(v);
fn bool engine_is_closure(Value v) => is_closure(v);

// ── Value creation ───────────────────────────────────────────────

fn Value engine_mk_num(double d) => mk_num(d);
fn Value engine_mk_bool(bool b) => mk_bool(b);
fn Value engine_mk_nil() => mk_nil();

fn Value engine_mk_str(String s) {
    return mk_str(s);
}

// Build a DS record from parallel key/value arrays.
fn Value engine_mk_record(String[] keys, Value[] values) {
    Record* r    = new_record();
    uint[] ids   = mem::new_array(uint, keys.len);
    Value[] vals = mem::new_array(Value, keys.len);
    for (int i = 0; i < keys.len; i++) {
        ids[i] = intern(keys[i]);
        // Re-intern string Values so their String* boxes are heap-stable.
        // Records built here may be cached across @pool() frame boundaries.
        vals[i] = is_str(values[i]) ? mk_str_intern(*as_str(values[i])) : values[i];
    }
    r.keys = ids;
    r.values = vals;
    return val_rec(r);
}

// Build a DS tagged value: { __tag: tag, __val: payload }
fn Value engine_mk_tagged(String tag, Value payload) {
    return engine_mk_record({ "__tag", "__val" }, { mk_str(tag), payload });
}

// Build a DS array from a slice of Values.
fn Value engine_mk_array(Value[] values) {
    Array* a   = new_array();
    Value* buf = mem::new_array(Value, values.len);
    for (sz i = 0; i < values.len; i++) {
        buf[i] = is_str(values[i]) ? mk_str_intern(*as_str(values[i])) : values[i];
    }
    a.items = buf[:values.len];
    return val_arr(a);
}

// ── Value extraction ─────────────────────────────────────────────

fn double engine_as_num(Value v) => as_num(v);
fn bool engine_as_bool(Value v) => as_bool(v);

// engine_as_str returns a String slice pointing into the engine's
// pool-managed memory.  Copy it before the next engine call if you
// need it to persist.
fn String engine_as_str(Value v) => *as_str(v);

// ── Show (value -> string representation) ────────────────────────

// Returns a String slice.  Same lifetime caveat as engine_as_str.
fn String engine_show(Value v) {
    Value s = show(v);
    return *as_str(s);
}

// ── Array access ─────────────────────────────────────────────────

fn int engine_array_len(Value v) {
    if (!is_arr(v)) return 0;
    return (int)as_arr(v).items.len;
}

fn Value engine_array_get(Value v, int index) {
    if (!is_arr(v)) return mk_nil();
    Array* a = as_arr(v);
    if (index < 0 || index >= (int)a.items.len) return mk_nil();
    return a.items[index];
}

// ── Record field access ──────────────────────────────────────────

fn bool engine_record_has(Value v, String field) {
    if (!is_rec(v)) return false;
    Record* r = as_rec(v);
    uint want = intern(field);
    foreach (&key : r.keys) {
        if (*key == want) return true;
    }
    return false;
}

fn Value engine_record_get(Value v, String field) {
    if (!is_rec(v)) return mk_nil();
    Record* r = as_rec(v);
    uint atom = intern(field);
    for (int i = 0; i < r.keys.len; i++) {
        if (r.keys[i] == atom) return r.values[i];
    }
    return mk_nil();
}

fn int engine_record_len(Value v) {
    if (!is_rec(v)) return 0;
    return (int)as_rec(v).keys.len;
}

// ── Calling DS closures from C3 ──────────────────────────────────

// engine_begin_render resets the JSX element slot counter for a new render pass.
// Call this before invoking the DS view function each frame.
fn void engine_begin_render() {
    g_element_slot = 0;
}

// Allocation tracking — count heap Array/Record allocations across render passes.
fn void engine_alloc_reset() {
    g_alloc_arrays = 0;
    g_alloc_records = 0;
    g_alloc_tracking = true;
}
fn void engine_alloc_stop() {
    g_alloc_tracking = false;
}
fn ulong engine_alloc_arrays() => g_alloc_arrays;
fn ulong engine_alloc_records() => g_alloc_records;
fn ulong engine_alloc_total() => g_alloc_arrays + g_alloc_records;

// engine_call invokes a DS closure value with the given arguments.
// Goes through eval() so TCO trampolining is handled correctly.
fn EvalResult engine_call(Value fn_val, Value[] args) {
    if (!is_closure(fn_val) && !is_prim(fn_val)) {
        return { .thrown = true, .value = mk_str("engine_call: not a function") };
    }
    EvalResult r = apply_fn(fn_val, args);
    if (r.is_tail) {
        return eval(r.tail_node, r.tail_env);
    }
    return r;
}