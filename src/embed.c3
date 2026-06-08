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
		uint id = intern(name);
		Binding new_binding = { .name_id = id, .value = mk_prim(name) };
		Binding* old = builtin_env.data.bindings_ptr;
		uint n = builtin_env.count;
		Binding* grown = mem::talloc_array(Binding, (sz)(n + 1));
		for (uint i = 0; i < n; i++) grown[i] = old[i];
		grown[n] = new_binding;
		builtin_env.data.bindings_ptr = grown;
		builtin_env.count = n + 1;
	}
	return ok;
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

fn bool engine_is_num(Value v)     => is_num(v);
fn bool engine_is_str(Value v)     => is_str(v);
fn bool engine_is_bool(Value v)    => is_bool(v);
fn bool engine_is_nil(Value v)     => is_nil(v);
fn bool engine_is_array(Value v)   => is_arr(v);
fn bool engine_is_record(Value v)  => is_rec(v);
fn bool engine_is_closure(Value v) => is_closure(v);

// ── Value creation ───────────────────────────────────────────────

fn Value engine_mk_num(double d) => mk_num(d);
fn Value engine_mk_bool(bool b)  => mk_bool(b);
fn Value engine_mk_nil()         => mk_nil();

fn Value engine_mk_str(String s) {
	return mk_str(s);
}

// ── Value extraction ─────────────────────────────────────────────

fn double engine_as_num(Value v) => as_num(v);
fn bool engine_as_bool(Value v)  => as_bool(v);

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
