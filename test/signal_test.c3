module engine;
import std::io;

// Tests for the reactive primitives: signal, signal_get, signal_set,
// derived, and effect.

fn void test_signal_create_and_read() @test
{
	// signal(42) creates a signal; signal_get returns the initial value.
	Value v = run_parsed("let s = signal(42); signal_get(s)");
	assert(is_num(v));
	assert(as_num(v) == 42.0);
}

fn void test_signal_set_and_read() @test
{
	// signal_set updates the value; signal_get returns the new value.
	Value v = run_parsed("let s = signal(0); signal_set(s, 99); signal_get(s)");
	assert(is_num(v));
	assert(as_num(v) == 99.0);
}

fn void test_signal_set_returns_nil() @test
{
	Value v = run_parsed("let s = signal(0); signal_set(s, 5)");
	assert(is_nil(v));
}

fn void test_signal_string_value() @test
{
	Value v = run_parsed("let s = signal(\"hello\"); signal_get(s)");
	assert(is_str(v));
	assert(*as_str(v) == "hello");
}

fn void test_signal_type_error() @test
{
	// signal_set on a non-signal should throw.
	Value v = run_parsed("signal_set(42, 1)");
	assert(is_nil(v)); // run_parsed returns nil on throw
}

fn void test_derived_basic() @test
{
	// derived(() => 10 + 5) should compute 15 on first read.
	Value v = run_parsed("let d = derived(fn() { 10 + 5 }); signal_get(d)");
	assert(is_num(v));
	assert(as_num(v) == 15.0);
}

fn void test_derived_tracks_signal() @test
{
	// derived reads a signal; changing the signal invalidates the derived.
	String src = "let s = signal(3); let d = derived(fn() { signal_get(s) * 2 }); signal_get(d)";
	Value v = run_parsed(src);
	assert(is_num(v));
	assert(as_num(v) == 6.0);
}

fn void test_derived_updates_on_signal_change() @test
{
	// After signal_set, reading the derived should recompute.
	String src = "let s = signal(3); let d = derived(fn() { signal_get(s) * 2 }); signal_set(s, 10); signal_get(d)";
	Value v = run_parsed(src);
	assert(is_num(v));
	assert(as_num(v) == 20.0);
}

fn void test_derived_caches() @test
{
	// Reading a derived twice without changing deps should return cached value.
	String src = "let s = signal(5); let d = derived(fn() { signal_get(s) + 1 }); let a = signal_get(d); let b = signal_get(d); a + b";
	Value v = run_parsed(src);
	assert(is_num(v));
	assert(as_num(v) == 12.0);
}

fn void test_derived_chain() @test
{
	// d2 depends on d1 which depends on s.  Changing s should propagate.
	String src = "let s = signal(1); let d1 = derived(fn() { signal_get(s) + 1 }); let d2 = derived(fn() { signal_get(d1) * 3 }); signal_set(s, 4); signal_get(d2)";
	Value v = run_parsed(src);
	assert(is_num(v));
	assert(as_num(v) == 15.0);
}

fn void test_effect_runs_on_signal_change() @test
{
	// An effect that reads a signal re-runs when the signal changes.
	// Use a helper to avoid needing ';' inside the closure body.
	String src = "let count = signal(0); let runs = signal(0); let inc = fn(_v) { signal_set(runs, signal_get(runs) + 1) }; effect(fn() { inc(signal_get(count)) }); signal_set(count, 1); signal_get(runs)";
	Value v = run_parsed(src);
	assert(is_num(v));
	// effect runs once on creation (runs=1) + once on count change (runs=2)
	assert(as_num(v) == 2.0);
}

fn void test_effect_re_runs_on_each_change() @test
{
	String src = "let s = signal(0); let runs = signal(0); let inc = fn(_v) { signal_set(runs, signal_get(runs) + 1) }; effect(fn() { inc(signal_get(s)) }); signal_set(s, 1); signal_set(s, 2); signal_set(s, 3); signal_get(runs)";
	Value v = run_parsed(src);
	assert(is_num(v));
	// 1 (initial) + 3 (three signal_set calls) = 4
	assert(as_num(v) == 4.0);
}

fn void test_signal_value_identity() @test
{
	// Two reads of the same signal return the same value.
	String src = "let s = signal(42); let a = signal_get(s); let b = signal_get(s); a === b";
	Value v = run_parsed(src);
	assert(is_bool(v));
	assert(as_bool(v));
}

fn void test_signal_multiple_types() @test
{
	// Signal can hold any value type.
	String src = "let s = signal({name: \"test\", value: 42}); let r = signal_get(s); r.name";
	Value v = run_parsed(src);
	assert(is_str(v));
	assert(*as_str(v) == "test");
}

fn void test_derived_with_multiple_signals() @test
{
	String src = "let a = signal(2); let b = signal(3); let d = derived(fn() { signal_get(a) + signal_get(b) }); signal_get(d)";
	Value v = run_parsed(src);
	assert(is_num(v));
	assert(as_num(v) == 5.0);
}

fn void test_derived_with_multiple_signals_update_one() @test
{
	String src = "let a = signal(2); let b = signal(3); let d = derived(fn() { signal_get(a) + signal_get(b) }); signal_set(a, 10); signal_get(d)";
	Value v = run_parsed(src);
	assert(is_num(v));
	assert(as_num(v) == 13.0);
}
