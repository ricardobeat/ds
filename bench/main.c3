// bench/main.c3 — JSX stable-ref memoization benchmark
//
// Compares heap Array+Record allocations for N render passes:
//   CACHED  : view() uses JSX (<Comp prop=val />) routed through __element
//   UNCACHED: view() calls component functions directly (bypasses __element cache)
//
// String interning + record interning: all literal props produce stable Value bits
// across frames → __element fingerprint hits → 0 allocs/frame after warmup.

module bench;
import engine;
import std::io;

// ── DS source strings ────────────────────────────────────────────────────────

// Cached: JSX syntax routes through __element. String literals are interned
// at parse time — same content → same Value bits → fingerprint hit on re-render.
// sel0/sel1/sel2 are signals (stable pointers). All inputs stable → all cache hits.
const String CACHED_SRC = `
let Root   = fn(p, kids) { {kind: "root", items: kids} }
let Header = fn(p) { {kind: "header", value: p.title} }
let Item   = fn(p) { {kind: "item", text: p.text, selected: p.sel} }

let sel0 = signal(false)
let sel1 = signal(false)
let sel2 = signal(false)

let view = fn(cursor) {
  signal_set(sel0, cursor === 0)
  signal_set(sel1, cursor === 1)
  signal_set(sel2, cursor === 2)
  <Root>
    <Header title="Todo" />,
    <Item text="Buy milk"   sel=sel0 />,
    <Item text="Write code" sel=sel1 />,
    <Item text="Ship it"    sel=sel2 />
  </Root>
}
view
`;

// Uncached: structurally identical but components called directly, no memoization.
// Every frame: 5 component calls → 5 fresh records + 1 children array = 6 allocs.
const String UNCACHED_SRC = `
let Root   = fn(p, kids) { {kind: "root", items: kids} }
let Header = fn(p) { {kind: "header", value: p.title} }
let Item   = fn(p) { {kind: "item", text: p.text, selected: p.sel} }

let sel0 = signal(false)
let sel1 = signal(false)
let sel2 = signal(false)

let view = fn(cursor) {
  signal_set(sel0, cursor === 0)
  signal_set(sel1, cursor === 1)
  signal_set(sel2, cursor === 2)
  Root({}, [
    Header({title: "Todo"}),
    Item({text: "Buy milk",   sel: sel0}),
    Item({text: "Write code", sel: sel1}),
    Item({text: "Ship it",    sel: sel2})
  ])
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

	// Parse + eval: interns strings, allocates closures (not counted in bench).
	Value cached_view   = eval_src(CACHED_SRC);
	Value uncached_view = eval_src(UNCACHED_SRC);

	// Verify string interning is working: __element with a bare string arg.
	// "hello" is interned at parse time → same Value every frame → cache hits.
	// After warmup frame: 0 record allocs/frame (Leaf body never re-executes).
	Value str_test_fn = eval_src(`
		let Leaf = fn(s) { {val: s} }
		let view = fn(n) {
		  __begin_render()
		  __element(Leaf, "hello")
		}
		view
	`);
	// Direct call without __element — baseline: always 1 record/frame.
	Value str_direct_fn = eval_src(`
		let Leaf = fn(s) { {val: s} }
		let view = fn(n) { Leaf("hello") }
		view
	`);
	io::printfn("\n--- String interning verification ---");
	run_bench("str-direct", str_direct_fn, FRAMES);
	run_bench("str-cached", str_test_fn, FRAMES);

	io::printfn("\n=== JSX stable-ref memoization benchmark ===");
	io::printfn("5-component tree: Root + Header + Item×3, props passed as records");
	io::printfn("Record interning: literal props records have stable Value bits across frames");
	io::printfn("→ __element fingerprint hits → 0 allocs/frame after warmup");
	io::printfn("CACHED  : JSX → __element");
	io::printfn("UNCACHED: direct component calls (1 children array/frame, no memoization)");
	io::printfn("");
	io::printfn("%-12s  %-10s  %-10s  %-10s  %-10s  %-12s",
	            "path", "frames", "arrays", "records", "total", "per_frame");
	io::printfn("──────────────────────────────────────────────────────────────────────────────");

	run_bench("uncached", uncached_view, FRAMES);
	run_bench("cached",   cached_view,   FRAMES);

	io::printfn("");
}
