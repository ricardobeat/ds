Design invariants

Everything is an expression. One syntactic category; eval returns a value for every node. No statement/expression split.
The kernel stays tiny. Surface features desugar into a small core; nothing new is added to the kernel or VM unless it's genuinely irreducible.
Types add zero runtime values and zero VM ops. They're front-end only, lowering to Throw/If/Get. A tagged union is just a record with a __tag field.

Primitive types (the value universe)

Number — single type, IEEE-754 double (accept the can't-represent-all-int64 limitation, à la Lua pre-5.3).
String — immutable, UTF-8, encoding not exposed.
Bool
Nil / unit — the one bottom value; also what effectful expressions (Set, loops-for-effect) return.
Array — primitive, contiguous, integer keys only.
Record — the one keyed aggregate; also the substrate for tagged unions and "objects."
Closure — first-class function + captured environment.

No null/undefined split, no ==/coercion, no prototypes, no this.
Layer 0: Surface AST
Type =                                  // tiny, non-Turing-complete, no inference
  | TName(name) | TArray(Type)
  | TRecord([(field, Type)]) | TSum([(tag, Type)])

Expr =
  | Lit(value) | Var(name)
  | Lambda(params:[(name,Type?)], retType:Type?, body)
  | Call(fn, args) | If(cond, then, else)
  | Let(name, Type?, init, body) | Assign(name, value) | Seq(exprs)
  | BinOp(op, lhs, rhs)
  | Record(fields) | ArrayLit([Expr])
  | Get(obj, key) | Set(obj, key, value)
  | MethodCall(recv, name, args)        // explicit-self sugar
  | Throw(value) | Try(body, catchName, handler)
  | TypeDef(name, Type, body)           // Rung 2
  | Construct(tag, expr) | Match(scrutinee, [(tag, bindName, branch)])  // Rung 2
Layer 1: Desugaring to the kernel
Everything collapses to ~12 nodes:
Kernel = Lit | Var | Lambda | Call | If | Get | Set | Record | ArrayLit | Throw | Try | Prim
The lowerings:
Let(x,_,init,body)   → Call(Lambda([x], body), [init])      // binding = calling
Seq([a,b])           → Call(Lambda([_], b), [a])
BinOp(op,x,y)        → Call(Prim(op), [x,y])                // operators are builtins
while(cond,body)     → recursion (see below)

MethodCall(recv,m,args)                                     // receiver evaluated once
  → { let r = recv;  (r.m)(r, ...args) }
  = Call(Lambda([r], Call(Get(Var r,m), [Var r, ...args])), [recv])

Lambda with annotations                                     // Rung 1: boundary checks
  → un-annotated Lambda whose body is wrapped in check() asserts on params + return
check(T,e)           → If(Call(Prim is_T,[e]), e, Throw("type error"))

TypeDef(name,T,body) → register name→T in compile-time table; emit body (vanishes)
Construct(tag,e)     → Record([("__tag",Lit tag),("__val",e)])
Match(s,branches)    → evaluate s once, then If-chain on Get(s,"__tag"),
                       binding "__val" per branch; else Throw("non-exhaustive")
Arrays are not desugared — ArrayLit and array Get/Set are kernel-level; the runtime dispatches indexed-vs-hashed on the key. Everything else above evaporates into the kernel, which is the proof we stayed minimal.
Layer 2: Bytecode (~20 ops, ~12 irreducible)
# stack
PUSH_CONST k   PUSH_NIL   POP
# variables (lexical slots resolved at compile time)
LOAD_LOCAL i   STORE_LOCAL i   LOAD_UPVAL i   STORE_UPVAL i
# functions
MAKE_CLOSURE proto, upvals     CALL argc     TAILCALL argc     RETURN
# control flow
JUMP off       JUMP_IF_FALSE off
# aggregates
NEW_RECORD     GET_FIELD     SET_FIELD     NEW_ARRAY
# errors
PUSH_HANDLER off   POP_HANDLER   THROW
# primitives — could all just be CALL into builtins:
ADD SUB MUL EQ LT  is_int is_array is_record ...
Nothing in arrays, methods, types, or match adds an opcode: methods → GET_FIELD+CALL; checks → CALL is_*+JUMP_IF_FALSE+THROW; match → GET_FIELD "__tag"+EQ+JUMP_IF_FALSE; Construct → NEW_RECORD+SET_FIELD.
The two genuinely non-optional pieces

Closures + upvalue capture. The load-bearing wall. MAKE_CLOSURE captures enclosing variables; open upvalues point at stack slots, "close" (copy to heap) when the slot leaves scope (Lua's scheme). Without this it's not a functional language.
TAILCALL. Mandatory, not an optimization — because loops are recursion here, a long loop is a deep call chain that overflows without frame reuse. TAILCALL reuses the current frame.

Memory management
Reference counting fits this design well: the engine is small, VDOM/tree-shaped data is mostly acyclic, and you get deterministic, pause-free reclamation that matches the minimalist aesthetic. Records that form cycles (back-references, closures-over-mutable-records) need either a supplemental cycle collector (QuickJS's approach) or a discipline that avoids them. Start with plain refcounting; add the cycle collector only if real cycles show up.
Explicitly out of scope (the Rung 3 line)
No type inference, no unification, no type variables, no generics in the checker, no static rejection of programs. Annotations fire at runtime, at boundaries. Optional later: Rung 2.5, a purely-local syntactic check that flags only directly-visible mismatches (add("x",1)) and stays silent otherwise — no inference, bolt-on.
Also out (JS legacy/runtime, never part of this language): var/hoisting, ASI, with, ==/coercion, arguments, sloppy mode, prototypes, Proxy/Reflect, Date/Intl/regex/Promise, and all host/web APIs — the embedder provides whatever host functions it needs.
Build order

Kernel tree-walker — eval(expr, env) over the ~12 nodes; closures via environment chaining; loops-as-recursion (lean on host stack initially).
Arrays + records — the Get/Set dispatch branching integer-array vs. hashed-record.
Method-call sugar — desugar MethodCall; verify receiver-evaluated-once.
Rung 1 checks — annotation slots, check() desugaring, is_* primitives. Boundary errors work.
Rung 2 — type table, Construct, match lowering. Sum types + pattern matching work.
Surface parser + CLI — let the user run a real `.ds` file from disk. (DONE)
Round-trip formatter — parse, re-emit in canonical style. (DONE)
JSX-like element syntax — `<Tag attr=val ... />` and `<Tag>child, child, ...</Tag>` desugar to function calls. (DONE)
Bytecode compiler + VM — compile the kernel (not the surface language); implement upvalue closing and TAILCALL. Add refcounting; cycle collector only if needed.

Steps 3–5 add no kernel nodes and no opcodes — pure front-end desugaring — so you can build and test them against the tree-walker before the VM exists, and the VM never knows they happened. Steps 1–3 are ~150 lines; 4–5 add maybe 60–80 more.

Performance roadmap (prioritized)

| Priority | Change                                  | Expected gain                           |
|----------|-----------------------------------------|-----------------------------------------|
| 1        | Bytecode compiler + VM (step G)         | 20–50× speed, 1000× memory              |
| 2        | NaN-boxed Value (8 bytes)               | 2–5× further speed, 5× memory           |
| 3        | Interned field atoms for record access  | 2–3× on record-heavy code               |
| 4        | TAILCALL opcode                         | Unlimited recursion depth, loops viable |
| 5        | Reference counting on closures/arrays/records | Deterministic, pause-free GC      |

Priority 1 (bytecode VM) is the single biggest lever — it collapses the tree-walker's per-node overhead into tight bytecode dispatch and enables all the other optimizations. NaN-boxing (priority 2) shrinks Value from 24+ bytes to 8, which cascades into cache wins everywhere. Interned atoms (priority 3) turn record field lookup from string comparison into integer comparison. TAILCALL (priority 4) is mandatory for correctness — loops are recursion, and without frame reuse they overflow. Reference counting (priority 5) gives deterministic, pause-free GC that fits the minimalist aesthetic; add a cycle collector only if real cycles appear.
