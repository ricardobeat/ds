module engine;
import std::io;

// Helpers
fn AstNode* make_binop(String op, AstNode* lhs, AstNode* rhs) => make_call(make_prim_node(op), { lhs, rhs });

fn AstNode* make_let(String name, AstNode* init, AstNode* body) => make_letrec(name, init, body);

fn Value eval_value(AstNode* node) {
    EvalResult r = eval(node, null);
    assert(!r.thrown, "test program threw");
    return r.value;
}

fn Value eval_surface(AstNode* node) {
    AstNode* k   = desugar(node, null);
    EvalResult r = eval(k, null);
    assert(!r.thrown, "desugared program threw");
    return r.value;
}

// ============================================================================
// TESTS — port of reference/test.py sections 1, 2, 3, 5, 7.
// Sections 4, 6, 8 need the desugarer (build-order steps 3-5).
// ============================================================================

fn void test_lit_num() @test {
    @pool() {
        Value v = eval_value(make_lit(mk_num(42.0)));
        assert(is_num(v));
        assert(as_num(v) == 42.0);
    };
}

fn void test_lit_str() @test {
    @pool() {
        Value v = eval_value(make_lit(mk_str("hi")));
        assert(is_str(v));
        assert(*as_str(v) == "hi");
    };
}

fn void test_arith() @test {
    @pool() {
        AstNode* prog = make_binop(
            "+",
            make_lit(mk_num(3.0)),
            make_binop("*", make_lit(mk_num(4.0)), make_lit(mk_num(2.0)))
        );
        Value v = eval_value(prog);
        assert(is_num(v));
        assert(as_num(v) == 11.0);
    };
}

fn void test_strict_eq() @test {
    @pool() {
        Value a = eval_value(make_binop("===", make_lit(mk_num(3.0)), make_lit(mk_num(3.0))));
        assert(is_bool(a) && as_bool(a));

        Value b = eval_value(make_binop("===", make_lit(mk_num(3.0)), make_lit(mk_str("3"))));
        assert(is_bool(b) && !as_bool(b));
    };
}

fn void test_closure_lexical() @test {
    @pool() {
        AstNode* body  = make_binop("+", make_var("x"), make_var("y"));
        AstNode* inner = make_lambda({ "y" }, body);
        AstNode* outer = make_lambda({ "x" }, inner);
        AstNode* add   = make_var("add");
        AstNode* add10 = make_call(add, { make_lit(mk_num(10.0)) });
        AstNode* whole = make_let("add", outer, make_call(add10, { make_lit(mk_num(5.0)) }));
        io::printn("about to eval");
        EvalResult r = eval(whole, null);
        io::printfn("closure_lexical: thrown=%d type=%d num=%f", r.thrown, tag_of(r.value).ordinal, as_num(r.value));
        assert(!r.thrown);
        assert(is_num(r.value));
        assert(as_num(r.value) == 15.0);
    };
}

fn void test_let_simple() @test {
    @pool() {
        // let x = 42; x  =>  42
        AstNode* prog = make_let("x", make_lit(mk_num(42.0)), make_var("x"));
        Value v       = eval_value(prog);
        assert(is_num(v));
        assert(as_num(v) == 42.0);
    };
}

fn void test_let_lambda() @test {
    @pool() {
        // let id = fn(x) { x }; id(99)  =>  99
        AstNode* id_fn = make_lambda({ "x" }, make_var("x"));
        AstNode* prog  = make_let("id", id_fn, make_call(make_var("id"), { make_lit(mk_num(99.0)) }));
        Value v        = eval_value(prog);
        assert(is_num(v));
        assert(as_num(v) == 99.0);
    };
}

fn void test_recursion_sum() @test {
    @pool() {
        AstNode* sum_body = make_if(
            make_binop("===", make_var("n"), make_lit(mk_num(0.0))),
            make_var("acc"),
            make_call(
                make_var("sum"),
                {
                    make_binop("-", make_var("n"), make_lit(mk_num(1.0))),
                    make_binop("+", make_var("acc"), make_var("n")),
                }
            )
        );
        AstNode* sum_fn = make_lambda({ "n", "acc" }, sum_body);
        AstNode* prog = make_let(
            "sum",
            sum_fn,
            make_call(make_var("sum"), { make_lit(mk_num(10.0)), make_lit(mk_num(0.0)) })
        );
        Value v = eval_value(prog);
        assert(is_num(v));
        assert(as_num(v) == 55.0);
    };
}

fn void test_array_lit_and_index() @test {
    @pool() {
        AstNode* prog = make_get(
            make_array({ make_lit(mk_num(10.0)), make_lit(mk_num(20.0)), make_lit(mk_num(30.0)) }),
            make_lit(mk_num(1.0))
        );
        Value v = eval_value(prog);
        assert(is_num(v));
        assert(as_num(v) == 20.0);
    };
}

fn void test_array_push() @test {
    @pool() {
        // let a = [1,2,3]; len(a)  =>  3
        AstNode* arr      = make_array({ make_lit(mk_num(1.0)), make_lit(mk_num(2.0)), make_lit(mk_num(3.0)) });
        AstNode* len_call = make_call(make_prim_node("len"), { make_var("a") });
        AstNode* prog     = make_let("a", arr, len_call);
        Value v           = eval_value(prog);
        assert(is_num(v));
        assert(as_num(v) == 3.0);
    };
}

fn void test_record_lit_and_get() @test {
    @pool() {
        AstNode* prog = make_get(
            make_record({ "x", "y" }, { make_lit(mk_num(3.0)), make_lit(mk_num(4.0)) }),
            make_lit(mk_str("y"))
        );
        Value v = eval_value(prog);
        assert(is_num(v));
        assert(as_num(v) == 4.0);
    };
}

fn void test_set_returns_value() @test {
    @pool() {
        AstNode* prog = make_let(
            "r",
            make_record({ "x" }, { make_lit(mk_num(0.0)) }),
            make_set(make_var("r"), make_lit(mk_str("x")), make_lit(mk_num(7.0)))
        );
        Value v = eval_value(prog);
        assert(is_num(v));
        assert(as_num(v) == 7.0);
    };
}

fn void test_set_mutates_record() @test {
    @pool() {
        // let r = {x: 0}; r.x = 7; r.x  =>  7
        AstNode* set_step = make_set(make_var("r"), make_lit(mk_str("x")), make_lit(mk_num(7.0)));
        AstNode* prog = make_let(
            "r",
            make_record({ "x" }, { make_lit(mk_num(0.0)) }),
            make_let("_", set_step, make_get(make_var("r"), make_lit(mk_str("x"))))
        );
        Value v = eval_value(prog);
        assert(is_num(v));
        assert(as_num(v) == 7.0);
    };
}

fn void test_throw_try() @test {
    @pool() {
        AstNode* prog = make_try(make_throw(make_lit(mk_str("boom"))), "e", make_var("e"));
        Value v       = eval_value(prog);
        assert(is_str(v));
        assert(*as_str(v) == "boom");
    };
}

fn void test_throw_try_concat() @test {
    @pool() {
        // try (throw "boom") catch e { "caught: " + e }   =>  "caught: boom"
        AstNode* prog = make_try(
            make_throw(make_lit(mk_str("boom"))),
            "e",
            make_binop("+", make_lit(mk_str("caught: ")), make_var("e"))
        );
        Value v = eval_value(prog);
        assert(is_str(v));
        assert(*as_str(v) == "caught: boom");
    };
}

fn void test_if_branches() @test {
    @pool() {
        AstNode* a = make_if(make_lit(mk_bool(true)), make_lit(mk_num(1.0)), make_lit(mk_num(2.0)));
        assert(as_num(eval_value(a)) == 1.0);
        AstNode* b = make_if(make_lit(mk_bool(false)), make_lit(mk_num(1.0)), make_lit(mk_num(2.0)));
        assert(as_num(eval_value(b)) == 2.0);
        // 0 is truthy (Lua-style)
        AstNode* c = make_if(make_lit(mk_num(0.0)), make_lit(mk_num(1.0)), make_lit(mk_num(2.0)));
        assert(as_num(eval_value(c)) == 1.0);
    };
}

fn void test_prim_is() @test {
    @pool() {
        AstNode* p1 = make_call(make_prim_node("is_number"), { make_lit(mk_num(1.0)) });
        assert(as_bool(eval_value(p1)));
        AstNode* p2 = make_call(make_prim_node("is_string"), { make_lit(mk_num(1.0)) });
        assert(!as_bool(eval_value(p2)));
    };
}

fn void test_string_concat() @test {
    @pool() {
        AstNode* prog = make_binop("+", make_lit(mk_str("foo")), make_lit(mk_str("bar")));
        Value v       = eval_value(prog);
        assert(is_str(v));
        assert(*as_str(v) == "foobar");
    };
}

fn void test_prim_len_string() @test {
    @pool() {
        AstNode* prog = make_call(make_prim_node("len"), { make_lit(mk_str("hello")) });
        assert(as_num(eval_value(prog)) == 5.0);
    };
}

fn void test_prim_len_array() @test {
    @pool() {
        AstNode* arr  = make_array({ make_lit(mk_num(1.0)), make_lit(mk_num(2.0)), make_lit(mk_num(3.0)) });
        AstNode* prog = make_call(make_prim_node("len"), { arr });
        assert(as_num(eval_value(prog)) == 3.0);
    };
}

// ============================================================================
// SURFACE (desugarer) tests — build-order step 3: MethodCall + Seq + BinOp
// ============================================================================

fn void test_surface_binop() @test {
    @pool() {
        // 3 + 4 * 2   (surface BinOp, not pre-desugared Call)
        AstNode* prog = make_binop_node(
            "+",
            make_lit(mk_num(3.0)),
            make_binop_node("*", make_lit(mk_num(4.0)), make_lit(mk_num(2.0)))
        );
        Value v = eval_surface(prog);
        assert(is_num(v));
        assert(as_num(v) == 11.0);
    };
}

fn void test_surface_seq() @test {
    @pool() {
        // 1; 2; 3   =>  3
        AstNode* prog = make_seq({ make_lit(mk_num(1.0)), make_lit(mk_num(2.0)), make_lit(mk_num(3.0)), });
        Value v       = eval_surface(prog);
        assert(is_num(v));
        assert(as_num(v) == 3.0);
    };
}

fn void test_surface_methodcall_counter() @test {
    @pool() {
        // let counter = { count: 0,
        //                 inc: fn(self, n) { self.count = self.count + n } };
        // counter.inc(5); counter.inc(10); counter.count    =>  15
        AstNode* inc_fn = make_lambda(
            { "self", "n" },
            make_set(
                make_var("self"),
                make_lit(mk_str("count")),
                make_binop_node("+", make_get(make_var("self"), make_lit(mk_str("count"))), make_var("n"))
            )
        );
        AstNode* counter_init = make_record({ "count", "inc" }, { make_lit(mk_num(0.0)), inc_fn });
        AstNode* stmt1        = make_methodcall(make_var("counter"), "inc", { make_lit(mk_num(5.0)) });
        AstNode* stmt2        = make_methodcall(make_var("counter"), "inc", { make_lit(mk_num(10.0)) });
        AstNode* final        = make_get(make_var("counter"), make_lit(mk_str("count")));
        AstNode* body         = make_seq({ stmt1, stmt2, final });
        AstNode* prog         = make_letrec("counter", counter_init, body);
        Value v               = eval_surface(prog);
        assert(is_num(v));
        assert(as_num(v) == 15.0);
    };
}

fn void test_surface_methodcall_receiver_once() @test {
    @pool() {
        // r = { hits: 0, bump: fn(self) { self.hits = self.hits + 1; self.hits } };
        // r.bump(); r.bump()   =>  2  (each call evaluates the receiver exactly once)
        AstNode* bump_fn = make_lambda(
            { "self" },
            make_seq(
                {
                    make_set(
                        make_var("self"),
                        make_lit(mk_str("hits")),
                        make_binop_node(
                            "+",
                            make_get(make_var("self"), make_lit(mk_str("hits"))),
                            make_lit(mk_num(1.0))
                        )
                    ),
                    make_get(make_var("self"), make_lit(mk_str("hits"))),
                }
            )
        );
        AstNode* r_init = make_record({ "hits", "bump" }, { make_lit(mk_num(0.0)), bump_fn });
        AstNode* b1     = make_methodcall(make_var("r"), "bump", { });
        AstNode* b2     = make_methodcall(make_var("r"), "bump", { });
        AstNode* prog   = make_letrec("r", r_init, make_seq({ b1, b2 }));
        Value v         = eval_surface(prog);
        assert(is_num(v));
        assert(as_num(v) == 2.0);
    };
}

// ============================================================================
// SAMPLE: a "JS but not JS" program — records with method fields, method
// calls, string concatenation, and a higher-order greet function.  This
// sample is a plausible slice of real-world usage.
// ============================================================================

fn void test_sample_greet_both() @test {
    @pool() {
        // let alice = { name: "Alice",
        //               greet: fn(self) { "hi, I'm " + self.name } };
        // let bob   = { name: "Bob",
        //               greet: fn(self) { "hi, I'm " + self.name } };
        // let greetBoth = fn(a, b) { a.greet() + " and " + b.greet() };
        // greetBoth(alice, bob)   =>  "hi, I'm Alice and hi, I'm Bob"
        AstNode* greet_fn = make_lambda(
            { "self" },
            make_binop_node("+", make_lit(mk_str("hi, I'm ")), make_get(make_var("self"), make_lit(mk_str("name"))))
        );
        AstNode* alice = make_record({ "name", "greet" }, { make_lit(mk_str("Alice")), greet_fn });
        AstNode* bob   = make_record({ "name", "greet" }, { make_lit(mk_str("Bob")), greet_fn });
        AstNode* greet_both = make_lambda(
            { "a", "b" },
            make_binop_node(
                "+",
                make_binop_node("+", make_methodcall(make_var("a"), "greet", { }), make_lit(mk_str(" and "))),
                make_methodcall(make_var("b"), "greet", { })
            )
        );
        AstNode* prog = make_letrec(
            "alice",
            alice,
            make_letrec(
                "bob",
                bob,
                make_letrec(
                    "greetBoth",
                    greet_both,
                    make_call(make_var("greetBoth"), { make_var("alice"), make_var("bob") })
                )
            )
        );
        Value v = eval_surface(prog);
        assert(is_str(v));
        assert(*as_str(v) == "hi, I'm Alice and hi, I'm Bob");
    };
}

// ============================================================================
// RUNG 1 / RUNG 2 surface tests
//   Section 5/5b: typed function, good + bad call
//   Section 6/6b: sum type + match
//   Section 8: typed record check
// ============================================================================
// (Surface constructors `make_typed_lambda`, `make_typed_let`, `make_typedef`,
//  `make_construct`, `make_match` live in src/main.c3 so the parser can use
//  them too.)

fn void test_rung1_typed_function_good() @test {
    @pool() {
        // let add = fn(x: Int, y: Int): Int { x + y }; add(3, 4)  =>  7
        Type* int_t = mem::tnew(Type);
        *int_t = mk_tname("Int");
        AstNode* body = make_binop_node("+", make_var("x"), make_var("y"));
        Type*[] pts   = mem::talloc_array(Type*, 2);
        pts[0] = int_t;
        pts[1] = int_t;
        AstNode* add_fn = make_typed_lambda({ "x", "y" }, pts, int_t, body);
        AstNode* prog = make_typed_let(
            "add",
            null,
            add_fn,
            make_call(make_var("add"), { make_lit(mk_num(3.0)), make_lit(mk_num(4.0)) })
        );
        Value v = eval_surface(prog);
        assert(is_num(v));
        assert(as_num(v) == 7.0);
    };
}

fn void test_rung1_typed_function_bad() @test {
    @pool() {
        // add(3, "oops")  -> thrown
        Type* int_t = mem::tnew(Type);
        *int_t = mk_tname("Int");
        AstNode* body = make_binop_node("+", make_var("x"), make_var("y"));
        Type*[] pts   = mem::talloc_array(Type*, 2);
        pts[0] = int_t;
        pts[1] = int_t;
        AstNode* add_fn = make_typed_lambda({ "x", "y" }, pts, int_t, body);
        AstNode* prog = make_typed_let(
            "add",
            null,
            add_fn,
            make_call(make_var("add"), { make_lit(mk_num(3.0)), make_lit(mk_str("oops")) })
        );
        // Should throw at the boundary.
        AstNode* k   = desugar(prog, null);
        EvalResult r = eval(k, null);
        assert(r.thrown, "expected type error to throw");
    };
}

fn void test_rung1_typed_record_good() @test {
    @pool() {
        // fn(p: {x:Int, y:Int}): Int { p.x + p.y }; f({x:3, y:4})  =>  7
        Type* int_t = mem::tnew(Type);
        *int_t = mk_tname("Int");
        Type pt    = mk_trecord({ "x", "y" }, { *int_t, *int_t });
        Type* pt_p = mem::tnew(Type);
        *pt_p = pt;
        AstNode* body = make_binop_node(
            "+",
            make_get(make_var("p"), make_lit(mk_str("x"))),
            make_get(make_var("p"), make_lit(mk_str("y")))
        );
        Type*[] pts = mem::talloc_array(Type*, 1);
        pts[0] = pt_p;
        AstNode* f    = make_typed_lambda({ "p" }, pts, int_t, body);
        AstNode* arg  = make_record({ "x", "y" }, { make_lit(mk_num(3.0)), make_lit(mk_num(4.0)) });
        AstNode* prog = make_typed_let("f", null, f, make_call(make_var("f"), { arg }));
        Value v       = eval_surface(prog);
        assert(is_num(v));
        assert(as_num(v) == 7.0);
    };
}

fn void test_rung1_typed_record_missing() @test {
    @pool() {
        // fn(p: {x:Int, y:Int}): Int { p.x + p.y }; f({x:3})  => throws
        Type* int_t = mem::tnew(Type);
        *int_t = mk_tname("Int");
        Type pt    = mk_trecord({ "x", "y" }, { *int_t, *int_t });
        Type* pt_p = mem::tnew(Type);
        *pt_p = pt;
        AstNode* body = make_binop_node(
            "+",
            make_get(make_var("p"), make_lit(mk_str("x"))),
            make_get(make_var("p"), make_lit(mk_str("y")))
        );
        Type*[] pts = mem::talloc_array(Type*, 1);
        pts[0] = pt_p;
        AstNode* f    = make_typed_lambda({ "p" }, pts, int_t, body);
        AstNode* arg  = make_record({ "x" }, { make_lit(mk_num(3.0)) });
        AstNode* prog = make_typed_let("f", null, f, make_call(make_var("f"), { arg }));
        AstNode* k    = desugar(prog, null);
        EvalResult r  = eval(k, null);
        assert(r.thrown, "expected type error to throw");
    };
}

fn void test_rung2_sum_match() @test {
    @pool() {
        // type Shape = Circle({radius:Int}) | Rectangle({w:Int,h:Int})
        // area = fn(sh) { match sh { Circle(c) => 3*c.radius*c.radius
        //                          Rectangle(r) => r.w * r.h } }
        // area(Circle({radius:10})) + area(Rectangle({w:4, h:5}))  =>  320
        Type* int_t = mem::tnew(Type);
        *int_t = mk_tname("Int");
        AstNode* area = make_lambda(
            { "sh" },
            make_match(
                make_var("sh"),
                { "Circle", "Rectangle" },
                { "c", "r" },
                {
                    make_binop_node(
                        "*",
                        make_binop_node(
                            "*",
                            make_lit(mk_num(3.0)),
                            make_get(make_var("c"), make_lit(mk_str("radius")))
                        ),
                        make_get(make_var("c"), make_lit(mk_str("radius")))
                    ),
                    make_binop_node(
                        "*",
                        make_get(make_var("r"), make_lit(mk_str("w"))),
                        make_get(make_var("r"), make_lit(mk_str("h")))
                    ),
                }
            )
        );
        AstNode* c1 = make_call(
            make_var("area"),
            { make_construct("Circle", make_record({ "radius" }, { make_lit(mk_num(10.0)) })) }
        );
        AstNode* c2 = make_call(
            make_var("area"),
            { make_construct("Rectangle", make_record({ "w", "h" }, { make_lit(mk_num(4.0)), make_lit(mk_num(5.0)) })) }
        );
        AstNode* prog = make_typed_let("area", null, area, make_binop_node("+", c1, c2));
        Value v       = eval_surface(prog);
        assert(is_num(v));
        assert(as_num(v) == 320.0);
    };
}

fn void test_rung2_match_non_exhaustive() @test {
    @pool() {
        // Same area function as above, but call with a Triangle -> throws
        Type* int_t = mem::tnew(Type);
        *int_t = mk_tname("Int");
        AstNode* area = make_lambda(
            { "sh" },
            make_match(
                make_var("sh"),
                { "Circle", "Rectangle" },
                { "c", "r" },
                { make_lit(mk_num(1.0)), make_lit(mk_num(1.0)), }
            )
        );
        AstNode* prog = make_typed_let(
            "area",
            null,
            area,
            make_call(
                make_var("area"),
                { make_construct("Triangle", make_record({ "base" }, { make_lit(mk_num(2.0)) })) }
            )
        );
        AstNode* k   = desugar(prog, null);
        EvalResult r = eval(k, null);
        assert(r.thrown, "expected non-exhaustive match to throw");
    };
}

// ============================================================================
// INTERN TABLE / ATOM-BASED RECORD KEY TESTS (Step 2 of compiler plan)
// ============================================================================

fn void test_intern_returns_same_id() @test {
    uint a = intern("foo");
    uint b = intern("foo");
    uint c = intern("bar");
    assert(a != 0);
    assert(a == b, "same string should intern to same atom");
    assert(a != c, "different strings should intern to different atoms");
}

fn void test_intern_dense_ids() @test {
    uint x = intern("__test_dense_1");
    uint y = intern("__test_dense_2");
    uint z = intern("__test_dense_3");
    assert(x + 1 == y, "atoms should be densely allocated");
    assert(y + 1 == z, "atoms should be densely allocated");
}

fn void test_atom_name_round_trip() @test {
    String s    = "round_trip_atom";
    uint id     = intern(s);
    String back = atom_name(id);
    assert(back == s, "atom_name should return the original string");
}

fn void test_record_keys_are_atoms() @test {
    @pool() {
        // Construct a record and verify the keys array now holds atom IDs
        // (uints), not Strings.  Same field name should intern to the same atom
        // when looked up.
        AstNode* prog = make_record({ "x" }, { make_lit(mk_num(7.0)) });
        EvalResult r  = eval(prog, null);
        assert(!r.thrown);
        assert(is_rec(r.value));
        Record* rec = as_rec(r.value);
        assert(rec.keys.len == 1);
        assert(rec.keys[0] == intern("x"));
    };
}

fn void test_record_get_via_intern() @test {
    @pool() {
        // Even when the key is a fresh string (built at runtime), the GET
        // path intern()s it before scanning the atom table.  The original
        // field was interned at RECORD construction; the GET atom should
        // match.
        AstNode* built  = make_record({ "alpha" }, { make_lit(mk_num(1.0)) });
        AstNode* get_it = make_get(built, make_lit(mk_str("alpha")));
        Value v         = eval_value(get_it);
        assert(is_num(v));
        assert(as_num(v) == 1.0);
    };
}

fn void test_record_get_unknown_field_throws() @test {
    @pool() {
        AstNode* built  = make_record({ "x" }, { make_lit(mk_num(0.0)) });
        AstNode* get_it = make_get(built, make_lit(mk_str("nope")));
        EvalResult r    = eval(get_it, null);
        assert(r.thrown);
    };
}

fn void test_record_set_appends_new_atom() @test {
    @pool() {
        // Setting a brand-new key must intern it and append the atom to the
        // record's key array.  The record is mutated in place; the GET
        // afterwards (via the env-bound name `r`) finds the new key.
        // We use `make_var("r")` rather than the RECORD AST node directly
        // so the mutation persists across the let-binding — re-evaluating
        // the RECORD node would create a fresh record from `node.names`.
        AstNode* r_init = make_record({ "x" }, { make_lit(mk_num(0.0)) });
        AstNode* set_it = make_set(make_var("r"), make_lit(mk_str("y")), make_lit(mk_num(9.0)));
        AstNode* get_it = make_get(make_var("r"), make_lit(mk_str("y")));
        AstNode* prog   = make_let("r", r_init, make_let("_", set_it, get_it));
        Value v         = eval_value(prog);
        assert(is_num(v));
        assert(as_num(v) == 9.0);
    };
}