module engine;
import std::io;

// Tests for the element (JSX-like) syntax.  Elements are sugar for a
// function call: `<Tag attrs />` and `<Tag>children</Tag>` desugar to
// `Tag({...attrs}, child1, child2, ...)`.  The tag is just the name of a
// function in scope.
// 
// We exercise:
//   - self-closing with attributes
//   - attribute values that are strings, numbers, bools, idents
//   - elements with children
//   - postfix on the element result (e.g. `<Foo />.field`)
//   - nesting: <Outer>...<Inner />...</Outer>
//   - elements in larger expressions (calls, records, arrays)

fn void test_element_self_closing() @test {
    // let make = fn(attrs) { attrs }
    // <make x=1 />  =>  make({x: 1})  =>  {x: 1}
    Value v = run_parsed("let make = fn(attrs) { attrs }; <make x=1 />");
    assert(is_rec(v));
}

fn void test_element_attrs_string() @test {
    Value v = run_parsed("let make = fn(attrs) { attrs }; <make name=\"Alice\" />");
    assert(is_rec(v));
}

fn void test_element_attrs_number() @test {
    Value v = run_parsed("let make = fn(attrs) { attrs }; <make age=30 />");
    assert(is_rec(v));
}

fn void test_element_attrs_bool() @test {
    Value v = run_parsed("let make = fn(attrs) { attrs }; <make active=true />");
    assert(is_rec(v));
}

fn void test_element_attrs_ident() @test {
    // Ident attribute values become Var references.
    Value v = run_parsed("let x = 42; let make = fn(attrs) { attrs }; <make v=x />");
    assert(is_rec(v));
}

fn void test_element_with_children() @test {
    // <wrap>a, b, c</wrap>  =>  wrap({}, [a, b, c])
    Value v = run_parsed("let wrap = fn(_attrs, kids) { kids }; <wrap>10, 20, 30</wrap>");
    assert(is_arr(v));
}

fn void test_element_no_children_self_close() @test {
    // <tag />  =>  tag({})
    Value v = run_parsed("let tag = fn(_attrs) { 7 }; <tag />");
    assert(is_num(v));
    assert(as_num(v) == 7.0);
}

fn void test_element_postfix() @test {
    // <user name="A" />.name  =>  user({name: "A"}).name  =>  "A"
    Value v = run_parsed("let user = fn(attrs) { attrs }; <user name=\"A\" />.name");
    assert(is_str(v));
    assert(*as_str(v) == "A");
}

fn void test_element_nested() @test {
    // <outer><inner /></outer>
    //   =>  outer({}, [inner({})])
    // outer is fn(_attrs, kids) { kids[0] + 1 }
    // inner is fn(_attrs) { 41 }
    // => outer({}, [41]) = 42
    String src = "let inner = fn(_a) { 41 }; let outer = fn(_a, kids) { kids[0] + 1 }; <outer><inner /></outer>";
    Value v    = run_parsed(src);
    assert(is_num(v));
    assert(as_num(v) == 42.0);
}

fn void test_element_does_not_clobber_comparison() @test {
    // `<` as a comparison must still work.
    Value v = run_parsed("1 < 2");
    assert(is_bool(v));
    assert(as_bool(v));
}

fn void test_element_does_not_clobber_arrow_or_le() @test {
    // `<=` (less-or-equal) must still work; the parser's element check
    // looks at the next token, which here is a number, not an ident.
    Value v = run_parsed("3 <= 4");
    assert(is_bool(v));
    assert(as_bool(v));
}

fn void test_element_in_array() @test {
    Value v = run_parsed("let m = fn(a) { a }; [<m x=1 />, <m y=2 />]");
    assert(is_arr(v));
}

fn void test_element_in_call_arg() @test {
    // Pass the result of an element as an argument to a function.
    String src = "let m = fn(a) { a }; let id = fn(x) { x }; id(<m v=99 />)";
    Value v    = run_parsed(src);
    assert(is_rec(v));
}

fn void test_element_children_whitespace_separated() @test {
    // Children can be separated by whitespace (no commas needed).
    Value v = run_parsed("let wrap = fn(_attrs, kids) { kids }; <wrap>10 20 30</wrap>");
    assert(is_arr(v));
}