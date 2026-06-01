"""
A minimal expression-oriented language engine.

Architecture (matching the plan):
  - Value universe: Number, String, Bool, Nil, Array, Record, Closure
  - Surface AST  -> desugar() -> Kernel AST -> eval()
  - The evaluator (eval_kernel) understands ONLY the ~12 kernel nodes.
    Everything else (Let, Seq, BinOp, MethodCall, type annotations,
    TypeDef, Construct, Match) is gone before evaluation runs.

Invariants:
  1. Everything is an expression: eval returns a value for every node.
  2. The kernel stays tiny.
  3. Types add zero runtime values and zero eval cases: they lower to If/Throw/Get.
"""

# ============================================================================
# VALUE UNIVERSE
# ============================================================================
# Python floats == our Number; str == String; bool == Bool; None == Nil.
# Arrays and Records get small wrapper classes so Get/Set can dispatch on them.

class Array:
    __slots__ = ("items",)
    def __init__(self, items): self.items = items          # python list
    def __repr__(self): return "[" + ", ".join(map(_show, self.items)) + "]"

class Record:
    __slots__ = ("fields",)
    def __init__(self, fields): self.fields = fields        # python dict
    def __repr__(self):
        return "{" + ", ".join(f"{k}: {_show(v)}" for k, v in self.fields.items()) + "}"

class Closure:
    __slots__ = ("params", "body", "env")
    def __init__(self, params, body, env):
        self.params, self.body, self.env = params, body, env
    def __repr__(self): return f"<closure({', '.join(self.params)})>"

def _show(v):
    if v is None: return "nil"
    if v is True: return "true"
    if v is False: return "false"
    if isinstance(v, float):
        return str(int(v)) if v.is_integer() else str(v)
    if isinstance(v, str): return repr(v)
    return repr(v)


# ============================================================================
# ERRORS
# ============================================================================
# A language-level `throw` is carried by a host exception so try/catch works.

class LangThrow(Exception):
    def __init__(self, value): self.value = value


# ============================================================================
# SURFACE AST
# ============================================================================
# Plain tuples tagged by a leading string. Types are tuples too.
#
# Type:
#   ("TName", name) | ("TArray", T) | ("TRecord", [(field,T)...]) | ("TSum",[(tag,T)...])
#
# Expr (surface):
#   ("Lit", v)
#   ("Var", name)
#   ("Lambda", params=[(name, T_or_None)...], retType_or_None, body)
#   ("Call", fn, [args])
#   ("If", c, t, e)
#   ("Let", name, T_or_None, init, body)
#   ("Seq", [exprs])
#   ("BinOp", op, lhs, rhs)
#   ("Record", [(key, expr)...])
#   ("ArrayLit", [exprs])
#   ("Get", obj, key_expr)
#   ("Set", obj, key_expr, val)
#   ("MethodCall", recv, name, [args])
#   ("Throw", expr)
#   ("Try", body, catchName, handler)
#   ("TypeDef", name, T, body)
#   ("Construct", tag, expr)
#   ("Match", scrutinee, [(tag, bindName, branch)...])


# ============================================================================
# DESUGARING:  surface  ->  kernel
# ============================================================================
# Kernel nodes the evaluator handles:
#   Lit, Var, Lambda(plain), Call, If, Get, Set, Record, ArrayLit, Throw, Try, Prim
#
# `tenv` is the COMPILE-TIME type table (name -> Type), populated by TypeDef.
# It exists only during desugaring; it never reaches the evaluator.

_gensym = 0
def gensym(prefix="_t"):
    global _gensym
    _gensym += 1
    return f"{prefix}{_gensym}"

def desugar(e, tenv):
    tag = e[0]

    # ---- already-kernel leaves ----
    if tag == "Lit": return e
    if tag == "Var": return e
    if tag == "Prim": return e        # direct builtin reference

    # ---- Lambda: strip annotations into runtime boundary checks (Rung 1) ----
    if tag == "Lambda":
        _, params, ret_t, body = e
        names = [p[0] for p in params]
        checks = []
        for (name, t) in params:
            if t is not None:
                checks.append(make_check(t, ("Var", name), tenv,
                                          f"param '{name}'"))
        inner = desugar(body, tenv)
        if ret_t is not None:
            # bind the result, check it, return it
            r = gensym("_ret")
            inner = ("Call",
                     ("Lambda", [r],
                      seq_kernel([
                          make_check(ret_t, ("Var", r), tenv, "return value"),
                          ("Var", r)])),
                     [inner])
        full = seq_kernel(checks + [inner]) if checks else inner
        return ("Lambda", names, full)

    if tag == "Call":
        _, fn, args = e
        return ("Call", desugar(fn, tenv), [desugar(a, tenv) for a in args])

    if tag == "If":
        _, c, t, el = e
        return ("If", desugar(c, tenv), desugar(t, tenv), desugar(el, tenv))

    # ---- Let:  a recursive binding (name is visible in its own initializer).
    # We lower to a single LetRec kernel node rather than Call-of-Lambda,
    # because Call-of-Lambda evaluates the initializer in the OUTER env, so a
    # function couldn't see itself -> no recursion. LetRec defines the name
    # first, then evaluates init in the env that already contains it. This is
    # exactly Scheme's let/letrec distinction; we just make all `let` recursive.
    if tag == "Let":
        _, name, t, init, body = e
        init_d = desugar(init, tenv)
        if t is not None:
            init_d = make_check(t, init_d, tenv, f"let '{name}'")
        return ("LetRec", name, init_d, desugar(body, tenv))

    # ---- Seq:  sequence via ignored-binding lambdas ----
    if tag == "Seq":
        _, exprs = e
        return seq_kernel([desugar(x, tenv) for x in exprs])

    # ---- BinOp:  operators are calls to primitive builtins ----
    if tag == "BinOp":
        _, op, lhs, rhs = e
        return ("Call", ("Prim", op),
                [desugar(lhs, tenv), desugar(rhs, tenv)])

    if tag == "Record":
        _, fields = e
        return ("Record", [(k, desugar(v, tenv)) for (k, v) in fields])

    if tag == "ArrayLit":
        _, items = e
        return ("ArrayLit", [desugar(x, tenv) for x in items])

    if tag == "Get":
        _, obj, key = e
        return ("Get", desugar(obj, tenv), desugar(key, tenv))

    if tag == "Set":
        _, obj, key, val = e
        return ("Set", desugar(obj, tenv), desugar(key, tenv), desugar(val, tenv))

    # ---- MethodCall:  evaluate receiver once, thread it as explicit self ----
    if tag == "MethodCall":
        _, recv, name, args = e
        r = gensym("_recv")
        return ("Call",
                ("Lambda", [r],
                 ("Call",
                  ("Get", ("Var", r), ("Lit", name)),
                  [("Var", r)] + [desugar(a, tenv) for a in args])),
                [desugar(recv, tenv)])

    if tag == "Throw":
        _, v = e
        return ("Throw", desugar(v, tenv))

    if tag == "Try":
        _, body, cname, handler = e
        return ("Try", desugar(body, tenv), cname, desugar(handler, tenv))

    # ---- TypeDef:  register name in compile-time table; vanish, emit body ----
    if tag == "TypeDef":
        _, name, t, body = e
        tenv = dict(tenv); tenv[name] = t
        return desugar(body, tenv)

    # ---- Construct:  a tagged value is just a record ----
    if tag == "Construct":
        _, ctag, val = e
        return ("Record", [("__tag", ("Lit", ctag)),
                           ("__val", desugar(val, tenv))])

    # ---- Match:  evaluate scrutinee once, If-chain on the tag ----
    if tag == "Match":
        _, scrut, branches = e
        s = gensym("_scrut")
        chain = ("Throw", ("Lit", "non-exhaustive match"))
        for (mtag, bind, branch) in reversed(branches):
            # bind __val into `bind`, run branch
            branch_bound = ("Call",
                            ("Lambda", [bind], desugar(branch, tenv)),
                            [("Get", ("Var", s), ("Lit", "__val"))])
            chain = ("If",
                     ("Call", ("Prim", "==="),
                      [("Get", ("Var", s), ("Lit", "__tag")), ("Lit", mtag)]),
                     branch_bound,
                     chain)
        return ("Call", ("Lambda", [s], chain), [desugar(scrut, tenv)])

    raise Exception(f"desugar: unknown surface node {tag}")


def seq_kernel(exprs):
    """Right-fold a list of kernel exprs into nested ignored-binding lambdas.
       value of the sequence is the value of the last expr."""
    if not exprs:
        return ("Lit", None)
    if len(exprs) == 1:
        return exprs[0]
    head, rest = exprs[0], exprs[1:]
    return ("Call", ("Lambda", ["_"], seq_kernel(rest)), [head])


# ---- type checks lower to If / Throw / Prim (Rung 1 / Rung 2) ----
def make_check(t, expr_kernel, tenv, where):
    """Return a kernel expr that evaluates expr, checks it against type t,
       returns it if ok, else Throw. expr_kernel is ALREADY desugared."""
    # Bind the value once so we don't re-evaluate it.
    v = gensym("_v")
    pred = type_pred(t, ("Var", v), tenv)
    msg = ("Lit", f"type error at {where}: expected {type_name(t)}")
    return ("Call",
            ("Lambda", [v],
             ("If", pred, ("Var", v), ("Throw", msg))),
            [expr_kernel])

def type_name(t):
    if t[0] == "TName": return t[1]
    if t[0] == "TArray": return f"Array<{type_name(t[1])}>"
    if t[0] == "TRecord": return "{" + ", ".join(f"{k}:{type_name(ft)}" for k,ft in t[1]) + "}"
    if t[0] == "TSum": return " | ".join(tag for tag,_ in t[1])
    return "?"

def type_pred(t, val_kernel, tenv):
    """Build a boolean kernel expr that is true iff val matches type t.
       val_kernel must be a pure Var (cheap to reference repeatedly)."""
    if t[0] == "TName":
        name = t[1]
        if name in ("Int", "Number"):
            return ("Call", ("Prim", "is_number"), [val_kernel])
        if name == "String":
            return ("Call", ("Prim", "is_string"), [val_kernel])
        if name == "Bool":
            return ("Call", ("Prim", "is_bool"), [val_kernel])
        if name in tenv:                       # a user type alias -> expand
            return type_pred(tenv[name], val_kernel, tenv)
        # unknown name: be permissive (gradual typing escape hatch)
        return ("Lit", True)
    if t[0] == "TArray":
        # is_array AND every element matches (delegated to a primitive that
        # takes a predicate closure)
        elem = gensym("_e")
        elem_pred = ("Lambda", [elem], type_pred(t[1], ("Var", elem), tenv))
        return ("Call", ("Prim", "array_all"), [val_kernel, elem_pred])
    if t[0] == "TRecord":
        # is_record AND each field present and matching.
        # Fold into a big AND via nested If.
        result = ("Lit", True)
        for (fname, ftype) in reversed(t[1]):
            fval = ("Get", val_kernel, ("Lit", fname))
            fcheck = type_pred(ftype, fval, tenv)
            # has-field AND field-matches AND rest
            result = ("If",
                      ("Call", ("Prim", "has_field"),
                       [val_kernel, ("Lit", fname)]),
                      ("If", fcheck, result, ("Lit", False)),
                      ("Lit", False))
        # also require it's a record at all
        return ("If", ("Call", ("Prim", "is_record"), [val_kernel]),
                result, ("Lit", False))
    if t[0] == "TSum":
        # value is a record with __tag in the set of tags
        result = ("Lit", False)
        for (tagname, _) in t[1]:
            result = ("If",
                      ("Call", ("Prim", "==="),
                       [("Get", val_kernel, ("Lit", "__tag")), ("Lit", tagname)]),
                      ("Lit", True), result)
        return ("If", ("Call", ("Prim", "is_record"), [val_kernel]),
                result, ("Lit", False))
    return ("Lit", True)


# ============================================================================
# PRIMITIVES  (the builtin functions that operators and checks call)
# ============================================================================
def _truthy(v):
    return v is not None and v is not False

PRIMS = {
    "+":   lambda a, b: a + b,
    "-":   lambda a, b: a - b,
    "*":   lambda a, b: a * b,
    "/":   lambda a, b: a / b,
    "===": lambda a, b: a is b or a == b if type(a) == type(b) else a is b,
    "<":   lambda a, b: a < b,
    ">":   lambda a, b: a > b,
    "<=":  lambda a, b: a <= b,
    ">=":  lambda a, b: a >= b,
    "and": lambda a, b: b if _truthy(a) else a,
    "or":  lambda a, b: a if _truthy(a) else b,
    "is_number": lambda a: isinstance(a, float),
    "is_string": lambda a: isinstance(a, str),
    "is_bool":   lambda a: isinstance(a, bool),
    "is_array":  lambda a: isinstance(a, Array),
    "is_record": lambda a: isinstance(a, Record),
    "has_field": lambda r, k: isinstance(r, Record) and k in r.fields,
    "len":       lambda a: float(len(a.items)) if isinstance(a, Array) else float(len(a)),
    "push":      lambda a, x: (a.items.append(x), None)[1],
    "print":     lambda *xs: (print(*[_show(x) for x in xs]), None)[1],
}

# array_all needs to CALL a language closure, so it's special (handled in eval).


# ============================================================================
# THE KERNEL EVALUATOR
# ============================================================================
# Environments are dicts chained by a parent pointer (lexical scope).

class Env:
    __slots__ = ("vars", "parent")
    def __init__(self, parent=None):
        self.vars = {}
        self.parent = parent
    def lookup(self, name):
        e = self
        while e is not None:
            if name in e.vars: return e.vars[name]
            e = e.parent
        raise LangThrow(f"unbound variable: {name}")
    def define(self, name, value):
        self.vars[name] = value


def eval_kernel(e, env):
    tag = e[0]

    if tag == "Lit":
        return e[1]

    if tag == "Var":
        return env.lookup(e[1])

    if tag == "Lambda":
        # e = ("Lambda", [names], body)   -- plain, no annotations left
        return Closure(e[1], e[2], env)

    if tag == "Prim":
        # bare primitive reference -> wrap as a callable closure-like value
        return ("__prim__", e[1])

    if tag == "Call":
        fn = eval_kernel(e[1], env)
        args = [eval_kernel(a, env) for a in e[2]]
        return apply_fn(fn, args)

    if tag == "If":
        if _truthy(eval_kernel(e[1], env)):
            return eval_kernel(e[2], env)
        return eval_kernel(e[3], env)

    if tag == "Record":
        return Record({k: eval_kernel(v, env) for (k, v) in e[1]})

    if tag == "ArrayLit":
        return Array([eval_kernel(x, env) for x in e[1]])

    if tag == "Get":
        obj = eval_kernel(e[1], env)
        key = eval_kernel(e[2], env)
        if isinstance(obj, Array):
            return obj.items[int(key)]
        if isinstance(obj, Record):
            if key not in obj.fields:
                raise LangThrow(f"no field '{key}'")
            return obj.fields[key]
        raise LangThrow(f"cannot index {_show(obj)}")

    if tag == "Set":
        obj = eval_kernel(e[1], env)
        key = eval_kernel(e[2], env)
        val = eval_kernel(e[3], env)
        if isinstance(obj, Array):
            obj.items[int(key)] = val
        elif isinstance(obj, Record):
            obj.fields[key] = val
        else:
            raise LangThrow(f"cannot set on {_show(obj)}")
        return val                                  # Set is an expression

    if tag == "Throw":
        raise LangThrow(eval_kernel(e[1], env))

    if tag == "Try":
        _, body, cname, handler = e
        try:
            return eval_kernel(body, env)
        except LangThrow as ex:
            h_env = Env(env)
            h_env.define(cname, ex.value)
            return eval_kernel(handler, h_env)

    if tag == "LetRec":
        # ("LetRec", name, init, body)
        # Create the binding's scope FIRST, then evaluate init within it, so a
        # lambda in init captures an env where its own name resolves. This is
        # the single rule that makes recursion (and thus loops) work.
        _, name, init, body = e
        rec_env = Env(env)
        rec_env.define(name, None)              # placeholder
        val = eval_kernel(init, rec_env)        # closure captures rec_env
        rec_env.vars[name] = val                # tie the knot
        return eval_kernel(body, rec_env)

    raise Exception(f"eval: unknown kernel node {tag}")


def apply_fn(fn, args):
    # primitive?
    if isinstance(fn, tuple) and fn and fn[0] == "__prim__":
        name = fn[1]
        if name == "array_all":
            arr, pred = args
            if not isinstance(arr, Array): return False
            return all(_truthy(apply_fn(pred, [x])) for x in arr.items)
        return PRIMS[name](*args)
    # language closure
    if isinstance(fn, Closure):
        call_env = Env(fn.env)
        if len(args) != len(fn.params):
            raise LangThrow(
                f"arity error: expected {len(fn.params)}, got {len(args)}")
        for p, a in zip(fn.params, args):
            call_env.define(p, a)
        return eval_kernel(fn.body, call_env)
    raise LangThrow(f"not callable: {_show(fn)}")


# ============================================================================
# TOP-LEVEL RUN
# ============================================================================
def run(surface_expr):
    kernel = desugar(surface_expr, {})
    return eval_kernel(kernel, Env())

# convenient builders for writing programs by hand
def num(n): return ("Lit", float(n))
def s(x):   return ("Lit", x)
def var(n): return ("Var", n)
