module engine;
import std::io;

// Tests for the parser.  The parser lives in src/parser.c3 (same module),
// so we can call `parse_source` directly.  We test:
//   - Basic literals (num, str, bool, nil, ident)
//   - Binops with the right precedence
//   - Records and arrays
//   - Let bindings
//   - Function definitions + calls
//   - If/else
//   - Method calls (desugared to Lambda-bind-receiver + Get+Call)
//   - String concat
//   - The full sample end-to-end

fn Value run_parsed(String src)
{
	if (builtin_env == null) builtin_env = make_builtin_env();
	@pool() {
		ParseResult pr = parse_source(src);
		if (pr.error)
		{
			io::printfn("parse failed: %s", pr.message);
			return mk_nil();
		}
		AstNode* kernel = desugar(pr.root, null);
		EvalResult r = eval(kernel, builtin_env);
		if (r.thrown)
		{
			Value s = show(r.value);
			io::printfn("threw: %s", s.str_val);
			return mk_nil();
		}
		// Copy string results to the heap so they survive the @pool.
		if (r.value.type == STRING)
		{
			String dup = string::format(mem, "%s", r.value.str_val);
			r.value.str_val = dup;
		}
		return r.value;
	};
}

fn void test_parser_number() @test
{
	Value v = run_parsed("42");
	assert(v.type == NUMBER);
	assert(v.num_val == 42.0);
}

fn void test_parser_float() @test
{
	Value v = run_parsed("3.14");
	assert(v.type == NUMBER);
	assert(v.num_val == 3.14);
}

fn void test_parser_string() @test
{
	Value v = run_parsed("\"hello, world\"");
	assert(v.type == STRING);
	assert(v.str_val == "hello, world");
}

fn void test_parser_string_escapes() @test
{
	Value v = run_parsed("\"a\\tb\\nc\"");
	assert(v.type == STRING);
	assert(v.str_val == "a\tb\nc");
}

fn void test_parser_bool_nil() @test
{
	assert(run_parsed("true").type == BOOL);
	assert(run_parsed("true").bool_val);
	assert(run_parsed("false").bool_val == false);
	assert(run_parsed("nil").type == NIL);
}

fn void test_parser_arith_precedence() @test
{
	// 1 + 2 * 3  =>  7  (mul binds tighter than add)
	Value v = run_parsed("1 + 2 * 3");
	assert(v.num_val == 7.0);
}

fn void test_parser_parens() @test
{
	// (1 + 2) * 3  =>  9
	Value v = run_parsed("(1 + 2) * 3");
	assert(v.num_val == 9.0);
}

fn void test_parser_comparison() @test
{
	Value v = run_parsed("1 < 2");
	assert(v.type == BOOL && v.bool_val);
}

fn void test_parser_strict_eq() @test
{
	Value a = run_parsed("3 === 3");
	assert(a.type == BOOL && a.bool_val);
	Value b = run_parsed("3 === 4");
	assert(b.type == BOOL && !b.bool_val);
}

fn void test_parser_string_concat() @test
{
	Value v = run_parsed("\"foo\" + \"bar\"");
	assert(v.type == STRING);
	assert(v.str_val == "foobar");
}

fn void test_parser_record_get() @test
{
	// { x: 3, y: 4 }.y   =>  4
	Value v = run_parsed("{ x: 3, y: 4 }.y");
	assert(v.type == NUMBER);
	assert(v.num_val == 4.0);
}

fn void test_parser_array_index() @test
{
	// [10, 20, 30][1]   =>  20
	Value v = run_parsed("[10, 20, 30][1]");
	assert(v.type == NUMBER);
	assert(v.num_val == 20.0);
}

fn void test_parser_let_simple() @test
{
	// let x = 5; x * 2  =>  10
	Value v = run_parsed("let x = 5; x * 2");
	assert(v.num_val == 10.0);
}

fn void test_parser_let_chains() @test
{
	// let a = 1; let b = 2; let c = 3; a + b + c  =>  6
	Value v = run_parsed("let a = 1; let b = 2; let c = 3; a + b + c");
	assert(v.num_val == 6.0);
}

fn void test_parser_function_call() @test
{
	// let id = fn(x) { x }; id(99)  =>  99
	Value v = run_parsed("let id = fn(x) { x }; id(99)");
	assert(v.num_val == 99.0);
}

fn void test_parser_function_two_args() @test
{
	// let add = fn(a, b) { a + b }; add(3, 4)  =>  7
	Value v = run_parsed("let add = fn(a, b) { a + b }; add(3, 4)");
	assert(v.num_val == 7.0);
}

fn void test_parser_if_then_else() @test
{
	// if 1 < 2 then 100 else 200  =>  100
	Value v = run_parsed("if 1 < 2 then 100 else 200");
	assert(v.num_val == 100.0);
}

fn void test_parser_method_call() @test
{
	// let r = { name: "Alice", greet: fn(self) { "hi " + self.name } };
	// r.greet()   =>  "hi Alice"
	Value v = run_parsed("let r = { name: \"Alice\", greet: fn(self) { \"hi \" + self.name } }; r.greet()");
	assert(v.type == STRING);
	assert(v.str_val == "hi Alice");
}

fn void test_parser_recursion() @test
{
	// let fact = fn(n) { if n === 0 then 1 else n * fact(n - 1) };
	// fact(5)  =>  120
	Value v = run_parsed("let fact = fn(n) { if n === 0 then 1 else n * fact(n - 1) }; fact(5)");
	assert(v.num_val == 120.0);
}

fn void test_parser_comments() @test
{
	// Comments should be skipped.
	Value v = run_parsed("// a comment\nlet x = 7; /* block */ x + 1");
	assert(v.num_val == 8.0);
}

fn void test_parser_error_reports() @test
{
	ParseResult pr = parse_source("let = 5");
	assert(pr.error);
}

fn void test_parser_unary_neg() @test
{
	Value v = run_parsed("-5 + 10");
	assert(v.num_val == 5.0);
}

fn void test_parser_higher_order() @test
{
	// let apply = fn(f, x) { f(x) };
	// apply(fn(n) { n * 2 }, 21)   =>  42
	Value v = run_parsed("let apply = fn(f, x) { f(x) }; apply(fn(n) { n * 2 }, 21)");
	assert(v.num_val == 42.0);
}

fn void test_sample_end_to_end() @test
{
	// The same program as resources/sample.ds, inlined.  Exercises records,
	// method fields, method calls, string concat, and a higher-order wrapper.
	String src = `let alice = { name: "Alice", greet: fn(self) { "hi, I'm " + self.name } };
let bob   = { name: "Bob",   greet: fn(self) { "hi, I'm " + self.name } };
let greetBoth = fn(a, b) { a.greet() + " and " + b.greet() };
greetBoth(alice, bob)`;
	Value v = run_parsed(src);
	assert(v.type == STRING);
	assert(v.str_val == "hi, I'm Alice and hi, I'm Bob");
}
