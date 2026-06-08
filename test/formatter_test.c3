module engine;
import std::io;

// Tests for the formatter.  The formatter is in src/formatter.c3 (same
// module), so we call format_source directly.  We verify:
//   - canonical layout of records / arrays / function bodies
//   - idempotence (formatting the formatted output is a no-op)
//   - the formatted program still runs and produces the same result

fn String fmt(String src) => format_source(src).output;

fn void test_fmt_record_layout() @test
{
	String out = fmt("let r = {x:1, y:2}; r");
	// Records are always multi-line, one field per line, trailing commas.
	assert(out.contains("\n  x: 1,\n"));
	assert(out.contains("\n  y: 2,\n"));
}

fn void test_fmt_array_layout() @test
{
	String out = fmt("let a = [1, 2, 3]; a");
	assert(out.contains("\n  1,\n"));
	assert(out.contains("\n  2,\n"));
	assert(out.contains("\n  3,\n"));
}

fn void test_fmt_function_short_body() @test
{
	// Short function bodies stay on one line.
	String out = fmt("let f = fn(x) { x + 1 }; f");
	assert(out.contains("fn(x) { x + 1 }"));
}

fn void test_fmt_function_long_body() @test
{
	// Long function bodies break across lines.
	String out = fmt(
		"let f = fn(x) { if x > 0 then x * 2 + 1 - 7 / 3 else -x * 9 + 4 * 2 }; f");
	assert(out.contains("fn(x) {\n"));
}

fn void test_fmt_method_call() @test
{
	String out = fmt("let r = { name: \"A\", g: fn(self) { self.name } }; r.g()");
	assert(out.contains("self.name"));
	assert(!out.contains("self.\"name\""));
}

fn void test_fmt_binop_spacing() @test
{
	String out = fmt("1 + 2 * 3");
	assert(out == "1 + 2 * 3\n");
}

fn void test_fmt_call_args() @test
{
	String out = fmt("f(1, 2, 3)");
	assert(out == "f(1, 2, 3)\n");
}

fn void test_fmt_let_chain() @test
{
	String out = fmt("let a = 1; let b = 2; a + b");
	assert(out.contains("let a = 1;\n"));
	assert(out.contains("let b = 2;\n"));
	assert(out.contains("a + b\n"));
}

fn void test_fmt_idempotent() @test
{
	String src = `let alice = { name: "Alice", greet: fn(self) { "hi " + self.name } };
let bob   = { name: "Bob",   greet: fn(self) { "hi " + self.name } };
let greetBoth = fn(a, b) { a.greet() + " and " + b.greet() };
greetBoth(alice, bob)`;
	String once  = fmt(src);
	String twice = fmt(once);
	assert(once == twice, "formatter should be idempotent");
}

fn void test_fmt_preserves_semantics() @test
{
	// Format a program and run it; result should be the same as running
	// the original.
	String src = `let alice = { name: "Alice", greet: fn(self) { "hi " + self.name } };
let bob   = { name: "Bob",   greet: fn(self) { "yo " + self.name } };
let older = fn(a, b) { if a.age > b.age then a else b };
older(alice, bob).name`;
	// Run original.
	Value before = run_parsed(src);
	// Format, then run the formatted version.
	String formatted = fmt(src);
	Value after       = run_parsed(formatted);
	assert(tag_of(before) == tag_of(after));
	if (is_str(before)) assert(*as_str(before) == *as_str(after));
}

fn void test_fmt_if_multiline_when_long() @test
{
	String src = "if firstArg < secondArg then aVeryLongBranchResultThatIsSignificant else anotherVeryLongBranchResultThatIsSignificant";
	String out = fmt(src);
	// The expression is well over the formatter's threshold, so the
	// formatter should break the if across lines.
	assert(out.contains("if firstArg < secondArg then\n"));
	assert(out.contains("\nelse\n"));
}

fn void test_fmt_if_singleline_when_short() @test
{
	String out = fmt("if 1 < 2 then 10 else 20");
	assert(out.contains("if 1 < 2 then 10 else 20"));
}

fn void test_fmt_else_if_chain() @test
{
	// Short inline chain
	String out1 = fmt("if a then 1 else if b then 2 else 3");
	assert(out1.contains("else if b then 2 else 3"), "else-if should stay on same line");
	// Outer IF multiline, inner else-if should still chain on same line
	String out2 = fmt("if veryLongConditionName then veryLongBranchResultName else if b then 2 else 3");
	assert(out2.contains("else if b then 2 else 3"), "else-if should chain even when outer is multiline");
	// Block branch forces multiline
	String out3 = fmt("if x then y else { a\nb }");
	assert(out3.contains("else {"), "block branch should use else { on same line");
}

fn void test_fmt_sample_round_trip() @test
{
	// Round-trip resources/sample.ds: formatted output runs and matches.
	String src = `let alice = {
  name: "Alice",
  age: 30,
  greet: fn(self) { "hi, I'm " + self.name }
}
let bob = {
  name: "Bob",
  age: 25,
  greet: fn(self) { "yo, I'm " + self.name }
}
let greetOlder = fn(a, b) {
  if a.age > b.age then a.greet() + " (older)" else b.greet() + " (older)"
}
greetOlder(alice, bob)`;
	String formatted = fmt(src);
	Value v          = run_parsed(formatted);
	assert(is_str(v));
	assert(*as_str(v) == "hi, I'm Alice (older)");
}
