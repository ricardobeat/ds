"""Exercise the engine. Programs are written directly in the surface AST."""
from engine import (run, num, s, var, _show, LangThrow)

def banner(t): print("\n" + "=" * 4 + " " + t + " " + "=" * (50 - len(t)))

# ---------------------------------------------------------------------------
banner("1. closures + lexical scope")
# let add = fn(x) { fn(y) { x + y } };  (add(10))(5)   => 15
prog = ("Let", "add", None,
        ("Lambda", [("x", None)], None,
         ("Lambda", [("y", None)], None,
          ("BinOp", "+", var("x"), var("y")))),
        ("Call", ("Call", var("add"), [num(10)]), [num(5)]))
print("(add(10))(5) =", _show(run(prog)))

# ---------------------------------------------------------------------------
banner("2. recursion as iteration (sum 1..n)")
# let sum = fn(n, acc) { if n === 0 then acc else sum(n-1, acc+n) }; sum(100,0)
prog = ("Let", "sum", None,
        ("Lambda", [("n", None), ("acc", None)], None,
         ("If", ("BinOp", "===", var("n"), num(0)),
                var("acc"),
                ("Call", var("sum"),
                 [("BinOp", "-", var("n"), num(1)),
                  ("BinOp", "+", var("acc"), var("n"))]))),
        ("Call", var("sum"), [num(100), num(0)]))
# NOTE: recursion needs the function to see itself. Our Let binds the lambda
# in the body's env, and the closure captures that same env, so self-reference
# works. (This is the recursion-as-loop story; a real VM uses TAILCALL here.)
print("sum(1..100) =", _show(run(prog)))

# ---------------------------------------------------------------------------
banner("3. arrays (integer keys) + primitives")
# let a = [1,2,3]; push(a, 4); a[0] + a[3]   => 1 + 4 = 5
prog = ("Let", "a", None,
        ("ArrayLit", [num(1), num(2), num(3)]),
        ("Seq", [
            ("Call", ("Prim", "push"), [var("a"), num(4)]),
            ("BinOp", "+",
             ("Get", var("a"), num(0)),
             ("Get", var("a"), num(3)))]))
print("a[0]+a[3] after push =", _show(run(prog)))

# ---------------------------------------------------------------------------
banner("4. explicit-self methods (Go-style receiver)")
# let counter = { count: 0,
#                 inc: fn(self, n) { self.count = self.count + n } };
# counter.inc(5); counter.inc(10); counter.count    => 15
prog = ("Let", "counter", None,
        ("Record", [
            ("count", num(0)),
            ("inc", ("Lambda", [("self", None), ("n", None)], None,
                     ("Set", var("self"), s("count"),
                      ("BinOp", "+",
                       ("Get", var("self"), s("count")), var("n")))))]),
        ("Seq", [
            ("MethodCall", var("counter"), "inc", [num(5)]),
            ("MethodCall", var("counter"), "inc", [num(10)]),
            ("Get", var("counter"), s("count"))]))
print("counter.count after inc(5),inc(10) =", _show(run(prog)))

# ---------------------------------------------------------------------------
banner("5. Rung 1: typed function, good call")
# let add = fn(x: Int, y: Int): Int { x + y }; add(3, 4)  => 7
Int = ("TName", "Int")
typed_add = ("Lambda", [("x", Int), ("y", Int)], Int,
             ("BinOp", "+", var("x"), var("y")))
prog = ("Let", "add", None, typed_add, ("Call", var("add"), [num(3), num(4)]))
print("add(3,4) =", _show(run(prog)))

banner("5b. Rung 1: typed function, BAD call throws at boundary")
# add(3, "oops")  -> type error
prog = ("Let", "add", None, typed_add,
        ("Call", var("add"), [num(3), s("oops")]))
try:
    run(prog)
    print("!! no error (unexpected)")
except LangThrow as ex:
    print("threw as expected:", _show(ex.value))

# ---------------------------------------------------------------------------
banner("6. Rung 2: sum type + match")
# type Shape = Circle({radius:Int}) | Rectangle({w:Int,h:Int})
# let area = fn(sh) { match sh {
#       Circle(c)    => 3 * c.radius * c.radius
#       Rectangle(r) => r.w * r.h } };
# area(Circle({radius:10})) + area(Rectangle({w:4,h:5}))  => 300 + 20 = 320
Shape = ("TSum", [("Circle", ("TName","Any")), ("Rectangle", ("TName","Any"))])
area = ("Lambda", [("sh", None)], None,
        ("Match", var("sh"), [
            ("Circle", "c",
             ("BinOp", "*",
              ("BinOp", "*", num(3), ("Get", var("c"), s("radius"))),
              ("Get", var("c"), s("radius")))),
            ("Rectangle", "r",
             ("BinOp", "*",
              ("Get", var("r"), s("w")), ("Get", var("r"), s("h"))))]))
prog = ("TypeDef", "Shape", Shape,
        ("Let", "area", None, area,
         ("BinOp", "+",
          ("Call", var("area"),
           [("Construct", "Circle", ("Record", [("radius", num(10))]))]),
          ("Call", var("area"),
           [("Construct", "Rectangle",
             ("Record", [("w", num(4)), ("h", num(5))]))]))))
print("area(Circle r=10) + area(Rect 4x5) =", _show(run(prog)))

banner("6b. Rung 2: match falls through -> non-exhaustive throws")
prog2 = ("Let", "area", None, area,
         ("Call", var("area"),
          [("Construct", "Triangle", ("Record", [("base", num(2))]))]))
try:
    run(prog2)
    print("!! no error (unexpected)")
except LangThrow as ex:
    print("threw as expected:", _show(ex.value))

# ---------------------------------------------------------------------------
banner("7. try/catch recovers a thrown value")
# try (throw "boom") catch e { "caught: " + e }
prog = ("Try", ("Throw", s("boom")), "e",
        ("BinOp", "+", s("caught: "), var("e")))
print(_show(run(prog)))

# ---------------------------------------------------------------------------
banner("8. typed record check (TRecord) at a boundary")
# fn(p: {x:Int, y:Int}): Int { p.x + p.y }
Pt = ("TRecord", [("x", Int), ("y", Int)])
dist = ("Lambda", [("p", Pt)], Int,
        ("BinOp", "+", ("Get", var("p"), s("x")), ("Get", var("p"), s("y"))))
good = ("Let", "f", None, dist,
        ("Call", var("f"), [("Record", [("x", num(3)), ("y", num(4))])]))
print("f({x:3,y:4}) =", _show(run(good)))
bad = ("Let", "f", None, dist,
       ("Call", var("f"), [("Record", [("x", num(3))])]))   # missing y
try:
    run(bad); print("!! no error")
except LangThrow as ex:
    print("missing-field threw as expected:", _show(ex.value))

print("\nall sections ran.")
