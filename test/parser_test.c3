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
	g_element_slot = 0;
	g_element_slots = {};
	Env* env = make_builtin_env();
	ParseResult pr = parse_source(src);
	if (pr.error)
	{
		io::printfn("parse failed: %s", pr.message);
		return mk_nil();
	}
	AstNode* kernel = desugar(pr.root, null);
	EvalResult r = eval(kernel, env);
	if (r.thrown)
	{
		Value s = show(r.value);
		io::printfn("threw: %s", *as_str(s));
		return mk_nil();
	}
	return r.value;
}

fn void test_parser_number() @test
{
	Value v = run_parsed("42");
	assert(is_num(v));
	assert(as_num(v) == 42.0);
}

fn void test_parser_float() @test
{
	Value v = run_parsed("3.14");
	assert(is_num(v));
	assert(as_num(v) == 3.14);
}

fn void test_parser_string() @test
{
	Value v = run_parsed("\"hello, world\"");
	assert(is_str(v));
	assert(*as_str(v) == "hello, world");
}

fn void test_parser_string_escapes() @test
{
	Value v = run_parsed("\"a\\tb\\nc\"");
	assert(is_str(v));
	assert(*as_str(v) == "a\tb\nc");
}

fn void test_parser_bool_nil() @test
{
	assert(is_bool(run_parsed("true")));
	assert(as_bool(run_parsed("true")));
	assert(as_bool(run_parsed("false")) == false);
	assert(is_nil(run_parsed("nil")));
}

fn void test_parser_arith_precedence() @test
{
	// 1 + 2 * 3  =>  7  (mul binds tighter than add)
	Value v = run_parsed("1 + 2 * 3");
	assert(as_num(v) == 7.0);
}

fn void test_parser_parens() @test
{
	// (1 + 2) * 3  =>  9
	Value v = run_parsed("(1 + 2) * 3");
	assert(as_num(v) == 9.0);
}

fn void test_parser_comparison() @test
{
	Value v = run_parsed("1 < 2");
	assert(is_bool(v) && as_bool(v));
}

fn void test_parser_strict_eq() @test
{
	Value a = run_parsed("3 === 3");
	assert(is_bool(a) && as_bool(a));
	Value b = run_parsed("3 === 4");
	assert(is_bool(b) && !as_bool(b));
}

fn void test_parser_string_concat() @test
{
	Value v = run_parsed("\"foo\" + \"bar\"");
	assert(is_str(v));
	assert(*as_str(v) == "foobar");
}

fn void test_parser_record_get() @test
{
	// { x: 3, y: 4 }.y   =>  4
	Value v = run_parsed("{ x: 3, y: 4 }.y");
	assert(is_num(v));
	assert(as_num(v) == 4.0);
}

fn void test_parser_array_index() @test
{
	// [10, 20, 30][1]   =>  20
	Value v = run_parsed("[10, 20, 30][1]");
	assert(is_num(v));
	assert(as_num(v) == 20.0);
}

fn void test_parser_let_simple() @test
{
	// let x = 5; x * 2  =>  10
	Value v = run_parsed("let x = 5; x * 2");
	assert(as_num(v) == 10.0);
}

fn void test_parser_let_chains() @test
{
	// let a = 1; let b = 2; let c = 3; a + b + c  =>  6
	Value v = run_parsed("let a = 1; let b = 2; let c = 3; a + b + c");
	assert(as_num(v) == 6.0);
}

fn void test_parser_function_call() @test
{
	// let id = fn(x) { x }; id(99)  =>  99
	Value v = run_parsed("let id = fn(x) { x }; id(99)");
	assert(as_num(v) == 99.0);
}

fn void test_parser_function_two_args() @test
{
	// let add = fn(a, b) { a + b }; add(3, 4)  =>  7
	Value v = run_parsed("let add = fn(a, b) { a + b }; add(3, 4)");
	assert(as_num(v) == 7.0);
}

fn void test_parser_if_then_else() @test
{
	// if 1 < 2 then 100 else 200  =>  100
	Value v = run_parsed("if 1 < 2 then 100 else 200");
	assert(as_num(v) == 100.0);
}

fn void test_parser_method_call() @test
{
	// let r = { name: "Alice", greet: fn(self) { "hi " + self.name } };
	// r.greet()   =>  "hi Alice"
	Value v = run_parsed("let r = { name: \"Alice\", greet: fn(self) { \"hi \" + self.name } }; r.greet()");
	assert(is_str(v));
	assert(*as_str(v) == "hi Alice");
}

fn void test_parser_recursion() @test
{
	// let fact = fn(n) { if n === 0 then 1 else n * fact(n - 1) };
	// fact(5)  =>  120
	Value v = run_parsed("let fact = fn(n) { if n === 0 then 1 else n * fact(n - 1) }; fact(5)");
	assert(as_num(v) == 120.0);
}

fn void test_parser_comments() @test
{
	// Comments should be skipped.
	Value v = run_parsed("// a comment\nlet x = 7; /* block */ x + 1");
	assert(as_num(v) == 8.0);
}

fn void test_parser_error_reports() @test
{
	@pool() {
		ParseResult pr = parse_source("let = 5");
		assert(pr.error);
	};
}

fn void test_parser_unary_neg() @test
{
	Value v = run_parsed("-5 + 10");
	assert(as_num(v) == 5.0);
}

fn void test_parser_higher_order() @test
{
	// let apply = fn(f, x) { f(x) };
	// apply(fn(n) { n * 2 }, 21)   =>  42
	Value v = run_parsed("let apply = fn(f, x) { f(x) }; apply(fn(n) { n * 2 }, 21)");
	assert(as_num(v) == 42.0);
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
	assert(is_str(v));
	assert(*as_str(v) == "hi, I'm Alice and hi, I'm Bob");
}

fn void test_named_fn_basic() @test
{
	// fn add(a, b) { a + b }; add(3, 4)  =>  7
	Value v = run_parsed("fn add(a, b) { a + b }; add(3, 4)");
	assert(as_num(v) == 7.0);
}

fn void test_named_fn_recursion() @test
{
	// fn fact(n) { if n === 0 then 1 else n * fact(n - 1) }; fact(5)  =>  120
	Value v = run_parsed("fn fact(n) { if n === 0 then 1 else n * fact(n - 1) }; fact(5)");
	assert(as_num(v) == 120.0);
}

fn void test_named_fn_in_let_init() @test
{
	// Named fn at expression position: let f = fn id(x) { x }; f(42)  =>  42
	Value v = run_parsed("let f = fn id(x) { x }; f(42)");
	assert(as_num(v) == 42.0);
}

fn void test_named_fn_with_type_annotations() @test
{
	// fn add(a: Number, b: Number) { a + b }; add(3, 4)  =>  7
	Value v = run_parsed("fn add(a: Number, b: Number) { a + b }; add(3, 4)");
	assert(as_num(v) == 7.0);
}

// ============================================================================
// Block expressions
// ============================================================================

fn void test_block_expr_empty() @test
{
	Value v = run_parsed("{}");
	assert(is_nil(v));
}

fn void test_block_expr_single() @test
{
	Value v = run_parsed("{ 42 }");
	assert(as_num(v) == 42.0);
}

fn void test_block_expr_seq() @test
{
	// Last expression is the block's value
	Value v = run_parsed("{ 1; 2; 3 }");
	assert(as_num(v) == 3.0);
}

fn void test_block_expr_let_binding() @test
{
	Value v = run_parsed("{ let x = 10; x + 1 }");
	assert(as_num(v) == 11.0);
}

fn void test_block_expr_fn_declaration() @test
{
	Value v = run_parsed("{ let double = fn(n) { n * 2 }; double(21) }");
	assert(as_num(v) == 42.0);
}

fn void test_block_expr_nested_let() @test
{
	Value v = run_parsed("{ let a = 3; let b = 4; a + b }");
	assert(as_num(v) == 7.0);
}

fn void test_block_expr_record_still_works() @test
{
	// IDENT ":" → record literal, not block
	Value v = run_parsed("let r = { x: 1, y: 2 }; r.x + r.y");
	assert(as_num(v) == 3.0);
}

fn void test_block_expr_in_let() @test
{
	Value v = run_parsed("let x = { let a = 5; a * 2 }; x + 1");
	assert(as_num(v) == 11.0);
}

fn void test_block_expr_with_fn_decl() @test
{
	// fn declaration inside a block expression
	Value v = run_parsed("{ fn add(a, b) { a + b }; add(3, 4) }");
	assert(as_num(v) == 7.0);
}

fn void test_block_expr_nested_blocks() @test
{
	Value v = run_parsed("{ let x = { 10 }; let y = { 20 }; x + y }");
	assert(as_num(v) == 30.0);
}

// ============================================================================
// $ signal sugar
// ============================================================================

fn void test_signal_sugar_let_init() @test
{
	// let $x = 10  →  let x = signal(10)
	Value v = run_parsed("let $x = 10; $x");
	assert(as_num(v) == 10.0);
}

fn void test_signal_sugar_set() @test
{
	// $x = 42  →  signal_set(x, 42)  →  returns 42
	Value v = run_parsed("let $x = 10; $x = 42; $x");
	assert(as_num(v) == 42.0);
}

fn void test_signal_sugar_multiple() @test
{
	Value v = run_parsed("let $a = 1; let $b = 2; $a + $b");
	assert(as_num(v) == 3.0);
}

// ============================================================================
// from...import
// ============================================================================

fn void test_from_import_single() @test
{
	Value v = run_parsed("from signals import { get }; let $x = 99; get(x)");
	assert(as_num(v) == 99.0);
}

fn void test_from_import_multiple() @test
{
	Value v = run_parsed("from signals import { get, set }; let $x = 10; set(x, 20); get(x)");
	assert(as_num(v) == 20.0);
}

fn void test_from_import_with_sugar() @test
{
	Value v = run_parsed("from signals import { get }; let $score = 5; $score = 15; get(score)");
	assert(as_num(v) == 15.0);
}

fn void test_string_interning() @test
{
	// Same string literal evaluated twice must produce the same Value bits.
	Value v1 = run_parsed("\"hello\"");
	Value v2 = run_parsed("\"hello\"");
	Value v3 = run_parsed("\"world\"");
	assert(is_str(v1));
	assert(is_str(v2));
	assert(v1 == v2, "interned string values must be identical");
	assert(v1 != v3, "different strings must differ");
}

// ── Shorthand records ─────────────────────────────────────────────

fn void test_shorthand_record_single() @test
{
	Value v = run_parsed("let x = 42; { x }.x");
	assert(is_num(v) && as_num(v) == 42.0);
}

fn void test_shorthand_record_multiple() @test
{
	Value v = run_parsed("let x = 1; let y = 2; let r = { x, y }; r.x + r.y");
	assert(is_num(v) && as_num(v) == 3.0);
}

fn void test_shorthand_record_mixed() @test
{
	Value v = run_parsed("let x = 10; { x, y: 20 }.y");
	assert(is_num(v) && as_num(v) == 20.0);
}

// ── Record destructuring ──────────────────────────────────────────

fn void test_destruct_basic() @test
{
	Value v = run_parsed("let rec = { x: 1, y: 2 }; let { x, y } = rec; x + y");
	assert(is_num(v) && as_num(v) == 3.0);
}

fn void test_destruct_in_block() @test
{
	Value v = run_parsed("let rec = { a: 10, b: 20 }; { let { a, b } = rec; a * b }");
	assert(is_num(v) && as_num(v) == 200.0);
}

fn void test_destruct_rest() @test
{
	Value v = run_parsed("let r = { x: 1, y: 2, z: 3 }; let { x, ...rest } = r; rest.y + rest.z");
	assert(is_num(v) && as_num(v) == 5.0);
}

fn void test_destruct_rest_excludes_named() @test
{
	Value v = run_parsed("let r = { x: 1, y: 2 }; let { x, ...rest } = r; has_field(rest, \"x\")");
	assert(is_bool(v) && !as_bool(v));
}

fn void test_destruct_rhs_evaluated_once() @test
{
	// The RHS is bound to a temp; field accesses all read from the same binding.
	Value v = run_parsed("let r = { a: 5, b: 7 }; let { a, b } = r; a + b");
	assert(is_num(v) && as_num(v) == 12.0);
}

// ── import * (LETREC_SPREAD) ──────────────────────────────────────

fn void test_import_star_binds_fields() @test
{
	Value v = run_parsed("let mymod = { x: 10, y: 20 }; from mymod import *; x + y");
	assert(is_num(v) && as_num(v) == 30.0);
}

fn void test_import_star_namespace_access() @test
{
	// Namespace record access works independently of import *.
	Value v = run_parsed("let mymod = { val: 99 }; mymod.val");
	assert(is_num(v) && as_num(v) == 99.0);
}

fn void test_import_star_in_block() @test
{
	Value v = run_parsed("let m = { a: 3, b: 4 }; { from m import *; a * b }");
	assert(is_num(v) && as_num(v) == 12.0);
}

// ── record_without primitive ──────────────────────────────────────

fn void test_record_without_removes_key() @test
{
	Value v = run_parsed("let r = { x: 1, y: 2, z: 3 }; has_field(record_without(r, [\"x\"]), \"x\")");
	assert(is_bool(v) && !as_bool(v));
}

fn void test_record_without_keeps_others() @test
{
	Value v = run_parsed("let r = { x: 1, y: 2, z: 3 }; record_without(r, [\"x\"]).y");
	assert(is_num(v) && as_num(v) == 2.0);
}

fn void test_record_without_multiple() @test
{
	Value v = run_parsed("let r = { a: 1, b: 2, c: 3 }; let r2 = record_without(r, [\"a\", \"b\"]); has_field(r2, \"c\")");
	assert(is_bool(v) && as_bool(v));
}

// ── Match disambiguation: uppercase variable patterns ─────────────

fn void test_match_uppercase_var_pattern() @test
{
	// Uppercase ident followed by '->' is a primitive variable pattern, not a tag.
	Value v = run_parsed("let UP = 65; let code = 65; match code { UP -> true, _ -> false }");
	assert(is_bool(v) && as_bool(v));
}

fn void test_match_uppercase_var_no_match() @test
{
	Value v = run_parsed("let UP = 65; let code = 99; match code { UP -> true, _ -> false }");
	assert(is_bool(v) && !as_bool(v));
}

fn void test_match_tagged_still_works() @test
{
	// Tag(binding) arms still parse as tagged match.
	Value v = run_parsed("let msg = { __tag: \"Key\", __val: 42 }; match msg { Key(k) -> k, Tick(t) -> 0 }");
	assert(is_num(v) && as_num(v) == 42.0);
}

fn void test_match_mixed_case_patterns() @test
{
	// Mix of uppercase and lowercase variable patterns in one primitive match.
	Value v = run_parsed("let A = 1; let b = 2; let x = 2; match x { A -> 10, b -> 20, _ -> 30 }");
	assert(is_num(v) && as_num(v) == 20.0);
}
