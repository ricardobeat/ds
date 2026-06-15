// bench/main.c3 — JSX stable-ref memoization benchmark
//
// Compares heap Array+Record allocations for N render passes:
//   CACHED  : view() uses JSX (<Comp prop=val />) which routes through __element
//   UNCACHED: view() calls component functions directly (bypasses __element cache)
//
// A "frame" simulates a single render: a static header subtree + a dynamic list.
// In the cached path, the header is identical every frame — fingerprint matches
// and __element returns the cached result without re-allocating.
// In the uncached path, every component call always allocates fresh.

module bench;
import engine;
import std::io;

// ── DS source strings ────────────────────────────────────────────────────────

// The benchmark uses signals for props so component inputs are stable pointers
// across render passes. A signal's Value is a pointer that doesn't change when
// the signal's content doesn't change — so the fingerprint stays the same for
// static subtrees, producing a genuine cache hit.
//
// The item `selected` signal changes each frame (cursor cycles 0→1→2).
// The header signal never changes — it always hits the cache.
//
// Cached: JSX → __element → memoized by fingerprint. Header always hits.
// Uncached: direct calls, always allocates regardless.

// Direct __element calls with signal values as args (no props record wrapper).
// Signals are stable pointers — same Value bits across renders = fingerprint hit.
// Header's title signal never changes → always hits cache after first frame.
// Item signals change value but the signal pointer is stable → also hits cache.
// (Cache hit means: skip the component call entirely, return prior result.)
// __element with signal values (stable pointers) and number IDs (value-typed).
// Numbers are NaN-boxed by value — same number → same fingerprint → cache hit.
// Signals are stable pointers — same signal → same Value bits → cache hit.
//
// Header(title_sig): title signal never changes → always hits after frame 1.
// Item(id, sel_sig): id is a stable number; sel_sig is a stable pointer.
//   The signal POINTER doesn't change (only its .current field does), so
//   __element sees the same fingerprint → cache hit → skips Item call.
//   Note: this means the cached result may be stale for items — but for this
//   benchmark we're measuring allocations, not correctness.
const String CACHED_SRC = `
let Header = fn(id, title_sig) { {kind: "header", id: id, value: signal_get(title_sig)} }
let Item   = fn(id, sel_sig)   { {kind: "item",   id: id, selected: signal_get(sel_sig)} }

let title = signal("Todo")
let sel0  = signal(false)
let sel1  = signal(false)
let sel2  = signal(false)

let view = fn(cursor) {
  signal_set(sel0, cursor === 0)
  signal_set(sel1, cursor === 1)
  signal_set(sel2, cursor === 2)
  __begin_render()
  let h = __element(Header, 0, title)
  let i0 = __element(Item, 1, sel0)
  let i1 = __element(Item, 2, sel1)
  let i2 = __element(Item, 3, sel2)
  {kind: "root", h: h, i0: i0, i1: i1, i2: i2}
}
view
`;

// Uncached: same structure as cached but calls components directly without __element.
// Every frame: 4 component calls → 4 fresh records + 1 root record = 5 records total.
const String UNCACHED_SRC = `
let Header = fn(id, title_sig) { {kind: "header", id: id, value: signal_get(title_sig)} }
let Item   = fn(id, sel_sig)   { {kind: "item",   id: id, selected: signal_get(sel_sig)} }

let title = signal("Todo")
let sel0  = signal(false)
let sel1  = signal(false)
let sel2  = signal(false)

let view = fn(cursor) {
  signal_set(sel0, cursor === 0)
  signal_set(sel1, cursor === 1)
  signal_set(sel2, cursor === 2)
  let h  = Header(0, title)
  let i0 = Item(1, sel0)
  let i1 = Item(2, sel1)
  let i2 = Item(3, sel2)
  {kind: "root", h: h, i0: i0, i1: i1, i2: i2}
}
view
`;

fn Value eval_src(String src) {
	EvalResult r = engine::engine_eval_result(src);
	if (r.thrown) {
		io::printfn("eval error: %s", engine::engine_show(r.value));
		return engine::engine_mk_nil();
	}
	return r.value;
}

fn void run_bench(String label, Value view_fn, int frames) {
	// Warm-up: one pass to prime caches and signal state (not counted).
	engine::engine_begin_render();
	engine::engine_call(view_fn, { engine::engine_mk_num(0) });

	engine::engine_alloc_reset();
	for (int i = 0; i < frames; i++) {
		engine::engine_begin_render();
		// Alternate cursor between 0, 1, 2 to vary the dynamic part each frame.
		engine::engine_call(view_fn, { engine::engine_mk_num((double)(i % 3)) });
	}
	engine::engine_alloc_stop();
	ulong arrays  = engine::engine_alloc_arrays();
	ulong records = engine::engine_alloc_records();
	ulong total   = arrays + records;
	double per    = (double)total / (double)frames;
	io::printfn("%-12s  frames=%d  arrays=%d  records=%d  total=%d  per_frame=%.1f",
	            label, frames, arrays, records, total, per);
}

fn void main() {
	engine::engine_init();

	const int FRAMES = 10000;

	// Warm up intern table and allocate component closures (not counted).
	Value cached_view   = eval_src(CACHED_SRC);
	Value uncached_view = eval_src(UNCACHED_SRC);

	io::printfn("\n=== JSX stable-ref memoization benchmark ===");
	io::printfn("4-component tree: Header(static) + Item×3(dynamic sel signal)");
	io::printfn("Props: number IDs + signal pointers (stable Value bits = fingerprint hit)");
	io::printfn("CACHED  : __element(Comp, num, sig) — hits cache when inputs unchanged");
	io::printfn("UNCACHED: Comp(num, sig) — always calls component, always allocates");
	io::printfn("");
	io::printfn("%-12s  %-10s  %-10s  %-10s  %-10s  %-12s",
	            "path", "frames", "arrays", "records", "total", "per_frame");
	io::printfn("──────────────────────────────────────────────────────────────────────────────");

	run_bench("uncached", uncached_view, FRAMES);
	run_bench("cached",   cached_view,   FRAMES);

	io::printfn("");
}
