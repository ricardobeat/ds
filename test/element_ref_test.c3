module engine;
import std::io;

// Tests for the __element / __begin_render stable-ref primitives.

fn void test_element_returns_record() @test
{
	Value v = run_parsed("let Div = fn(p) { p }; __element(Div, {x: 1})");
	assert(is_rec(v));
}

fn void test_element_has_id() @test
{
	Value v = run_parsed("let Div = fn(p) { p }; __begin_render(); let e = __element(Div, {x: 1}); e.__id");
	assert(is_num(v));
	assert(as_num(v) == 0.0);
}

fn void test_element_increments_slot() @test
{
	String src = "let Div = fn(p) { p }; __begin_render(); let e1 = __element(Div, {x: 1}); let e2 = __element(Div, {x: 2}); e2.__id";
	Value v = run_parsed(src);
	assert(is_num(v));
	assert(as_num(v) == 1.0);
}

fn void test_begin_render_resets_slot() @test
{
	String src = "let Div = fn(p) { p }; __begin_render(); __element(Div, {a: 1}); __element(Div, {b: 2}); __begin_render(); let e = __element(Div, {c: 3}); e.__id";
	Value v = run_parsed(src);
	assert(is_num(v));
	assert(as_num(v) == 0.0);
}

fn void test_element_preserves_tag() @test
{
	// __tag stores the tag function. Check it's not nil (i.e., was stored).
	String src = "let Div = fn(p) { p }; __begin_render(); let e = __element(Div, {x: 1}); e.__tag === nil";
	Value v = run_parsed(src);
	assert(is_bool(v));
	assert(!as_bool(v));
}

fn void test_element_preserves_props() @test
{
	String src = "let Div = fn(p) { p }; __begin_render(); let e = __element(Div, {name: \"test\"}); e.__props.name";
	Value v = run_parsed(src);
	assert(is_str(v));
	assert(*as_str(v) == "test");
}

fn void test_element_ref_with_children() @test
{
	String src = "let Div = fn(p, kids) { kids }; __begin_render(); let e = __element(Div, {}, 10, 20, 30); len(e.__children)";
	Value v = run_parsed(src);
	assert(is_num(v));
	assert(as_num(v) == 3.0);
}

fn void test_element_ref_no_children() @test
{
	String src = "let Div = fn(p) { p }; __begin_render(); let e = __element(Div, {x: 1}); len(e.__children)";
	Value v = run_parsed(src);
	assert(is_num(v));
	assert(as_num(v) == 0.0);
}

fn void test_element_slot_across_render_passes() @test
{
	// Two render passes should produce the same slot IDs.
	String src = "let Div = fn(p) { p }; __begin_render(); let a = __element(Div, {v: 1}); __begin_render(); let b = __element(Div, {v: 2}); a.__id === b.__id";
	Value v = run_parsed(src);
	assert(is_bool(v));
	assert(as_bool(v));
}
