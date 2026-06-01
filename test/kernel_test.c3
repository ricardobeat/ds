module engine;
import std::io;

// Helpers
fn AstNode* make_binop(String op, AstNode* lhs, AstNode* rhs) =>
	make_call(make_prim_node(op), { lhs, rhs });

fn AstNode* make_let(String name, AstNode* init, AstNode* body) =>
	make_letrec(name, init, body);

fn Value eval_value(AstNode* node)
{
	EvalResult r = eval(node, null);
	assert(!r.thrown, "test program threw");
	return r.value;
}

fn Value eval_surface(AstNode* node)
{
	AstNode* k = desugar(node);
	EvalResult r = eval(k, null);
	assert(!r.thrown, "desugared program threw");
	return r.value;
}

// ============================================================================
// TESTS — port of reference/test.py sections 1, 2, 3, 5, 7.
// Sections 4, 6, 8 need the desugarer (build-order steps 3-5).
// ============================================================================

fn void test_lit_num() @test
{
	@pool() {
		Value v = eval_value(make_lit(mk_num(42.0)));
		assert(v.type == NUMBER);
		assert(v.num_val == 42.0);
	};
}

fn void test_lit_str() @test
{
	@pool() {
		Value v = eval_value(make_lit(mk_str("hi")));
		assert(v.type == STRING);
		assert(v.str_val == "hi");
	};
}

fn void test_arith() @test
{
	@pool() {
		AstNode* prog = make_binop("+",
			make_lit(mk_num(3.0)),
			make_binop("*", make_lit(mk_num(4.0)), make_lit(mk_num(2.0))));
		Value v = eval_value(prog);
		assert(v.type == NUMBER);
		assert(v.num_val == 11.0);
	};
}

fn void test_strict_eq() @test
{
	@pool() {
		Value a = eval_value(make_binop("===", make_lit(mk_num(3.0)), make_lit(mk_num(3.0))));
		assert(a.type == BOOL && a.bool_val);

		Value b = eval_value(make_binop("===", make_lit(mk_num(3.0)), make_lit(mk_str("3"))));
		assert(b.type == BOOL && !b.bool_val);
	};
}

fn void test_closure_lexical() @test
{
	@pool() {
		AstNode* body = make_binop("+", make_var("x"), make_var("y"));
		AstNode* inner = make_lambda({ "y" }, body);
		AstNode* outer = make_lambda({ "x" }, inner);
		AstNode* add = make_var("add");
		AstNode* add10 = make_call(add, { make_lit(mk_num(10.0)) });
		AstNode* whole = make_let("add", outer, make_call(add10, { make_lit(mk_num(5.0)) }));
		io::printn("about to eval");
		EvalResult r = eval(whole, null);
		io::printfn("closure_lexical: thrown=%d type=%d num=%f", r.thrown, r.value.type.ordinal, r.value.num_val);
		assert(!r.thrown);
		assert(r.value.type == NUMBER);
		assert(r.value.num_val == 15.0);
	};
}

fn void test_let_simple() @test
{
	@pool() {
		// let x = 42; x  =>  42
		AstNode* prog = make_let("x", make_lit(mk_num(42.0)), make_var("x"));
		Value v = eval_value(prog);
		assert(v.type == NUMBER);
		assert(v.num_val == 42.0);
	};
}

fn void test_let_lambda() @test
{
	@pool() {
		// let id = fn(x) { x }; id(99)  =>  99
		AstNode* id_fn = make_lambda({ "x" }, make_var("x"));
		AstNode* prog = make_let("id", id_fn,
			make_call(make_var("id"), { make_lit(mk_num(99.0)) }));
		Value v = eval_value(prog);
		assert(v.type == NUMBER);
		assert(v.num_val == 99.0);
	};
}

fn void test_recursion_sum() @test
{
	@pool() {
		AstNode* sum_body = make_if(
			make_binop("===", make_var("n"), make_lit(mk_num(0.0))),
			make_var("acc"),
			make_call(make_var("sum"), {
				make_binop("-", make_var("n"), make_lit(mk_num(1.0))),
				make_binop("+", make_var("acc"), make_var("n")),
			}));
		AstNode* sum_fn = make_lambda({ "n", "acc" }, sum_body);
		AstNode* prog = make_let("sum", sum_fn,
			make_call(make_var("sum"), { make_lit(mk_num(10.0)), make_lit(mk_num(0.0)) }));
		Value v = eval_value(prog);
		assert(v.type == NUMBER);
		assert(v.num_val == 55.0);
	};
}

fn void test_array_lit_and_index() @test
{
	@pool() {
		AstNode* prog = make_get(
			make_array({ make_lit(mk_num(10.0)), make_lit(mk_num(20.0)), make_lit(mk_num(30.0)) }),
			make_lit(mk_num(1.0)));
		Value v = eval_value(prog);
		assert(v.type == NUMBER);
		assert(v.num_val == 20.0);
	};
}

fn void test_array_push() @test
{
	@pool() {
		// let a = [1,2,3]; len(a)  =>  3
		AstNode* arr = make_array({ make_lit(mk_num(1.0)), make_lit(mk_num(2.0)), make_lit(mk_num(3.0)) });
		AstNode* len_call = make_call(make_prim_node("len"), { make_var("a") });
		AstNode* prog = make_let("a", arr, len_call);
		Value v = eval_value(prog);
		assert(v.type == NUMBER);
		assert(v.num_val == 3.0);
	};
}

fn void test_record_lit_and_get() @test
{
	@pool() {
		AstNode* prog = make_get(
			make_record({ "x", "y" }, { make_lit(mk_num(3.0)), make_lit(mk_num(4.0)) }),
			make_lit(mk_str("y")));
		Value v = eval_value(prog);
		assert(v.type == NUMBER);
		assert(v.num_val == 4.0);
	};
}

fn void test_set_returns_value() @test
{
	@pool() {
		AstNode* prog = make_let("r",
			make_record({ "x" }, { make_lit(mk_num(0.0)) }),
			make_set(make_var("r"), make_lit(mk_str("x")), make_lit(mk_num(7.0))));
		Value v = eval_value(prog);
		assert(v.type == NUMBER);
		assert(v.num_val == 7.0);
	};
}

fn void test_set_mutates_record() @test
{
	@pool() {
		// let r = {x: 0}; r.x = 7; r.x  =>  7
		AstNode* set_step = make_set(make_var("r"), make_lit(mk_str("x")), make_lit(mk_num(7.0)));
		AstNode* prog = make_let("r",
			make_record({ "x" }, { make_lit(mk_num(0.0)) }),
			make_let("_", set_step, make_get(make_var("r"), make_lit(mk_str("x")))));
		Value v = eval_value(prog);
		assert(v.type == NUMBER);
		assert(v.num_val == 7.0);
	};
}

fn void test_throw_try() @test
{
	@pool() {
		AstNode* prog = make_try(
			make_throw(make_lit(mk_str("boom"))),
			"e",
			make_var("e"));
		Value v = eval_value(prog);
		assert(v.type == STRING);
		assert(v.str_val == "boom");
	};
}

fn void test_throw_try_concat() @test
{
	@pool() {
		// try (throw "boom") catch e { "caught: " + e }   =>  "caught: boom"
		AstNode* prog = make_try(
			make_throw(make_lit(mk_str("boom"))),
			"e",
			make_binop("+", make_lit(mk_str("caught: ")), make_var("e")));
		Value v = eval_value(prog);
		assert(v.type == STRING);
		assert(v.str_val == "caught: boom");
	};
}

fn void test_if_branches() @test
{
	@pool() {
		AstNode* a = make_if(make_lit(mk_bool(true)), make_lit(mk_num(1.0)), make_lit(mk_num(2.0)));
		assert(eval_value(a).num_val == 1.0);
		AstNode* b = make_if(make_lit(mk_bool(false)), make_lit(mk_num(1.0)), make_lit(mk_num(2.0)));
		assert(eval_value(b).num_val == 2.0);
		// 0 is truthy (Lua-style)
		AstNode* c = make_if(make_lit(mk_num(0.0)), make_lit(mk_num(1.0)), make_lit(mk_num(2.0)));
		assert(eval_value(c).num_val == 1.0);
	};
}

fn void test_prim_is() @test
{
	@pool() {
		AstNode* p1 = make_call(make_prim_node("is_number"), { make_lit(mk_num(1.0)) });
		assert(eval_value(p1).bool_val);
		AstNode* p2 = make_call(make_prim_node("is_string"), { make_lit(mk_num(1.0)) });
		assert(!eval_value(p2).bool_val);
	};
}

fn void test_string_concat() @test
{
	@pool() {
		AstNode* prog = make_binop("+", make_lit(mk_str("foo")), make_lit(mk_str("bar")));
		Value v = eval_value(prog);
		assert(v.type == STRING);
		assert(v.str_val == "foobar");
	};
}

fn void test_prim_len_string() @test
{
	@pool() {
		AstNode* prog = make_call(make_prim_node("len"), { make_lit(mk_str("hello")) });
		assert(eval_value(prog).num_val == 5.0);
	};
}

fn void test_prim_len_array() @test
{
	@pool() {
		AstNode* arr = make_array({ make_lit(mk_num(1.0)), make_lit(mk_num(2.0)), make_lit(mk_num(3.0)) });
		AstNode* prog = make_call(make_prim_node("len"), { arr });
		assert(eval_value(prog).num_val == 3.0);
	};
}

// ============================================================================
// SURFACE (desugarer) tests — build-order step 3: MethodCall + Seq + BinOp
// ============================================================================

fn void test_surface_binop() @test
{
	@pool() {
		// 3 + 4 * 2   (surface BinOp, not pre-desugared Call)
		AstNode* prog = make_binop_node("+",
			make_lit(mk_num(3.0)),
			make_binop_node("*", make_lit(mk_num(4.0)), make_lit(mk_num(2.0))));
		Value v = eval_surface(prog);
		assert(v.type == NUMBER);
		assert(v.num_val == 11.0);
	};
}

fn void test_surface_seq() @test
{
	@pool() {
		// 1; 2; 3   =>  3
		AstNode* prog = make_seq({
			make_lit(mk_num(1.0)),
			make_lit(mk_num(2.0)),
			make_lit(mk_num(3.0)),
		});
		Value v = eval_surface(prog);
		assert(v.type == NUMBER);
		assert(v.num_val == 3.0);
	};
}

fn void test_surface_methodcall_counter() @test
{
	@pool() {
		// let counter = { count: 0,
		//                 inc: fn(self, n) { self.count = self.count + n } };
		// counter.inc(5); counter.inc(10); counter.count    =>  15
		AstNode* inc_fn = make_lambda({ "self", "n" },
			make_set(make_var("self"), make_lit(mk_str("count")),
				make_binop_node("+",
					make_get(make_var("self"), make_lit(mk_str("count"))),
					make_var("n"))));
		AstNode* counter_init = make_record({ "count", "inc" },
			{ make_lit(mk_num(0.0)), inc_fn });
		AstNode* stmt1 = make_methodcall(make_var("counter"), "inc", { make_lit(mk_num(5.0)) });
		AstNode* stmt2 = make_methodcall(make_var("counter"), "inc", { make_lit(mk_num(10.0)) });
		AstNode* final = make_get(make_var("counter"), make_lit(mk_str("count")));
		AstNode* body = make_seq({ stmt1, stmt2, final });
		AstNode* prog = make_letrec("counter", counter_init, body);
		Value v = eval_surface(prog);
		assert(v.type == NUMBER);
		assert(v.num_val == 15.0);
	};
}

fn void test_surface_methodcall_receiver_once() @test
{
	@pool() {
		// r = { hits: 0, bump: fn(self) { self.hits = self.hits + 1; self.hits } };
		// r.bump(); r.bump()   =>  2  (each call evaluates the receiver exactly once)
		AstNode* bump_fn = make_lambda({ "self" },
			make_seq({
				make_set(make_var("self"), make_lit(mk_str("hits")),
					make_binop_node("+",
						make_get(make_var("self"), make_lit(mk_str("hits"))),
						make_lit(mk_num(1.0)))),
				make_get(make_var("self"), make_lit(mk_str("hits"))),
			}));
		AstNode* r_init = make_record({ "hits", "bump" },
			{ make_lit(mk_num(0.0)), bump_fn });
		AstNode* b1 = make_methodcall(make_var("r"), "bump", {});
		AstNode* b2 = make_methodcall(make_var("r"), "bump", {});
		AstNode* prog = make_letrec("r", r_init, make_seq({ b1, b2 }));
		Value v = eval_surface(prog);
		assert(v.type == NUMBER);
		assert(v.num_val == 2.0);
	};
}
