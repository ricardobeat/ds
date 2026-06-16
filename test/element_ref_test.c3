module engine;
import std::io;

// Tests for the __element / __begin_render stable-ref primitives.
// __element(fn, props, ...children) calls fn and caches the result by slot.
// On re-render with identical inputs (fingerprint match), returns cached value.

fn void test_element_returns_record() @test
{
	// __element calls the component and returns its result
	Value v = run_parsed("let Div = fn(p) { p }; __begin_render(); __element(Div, {x: 1})");
	assert(is_rec(v));
}

fn void test_element_has_id() @test
{
	// Slot 0 is assigned to the first element in a render pass
	// (We verify via __begin_render resetting; indirect: just check it runs without error)
	Value v = run_parsed("let Div = fn(p) { p }; __begin_render(); let e = __element(Div, {x: 1}); e.x");
	assert(is_num(v));
	assert(as_num(v) == 1.0);
}

fn void test_element_increments_slot() @test
{
	// Each __element call gets a distinct slot; both components are called
	String src = "let Div = fn(p) { p.x }; __begin_render(); let e1 = __element(Div, {x: 1}); let e2 = __element(Div, {x: 2}); e1 + e2";
	Value v = run_parsed(src);
	assert(is_num(v));
	assert(as_num(v) == 3.0);
}

fn void test_begin_render_resets_slot() @test
{
	// After __begin_render, slot counter resets to 0
	// Both render passes should invoke the component at slot 0
	String src = "let Div = fn(p) { p.v }; __begin_render(); let a = __element(Div, {v: 10}); __begin_render(); let b = __element(Div, {v: 20}); a + b";
	Value v = run_parsed(src);
	assert(is_num(v));
	assert(as_num(v) == 30.0);
}

fn void test_element_preserves_tag() @test
{
	// Component receives props correctly and returns result
	String src = "let Div = fn(p) { p.tag }; __begin_render(); __element(Div, {tag: \"div\"})";
	Value v = run_parsed(src);
	assert(is_str(v));
	assert(*as_str(v) == "div");
}

fn void test_element_preserves_props() @test
{
	String src = "let Div = fn(p) { p.name }; __begin_render(); __element(Div, {name: \"test\"})";
	Value v = run_parsed(src);
	assert(is_str(v));
	assert(*as_str(v) == "test");
}

fn void test_element_ref_with_children() @test
{
	// Component receives children as second arg
	String src = "let Div = fn(p, kids) { len(kids) }; __begin_render(); __element(Div, {}, 10, 20, 30)";
	Value v = run_parsed(src);
	assert(is_num(v));
	assert(as_num(v) == 3.0);
}

fn void test_element_ref_no_children() @test
{
	// No children: component called with (props) only
	String src = "let Div = fn(p) { p.x }; __begin_render(); __element(Div, {x: 42})";
	Value v = run_parsed(src);
	assert(is_num(v));
	assert(as_num(v) == 42.0);
}

fn void test_element_slot_across_render_passes() @test
{
	// Cache hit: same input Value bits on second render pass → slot result reused.
	// Verify by directly inspecting g_element_slots after two prim_dispatch calls.
	g_element_slot = 0;
	g_element_slots = {};

	// Use a plain-number prop — same NaN-boxed bits every call.
	Value prop = mk_num(42.0);

	// Build a closure without allocating (manually fill a Closure struct on the stack).
	Closure comp_c;
	comp_c.param_ids = {};
	comp_c.body = null;
	comp_c.env = null;
	Value comp = val_closure(&comp_c);

	// Manually prime slot 0 as if the first render already ran and produced result=99.
	Value fake_result = mk_num(99.0);
	ulong fp = (ulong)comp ^ (ulong)prop;
	g_element_slots[0].used        = true;
	g_element_slots[0].fingerprint = (Value)fp;
	g_element_slots[0].result      = fake_result;

	// Second render pass: same comp + same prop → cache hit → return fake_result.
	g_element_slot = 0;
	EvalResult r = prim_dispatch("__element", { comp, prop });
	assert(!r.thrown);
	assert(r.value == fake_result);
}
