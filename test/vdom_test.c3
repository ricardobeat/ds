module engine;
import std::io;

// A more substantial element-syntax test: build and render a small
// virtual DOM.  Exercises the element call desugaring, the new
// `slice` primitive (`xs[1..]`), the builtin env, and string concat.

fn void test_vdom_renders() @test {
    String src = `let h = fn(attrs, kids) { { name: attrs.name, attrs: attrs, kids: kids } };
let join = fn(rend, xs) {
  if len(xs) === 0 then ""
  else rend(xs[0]) + join(rend, xs[1..])
};
let render = fn(v) {
  if v.name === "text" then v.kids[0]
  else "<" + v.name + ">" + join(render, v.kids) + "</" + v.name + ">"
};
let page = <h name="div" class="container">
  <h name="h1"><h name="text">"Hello, vdom!"</h></h>,
  <h name="p"><h name="text">"A paragraph."</h></h>
</h>;
render(page)`;
    Value v = run_parsed(src);
    assert(is_str(v));
    assert(*as_str(v) == "<div><h1>Hello, vdom!</h1><p>A paragraph.</p></div>");
}

fn void test_vdom_text_node() @test {
    String src = `let wrap = fn(x) { if is_array(x) then x else [x] };
let h = fn(attrs, kids) { { name: attrs.name, attrs: attrs, kids: wrap(kids) } };
let render = fn(v) { if v.name === "text" then v.kids[0] else v.kids[0] };
render(<h name="text">"hi"</h>)`;
    Value v = run_parsed(src);
    assert(is_str(v));
    assert(*as_str(v) == "hi");
}

fn void test_builtin_len() @test {
    Value v = run_parsed("len([1, 2, 3])");
    assert(is_num(v));
    assert(as_num(v) == 3.0);
}

fn void test_builtin_slice() @test {
    Value v = run_parsed("[10, 20, 30, 40, 50][2..]");
    assert(is_arr(v));
}

fn void test_builtin_slice_open() @test {
    Value v = run_parsed("[10, 20, 30][1..][0]");
    assert(is_num(v));
    assert(as_num(v) == 20.0);
}