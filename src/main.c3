module engine;
import std::io;
import std::collections;
import std::collections::map;
import std::core::dstring;

// ============================================================================
// TYPES (Rung 1 + Rung 2 surface types)
// ============================================================================
//
// Types exist only at desugar time.  They never reach the kernel evaluator.
// `TName` is a name; we look it up in `tenv` (compile-time table populated by
// `TypeDef`).  `TRecord` and `TSum` carry parallel key/type arrays.
//
// The lowerings:
//   check(T, e)   = If(is_T(e), e, Throw("type error"))
//   Construct(t, v) = Record([("__tag", Lit t), ("__val", v)])
//   Match(s, [...]) = If-chain on Get(s, "__tag"), each branch binding "__val"

enum TypeKind : char { TNAME, TARRAY, TRECORD, TSUM }

struct Type
{
	TypeKind kind;
	String name;        // TName
	Type* elem;          // TArray  (heap, not by value: avoids recursive struct)
	String[] keys;       // TRecord field names / TSum tag names
	Type*[] types;       // TRecord field types / TSum tag types (pointers to avoid recursion)
}

fn Type mk_tname(String n)
{
	Type t;
	t.kind = TNAME;
	t.name = n;
	return t;
}

fn Type mk_tarray(Type e)
{
	Type t;
	t.kind = TARRAY;
	Type* p = mem::new(Type);
	*p = e;
	t.elem = p;
	return t;
}

fn Type mk_trecord(String[] ks, Type[] ts)
{
	assert(ks.len == ts.len);
	Type t;
	t.kind = TRECORD;
	t.keys = ks;
	Type*[] ps = mem::new_array(Type*, ts.len);
	for (int i = 0; i < ts.len; i++)
	{
		ps[i] = mem::new(Type);
		*ps[i] = ts[i];
	}
	t.types = ps;
	return t;
}

fn Type mk_tsum(String[] tags, Type[] ts)
{
	assert(tags.len == ts.len);
	Type t;
	t.kind = TSUM;
	t.keys = tags;
	Type*[] ps = mem::new_array(Type*, ts.len);
	for (int i = 0; i < ts.len; i++)
	{
		ps[i] = mem::new(Type);
		*ps[i] = ts[i];
	}
	t.types = ps;
	return t;
}

// Compile-time type table: name -> Type.  Linear search; tenv is tiny.
fn TypeDefEntry* tenv_lookup(TypeDefEntry* tenv, String name)
{
	for (TypeDefEntry* e = tenv; e != null; e = e.next)
	{
		if (e.name == name) return e;
	}
	return null;
}

fn TypeDefEntry* tenv_extend(TypeDefEntry* tenv, String name, Type type)
{
	TypeDefEntry* e = mem::new(TypeDefEntry);
	e.name = name;
	e.type = type;
	e.next = tenv;
	return e;
}
//
// The Value is a tagged union. Heap-allocated Array / Record / Closure / Prim
// live behind a void* and are tracked with simple manual allocation for the
// tree-walker phase. Reference counting comes in with the bytecode VM.

enum ValueType : char
{
	NIL,
	BOOL,
	NUMBER,
	STRING,
	ARRAY,
	RECORD,
	CLOSURE,
	PRIMITIVE,
}

struct Value
{
	ValueType type;
	bool bool_val;
	double num_val;
	String str_val;
	void* ptr_val;
}

// ============================================================================
// HEAP TYPES
// ============================================================================

struct Array
{
	Value[] items;
}

struct Record
{
	String[] keys;
	Value[] values;
}

struct Closure
{
	String[] params;
	AstNode* body;
	Env* env;
}

// A primitive is a named builtin.  We carry the name as a String and dispatch
// at apply time; carrying the name keeps debugging output honest.
struct Prim
{
	String name;
}

// ============================================================================
// AST NODES (kernel + a few surface that are still in the file for tests)
// ============================================================================
//
// Uniform node: `name` for single-name nodes (VAR, PRIM, LETREC, TRY catch),
// `literal` for LIT, `names` parallel to `children` for record fields and
// lambda param names, and `children` for the rest.

enum NodeType : char
{
	LIT,
	VAR,
	LAMBDA,
	CALL,
	IF,
	GET,
	SET,
	RECORD,
	ARRAY_LIT,
	THROW,
	TRY,
	PRIM,
	LETREC,
	SEQ,        // surface: sequential evaluation; desugars to ignored-binding lambdas
	BINOP,      // surface: operator call; desugars to Call(Prim(op), [a, b])
	METHODCALL, // surface: recv.m(args); desugars to Lambda-bind-r + Get+Call
	// Rung 1 / Rung 2 surface-only forms:
	LET_T,     // surface: typed Let; desugars to checked LetRec
	LAMBDA_T,  // surface: typed Lambda; desugars to checked Lambda
	TYPEDEF,   // surface: register a type name in tenv, emit body
	CONSTRUCT, // surface: tagged value; desugars to Record with __tag/__val
	MATCH,     // surface: pattern match; desugars to If-chain on __tag
}

struct TypeDefEntry
{
	String name;
	Type type;
	TypeDefEntry* next;
}

struct AstNode
{
	NodeType type;
	String name;
	Value literal;
	String[] names;
	AstNode*[] children;
	// Surface-only annotation payload (LAMBDA_T, LET_T).  These are erased
	// during desugaring; the kernel evaluator never sees them.
	Type*[] param_types;
	Type* ret_type;
	Type* ann_type;       // LET_T: type of the initializer
}

// ============================================================================
// ENVIRONMENT (lexical scope, parent chain)
// ============================================================================
//
// Each Env carries a HashMap{String, Value} for O(1) name lookup.  The HashMap
// is heap-allocated and initialized with the heap allocator; we don't free it
// (per the current --test-noleak policy — refcounting lands with the VM).

struct Env
{
	HashMap{String, Value}* map;
	Env* parent;
}

// ============================================================================
// EVAL RESULT
// ============================================================================
//
// Throw needs to carry a value back to Try without unwinding C3's stack via a
// fault.  We return a small struct; the `thrown` flag is the discriminator.

struct EvalResult
{
	bool thrown;
	Value value;
}

// ============================================================================
// CONSTRUCTORS
// ============================================================================

fn Value mk_nil() => { .type = NIL };
fn Value mk_bool(bool b) => { .type = BOOL, .bool_val = b };
fn Value mk_num(double n) => { .type = NUMBER, .num_val = n };
fn Value mk_str(String s) => { .type = STRING, .str_val = s };
fn Value mk_prim(String n) => { .type = PRIMITIVE, .str_val = n };

fn Array* new_array() => mem::new(Array);
fn Record* new_record() => mem::new(Record);
fn Closure* new_closure() => mem::new(Closure);
fn Prim* new_prim(String n)
{
	Prim* p = mem::new(Prim);
	p.name = n;
	return p;
}

fn AstNode* make_lit(Value v)
{
	AstNode* n = mem::new(AstNode);
	n.type = LIT;
	n.literal = v;
	return n;
}

fn AstNode* make_var(String name)
{
	AstNode* n = mem::new(AstNode);
	n.type = VAR;
	n.name = name;
	return n;
}

fn AstNode* make_lambda(String[] params, AstNode* body)
{
	// Copy `params` to heap — the caller's slice literal `{ "x", "y" }` is a
	// stack temp and would dangle once we return.
	AstNode* n = mem::new(AstNode);
	n.type = LAMBDA;
	String[] heap_params = mem::new_array(String, params.len);
	for (int i = 0; i < params.len; i++) heap_params[i] = params[i];
	n.names = heap_params;
	AstNode*[] kids = mem::new_array(AstNode*, 1);
	kids[0] = body;
	n.children = kids;
	return n;
}

fn AstNode* make_call(AstNode* fn_node, AstNode*[] args)
{
	AstNode*[] kids = mem::new_array(AstNode*, args.len + 1);
	kids[0] = fn_node;
	for (int i = 0; i < args.len; i++) kids[i + 1] = args[i];
	AstNode* n = mem::new(AstNode);
	n.type = CALL;
	n.children = kids;
	return n;
}

fn AstNode* make_if(AstNode* c, AstNode* t, AstNode* e)
{
	AstNode* n = mem::new(AstNode);
	n.type = IF;
	AstNode*[] kids = mem::new_array(AstNode*, 3);
	kids[0] = c; kids[1] = t; kids[2] = e;
	n.children = kids;
	return n;
}

fn AstNode* make_record(String[] keys, AstNode*[] vals)
{
	assert(keys.len == vals.len);
	// Same heap-copy rationale as make_lambda: `keys` is usually a stack temp.
	AstNode* n = mem::new(AstNode);
	n.type = RECORD;
	String[] heap_keys = mem::new_array(String, keys.len);
	for (int i = 0; i < keys.len; i++) heap_keys[i] = keys[i];
	n.names = heap_keys;
	n.children = vals;
	return n;
}

fn AstNode* make_array(AstNode*[] items)
{
	AstNode* n = mem::new(AstNode);
	n.type = ARRAY_LIT;
	n.children = items;
	return n;
}

fn AstNode* make_get(AstNode* obj, AstNode* key)
{
	AstNode* n = mem::new(AstNode);
	n.type = GET;
	AstNode*[] kids = mem::new_array(AstNode*, 2);
	kids[0] = obj; kids[1] = key;
	n.children = kids;
	return n;
}

fn AstNode* make_set(AstNode* obj, AstNode* key, AstNode* val)
{
	AstNode* n = mem::new(AstNode);
	n.type = SET;
	AstNode*[] kids = mem::new_array(AstNode*, 3);
	kids[0] = obj; kids[1] = key; kids[2] = val;
	n.children = kids;
	return n;
}

fn AstNode* make_throw(AstNode* v)
{
	AstNode* n = mem::new(AstNode);
	n.type = THROW;
	AstNode*[] kids = mem::new_array(AstNode*, 1);
	kids[0] = v;
	n.children = kids;
	return n;
}

fn AstNode* make_try(AstNode* body, String cname, AstNode* handler)
{
	AstNode* n = mem::new(AstNode);
	n.type = TRY;
	n.name = cname;
	AstNode*[] kids = mem::new_array(AstNode*, 2);
	kids[0] = body; kids[1] = handler;
	n.children = kids;
	return n;
}

fn AstNode* make_prim_node(String name)
{
	AstNode* n = mem::new(AstNode);
	n.type = PRIM;
	n.name = name;
	return n;
}

fn AstNode* make_letrec(String name, AstNode* init, AstNode* body)
{
	AstNode* n = mem::new(AstNode);
	n.type = LETREC;
	n.name = name;
	AstNode*[] kids = mem::new_array(AstNode*, 2);
	kids[0] = init; kids[1] = body;
	n.children = kids;
	return n;
}

fn AstNode* make_seq(AstNode*[] exprs)
{
	AstNode* n = mem::new(AstNode);
	n.type = SEQ;
	n.children = exprs;
	return n;
}

fn AstNode* make_binop_node(String op, AstNode* lhs, AstNode* rhs)
{
	AstNode* n = mem::new(AstNode);
	n.type = BINOP;
	n.name = op;
	AstNode*[] kids = mem::new_array(AstNode*, 2);
	kids[0] = lhs; kids[1] = rhs;
	n.children = kids;
	return n;
}

fn AstNode* make_methodcall(AstNode* recv, String name, AstNode*[] args)
{
	AstNode* n = mem::new(AstNode);
	n.type = METHODCALL;
	n.name = name;
	AstNode*[] kids = mem::new_array(AstNode*, args.len + 1);
	kids[0] = recv;
	for (int i = 0; i < args.len; i++) kids[i + 1] = args[i];
	n.children = kids;
	return n;
}

// ============================================================================
// VALUE HELPERS
// ============================================================================

fn bool truthy(Value v)
{
	if (v.type == NIL) return false;
	if (v.type == BOOL) return v.bool_val;
	return true;
}

fn bool strict_eq(Value a, Value b)
{
	if (a.type != b.type) return false;
	switch (a.type)
	{
		case NIL: return true;
		case BOOL: return a.bool_val == b.bool_val;
		case NUMBER: return a.num_val == b.num_val;
		case STRING: return a.str_val == b.str_val;
		case PRIMITIVE: return a.str_val == b.str_val;
		case ARRAY:
		case RECORD:
		case CLOSURE: return a.ptr_val == b.ptr_val;
	}
	return false;
}

fn Value show(Value v)
{
	switch (v.type)
	{
		case NIL: return mk_str("nil");
		case BOOL: return mk_str(v.bool_val ? "true" : "false");
		case NUMBER:
			if (v.num_val == (double)(long)v.num_val)
			{
				return mk_str(string::tformat("%d", (long)v.num_val));
			}
			return mk_str(string::tformat("%s", v.num_val));
		case STRING: return mk_str(string::tformat("%s", v.str_val));
		case ARRAY:
			Array* a = (Array*)v.ptr_val;
			@pool() {
				DString buf;
				buf.tinit();
				buf.append_char('[');
				for (int i = 0; i < a.items.len; i++)
				{
					if (i > 0) buf.append(", ");
					Value s = show(a.items[i]);
					buf.append(s.str_val);
				}
				buf.append_char(']');
				return mk_str(buf.str_view());
			};
		case RECORD:
			Record* r = (Record*)v.ptr_val;
			@pool() {
				DString buf;
				buf.tinit();
				buf.append_char('{');
				for (int i = 0; i < r.keys.len; i++)
				{
					if (i > 0) buf.append(", ");
					buf.append(r.keys[i]);
					buf.append(": ");
					Value s = show(r.values[i]);
					buf.append(s.str_val);
				}
				buf.append_char('}');
				return mk_str(buf.str_view());
			};
		case CLOSURE:
			Closure* c = (Closure*)v.ptr_val;
			@pool() {
				DString buf;
				buf.tinit();
				buf.append("<closure(");
				for (int i = 0; i < c.params.len; i++)
				{
					if (i > 0) buf.append(", ");
					buf.append(c.params[i]);
				}
				buf.append(")>");
				return mk_str(buf.str_view());
			};
		case PRIMITIVE: return mk_str(string::tformat("<prim %s>", v.str_val));
	}
	return mk_nil();
}

// ============================================================================
// ENV HELPERS
// ============================================================================

fn Env* env_extend(Env* parent, String[] names, Value[] values)
{
	Env* e = mem::new(Env);
	e.parent = parent;
	e.map = mem::new(HashMap{String, Value});
	e.map.init(mem);
	for (int i = 0; i < names.len; i++)
	{
		e.map.set(names[i], values[i]);
	}
	return e;
}

fn Env* env_define(Env* parent, String name, Value v)
{
	Env* e = mem::new(Env);
	e.parent = parent;
	e.map = mem::new(HashMap{String, Value});
	e.map.init(mem);
	e.map.set(name, v);
	return e;
}

fn Value env_lookup(Env* env, String name, bool* found = null)
{
	Env* cur = env;
	while (cur != null)
	{
		if (try v = cur.map.get(name))
		{
			if (found != null) *found = true;
			return v;
		}
		cur = cur.parent;
	}
	if (found != null) *found = false;
	return mk_nil();
}

fn void env_set(Env* env, String name, Value v)
{
	Env* cur = env;
	while (cur != null)
	{
		if (cur.map.has_key(name)) { cur.map.set(name, v); return; }
		cur = cur.parent;
	}
	// Unbound assignment: set adds to the innermost scope, matching JS-y
	// "set adds" behavior so things don't disappear silently.
	env.map.set(name, v);
}

// ============================================================================
// PRIMITIVES
// ============================================================================
//
// Each primitive returns an EvalResult because some (like `array_all`) need
// control flow that would otherwise re-enter eval in a confusing way.

fn EvalResult prim_dispatch(String name, Value[] args)
{
	switch (name)
	{
		case "+":
			if (args[0].type == NUMBER && args[1].type == NUMBER)
			{
				return { .value = mk_num(args[0].num_val + args[1].num_val) };
			}
			if (args[0].type == STRING && args[1].type == STRING)
			{
				return { .value = mk_str(args[0].str_val.tconcat(args[1].str_val)) };
			}
			return { .thrown = true, .value = mk_str("type error: + expects number or string") };
		case "-":
			if (args[0].type != NUMBER || args[1].type != NUMBER)
			{
				return { .thrown = true, .value = mk_str("type error: - expects numbers") };
			}
			return { .value = mk_num(args[0].num_val - args[1].num_val) };
		case "*":
			if (args[0].type != NUMBER || args[1].type != NUMBER)
			{
				return { .thrown = true, .value = mk_str("type error: * expects numbers") };
			}
			return { .value = mk_num(args[0].num_val * args[1].num_val) };
		case "/":
			if (args[0].type != NUMBER || args[1].type != NUMBER)
			{
				return { .thrown = true, .value = mk_str("type error: / expects numbers") };
			}
			if (args[1].num_val == 0.0)
			{
				return { .thrown = true, .value = mk_str("division by zero") };
			}
			return { .value = mk_num(args[0].num_val / args[1].num_val) };
		case "===":
			return { .value = mk_bool(strict_eq(args[0], args[1])) };
		case "<":
			if (args[0].type != NUMBER || args[1].type != NUMBER)
			{
				return { .thrown = true, .value = mk_str("type error: < expects numbers") };
			}
			return { .value = mk_bool(args[0].num_val < args[1].num_val) };
		case ">":
			if (args[0].type != NUMBER || args[1].type != NUMBER)
			{
				return { .thrown = true, .value = mk_str("type error: > expects numbers") };
			}
			return { .value = mk_bool(args[0].num_val > args[1].num_val) };
		case "<=":
			if (args[0].type != NUMBER || args[1].type != NUMBER)
			{
				return { .thrown = true, .value = mk_str("type error: <= expects numbers") };
			}
			return { .value = mk_bool(args[0].num_val <= args[1].num_val) };
		case ">=":
			if (args[0].type != NUMBER || args[1].type != NUMBER)
			{
				return { .thrown = true, .value = mk_str("type error: >= expects numbers") };
			}
			return { .value = mk_bool(args[0].num_val >= args[1].num_val) };
		case "and":
			return { .value = truthy(args[0]) ? args[1] : args[0] };
		case "or":
			return { .value = truthy(args[0]) ? args[0] : args[1] };
		case "is_number": return { .value = mk_bool(args[0].type == NUMBER) };
		case "is_string": return { .value = mk_bool(args[0].type == STRING) };
		case "is_bool":   return { .value = mk_bool(args[0].type == BOOL) };
		case "is_array":  return { .value = mk_bool(args[0].type == ARRAY) };
		case "is_record": return { .value = mk_bool(args[0].type == RECORD) };
		case "is_nil":    return { .value = mk_bool(args[0].type == NIL) };
		case "has_field":
			if (args[0].type != RECORD)
			{
				return { .thrown = true, .value = mk_str("type error: has_field expects record") };
			}
			Record* r = (Record*)args[0].ptr_val;
			String k = args[1].str_val;
			foreach (&key : r.keys)
			{
				if (*key == k) return { .value = mk_bool(true) };
			}
			return { .value = mk_bool(false) };
		case "len":
			if (args[0].type == ARRAY)
			{
				Array* a = (Array*)args[0].ptr_val;
				return { .value = mk_num((double)a.items.len) };
			}
			if (args[0].type == STRING)
			{
				return { .value = mk_num((double)args[0].str_val.len) };
			}
			return { .thrown = true, .value = mk_str("type error: len expects array or string") };
		case "push":
			if (args[0].type != ARRAY)
			{
				return { .thrown = true, .value = mk_str("type error: push expects array") };
			}
			Array* a = (Array*)args[0].ptr_val;
			Value[] grown = mem::new_array(Value, a.items.len + 1);
			for (int i = 0; i < a.items.len; i++) grown[i] = a.items[i];
			grown[a.items.len] = args[1];
			a.items = grown;
			return { .value = mk_nil() };
		case "array_all":
		{
			// array_all(arr, pred)  =>  true if pred(x) is truthy for every x in arr
			if (args[0].type != ARRAY)
			{
				return { .thrown = true, .value = mk_str("type error: array_all expects array") };
			}
			if (args[1].type != CLOSURE)
			{
				return { .thrown = true, .value = mk_str("type error: array_all expects closure") };
			}
			Array* a = (Array*)args[0].ptr_val;
			foreach (&item : a.items)
			{
				EvalResult r = apply_fn(args[1], { *item });
				if (r.thrown) return r;
				if (!truthy(r.value)) return { .value = mk_bool(false) };
			}
			return { .value = mk_bool(true) };
		}
		case "print":
			foreach (arg : args)
			{
				Value s = show(arg);
				io::printn(s.str_val);
			}
			return { .value = mk_nil() };
	}
	return { .thrown = true, .value = mk_str(string::tformat("unknown primitive: %s", name)) };
}

// ============================================================================
// DESUGARER (surface -> kernel)
// ============================================================================
//
// Steps 3-5 of the build order are pure front-end desugaring.  The kernel
// evaluator below never sees SEQ, BINOP, or METHODCALL because they are
// rewritten into the existing kernel nodes.  Rung 1 (type annotations) and
// Rung 2 (Construct/Match) are handled in later steps.

fn AstNode* desugar_seq_kids(AstNode*[] exprs)
{
	// Seq([a, b, ...])   =>   Call(Lambda(["_"], rest), [a])
	// with the base case Seq([]) => Lit(nil), Seq([a]) => desugar(a).
	if (exprs.len == 0) return make_lit(mk_nil());
	if (exprs.len == 1) return desugar(exprs[0], null);
	AstNode* head = desugar(exprs[0], null);
	AstNode*[] rest = mem::new_array(AstNode*, exprs.len - 1);
	for (int i = 1; i < exprs.len; i++) rest[i - 1] = exprs[i];
	return make_call(make_lambda({ "_" }, desugar_seq_kids(rest)), { head });
}

// Desugar every child of an already-kernel node, then rebuild it.
fn AstNode* desugar_with_kids(NodeType t, AstNode*[] kids, TypeDefEntry* tenv)
{
	AstNode*[] out = mem::new_array(AstNode*, kids.len);
	for (int i = 0; i < kids.len; i++) out[i] = desugar(kids[i], tenv);
	AstNode* n = mem::new(AstNode);
	n.type = t;
	n.children = out;
	return n;
}

int gensym_counter;
fn String gensym(String prefix)
{
	gensym_counter++;
	return string::tformat("%s%d", prefix, gensym_counter);
}

// type_pred: build a kernel boolean AST that is true iff `val` matches type t.
// `val` is the already-desugared kernel expression being checked.
fn AstNode* type_pred(Type t, AstNode* val, TypeDefEntry* tenv)
{
	switch (t.kind)
	{
		case TNAME:
			if (t.name == "Int" || t.name == "Number")
			{
				return make_call(make_prim_node("is_number"), { val });
			}
			if (t.name == "String")
			{
				return make_call(make_prim_node("is_string"), { val });
			}
			if (t.name == "Bool")
			{
				return make_call(make_prim_node("is_bool"), { val });
			}
			if (tenv_lookup(tenv, t.name) != null)
			{
				return type_pred(tenv_lookup(tenv, t.name).type, val, tenv);
			}
			// unknown: gradual-typing escape hatch — be permissive.
			return make_lit(mk_bool(true));
		case TARRAY:
		{
			// is_array AND every element matches (via array_all + a lambda predicate)
			String e = gensym("_e");
			AstNode* e_var = make_var(e);
			AstNode* elem_pred = make_lambda({ e }, type_pred(*t.elem, e_var, tenv));
			return make_call(make_prim_node("array_all"), { val, elem_pred });
		}
		case TRECORD:
		{
			// is_record AND every named field present and matching.
			// Folded into a right-nested If.
			AstNode* result = make_lit(mk_bool(true));
			for (int i = t.keys.len - 1; i >= 0; i--)
			{
				String fname = t.keys[i];
				Type ftype = *t.types[i];
				AstNode* fval = make_get(val, make_lit(mk_str(fname)));
				AstNode* fcheck = type_pred(ftype, fval, tenv);
				AstNode* has = make_call(make_prim_node("has_field"),
					{ val, make_lit(mk_str(fname)) });
				result = make_if(has,
					make_if(fcheck, result, make_lit(mk_bool(false))),
					make_lit(mk_bool(false)));
			}
			return make_if(
				make_call(make_prim_node("is_record"), { val }),
				result,
				make_lit(mk_bool(false)));
		}
		case TSUM:
		{
			// is_record AND __tag is one of the listed tags.
			AstNode* result = make_lit(mk_bool(false));
			for (int i = 0; i < t.keys.len; i++)
			{
				String tag = t.keys[i];
				AstNode* eq = make_call(make_prim_node("==="), {
					make_get(val, make_lit(mk_str("__tag"))),
					make_lit(mk_str(tag)),
				});
				result = make_if(eq, make_lit(mk_bool(true)), result);
			}
			return make_if(
				make_call(make_prim_node("is_record"), { val }),
				result,
				make_lit(mk_bool(false)));
		}
	}
	return make_lit(mk_bool(true));
}

// make_check: wrap an already-desugared kernel expression `expr_kernel` so
// that it is re-evaluated exactly once, asserted against type t, and either
// returned or thrown.  Mirrors the reference's `make_check`.
fn AstNode* make_check(Type t, AstNode* expr_kernel, TypeDefEntry* tenv, String where)
{
	String v = gensym("_v");
	AstNode* v_var = make_var(v);
	AstNode* pred = type_pred(t, v_var, tenv);
	String msg = string::tformat("type error at %s: expected %s", where, type_name(t));
	AstNode* err = make_throw(make_lit(mk_str(msg)));
	AstNode* body = make_if(pred, v_var, err);
	return make_call(make_lambda({ v }, body), { expr_kernel });
}

fn String type_name(Type t)
{
	switch (t.kind)
	{
		case TNAME: return t.name;
		case TARRAY: return string::tformat("Array<%s>", type_name(*t.elem));
		case TRECORD:
		{
			@pool() {
				DString buf;
				buf.tinit();
				buf.append_char('{');
				for (int i = 0; i < t.keys.len; i++)
				{
					if (i > 0) buf.append(", ");
					buf.append(t.keys[i]);
					buf.append(": ");
					buf.append(type_name(*t.types[i]));
				}
				buf.append_char('}');
				return buf.str_view();
			};
		}
		case TSUM:
		{
			@pool() {
				DString buf;
				buf.tinit();
				for (int i = 0; i < t.keys.len; i++)
				{
					if (i > 0) buf.append(" | ");
					buf.append(t.keys[i]);
				}
				return buf.str_view();
			};
		}
	}
	return "?";
}

fn AstNode* desugar(AstNode* e, TypeDefEntry* tenv)
{
	switch (e.type)
	{
		case LIT:
		case VAR:
		case PRIM:
			return e;
		case LAMBDA:
		{
			// A lambda's body might be a SEQ or other surface form; desugar it.
			AstNode* n = mem::new(AstNode);
			n.type = LAMBDA;
			n.names = e.names;
			AstNode*[] kids = mem::new_array(AstNode*, e.children.len);
			for (int i = 0; i < e.children.len; i++) kids[i] = desugar(e.children[i], tenv);
			n.children = kids;
			return n;
		}
		case CALL:    return desugar_with_kids(CALL, e.children, tenv);
		case IF:      return desugar_with_kids(IF, e.children, tenv);
		case GET:     return desugar_with_kids(GET, e.children, tenv);
		case SET:     return desugar_with_kids(SET, e.children, tenv);
		case RECORD:
		{
			// Record has parallel `names` and `children`; desugar children only.
			AstNode* n = mem::new(AstNode);
			n.type = RECORD;
			n.names = e.names;
			AstNode*[] out = mem::new_array(AstNode*, e.children.len);
			for (int i = 0; i < e.children.len; i++) out[i] = desugar(e.children[i], tenv);
			n.children = out;
			return n;
		}
		case ARRAY_LIT: return desugar_with_kids(ARRAY_LIT, e.children, tenv);
		case THROW:     return desugar_with_kids(THROW, e.children, tenv);
		case TRY:
		{
			AstNode* n = mem::new(AstNode);
			n.type = TRY;
			n.name = e.name;
			AstNode*[] out = mem::new_array(AstNode*, e.children.len);
			for (int i = 0; i < e.children.len; i++) out[i] = desugar(e.children[i], tenv);
			n.children = out;
			return n;
		}
		case LETREC:
		{
			AstNode* n = mem::new(AstNode);
			n.type = LETREC;
			n.name = e.name;
			AstNode*[] out = mem::new_array(AstNode*, e.children.len);
			for (int i = 0; i < e.children.len; i++) out[i] = desugar(e.children[i], tenv);
			n.children = out;
			return n;
		}
		case SEQ:
			return desugar_seq_kids(e.children);
		case BINOP:
		{
			// BinOp(op, lhs, rhs)  =>  Call(Prim(op), [lhs', rhs'])
			AstNode* lhs = desugar(e.children[0], tenv);
			AstNode* rhs = desugar(e.children[1], tenv);
			return make_call(make_prim_node(e.name), { lhs, rhs });
		}
		case METHODCALL:
		{
			// recv.m(args)  =>  Call(Lambda([r], Call(Get(Var r, m), [Var r, ...args])), [recv])
			String m = e.name;
			AstNode* recv = desugar(e.children[0], tenv);
			AstNode*[] args = mem::new_array(AstNode*, e.children.len - 1);
			for (int i = 1; i < e.children.len; i++) args[i - 1] = desugar(e.children[i], tenv);
			AstNode*[] call_args = mem::new_array(AstNode*, args.len + 1);
			call_args[0] = make_var("r");
			for (int i = 0; i < args.len; i++) call_args[i + 1] = args[i];
			AstNode* get = make_get(make_var("r"), make_lit(mk_str(m)));
			AstNode* call = make_call(get, call_args);
			AstNode* lam = make_lambda({ "r" }, call);
			return make_call(lam, { recv });
		}
		case LAMBDA_T:
		{
			// Typed Lambda: strip annotations, wrap body in checks for params and return.
			//   Lambda(xs:[name,Type?], ret:Type?, body)
			//   => Lambda(xs, Check(ret, Bind(_r, body)))
			AstNode* body_d = desugar(e.children[0], tenv);
			String[] heap_names = mem::new_array(String, e.names.len);
			for (int i = 0; i < e.names.len; i++) heap_names[i] = e.names[i];
			// Param checks
			AstNode* checked = body_d;
			for (int i = e.param_types.len - 1; i >= 0; i--)
			{
				if (e.param_types[i] != null)
				{
					String pname = heap_names[i];
					Type pt = *e.param_types[i];
					AstNode* v = make_var(pname);
					AstNode* pred = type_pred(pt, v, tenv);
					String msg = string::tformat("type error at param '%s': expected %s", pname, type_name(pt));
					checked = make_if(pred, checked, make_throw(make_lit(mk_str(msg))));
				}
			}
			// Return check
			if (e.ret_type != null)
			{
				String rname = gensym("_ret");
				Type rt = *e.ret_type;
				AstNode* rv = make_var(rname);
				AstNode* pred = type_pred(rt, rv, tenv);
				String msg = string::tformat("type error at return value: expected %s", type_name(rt));
				AstNode* return_checked = make_if(pred, rv, make_throw(make_lit(mk_str(msg))));
				AstNode* bind = make_lambda({ rname }, return_checked);
				checked = make_call(bind, { checked });
			}
			AstNode* n = mem::new(AstNode);
			n.type = LAMBDA;
			n.names = heap_names;
			AstNode*[] kids = mem::new_array(AstNode*, 1);
			kids[0] = checked;
			n.children = kids;
			return n;
		}
		case LET_T:
		{
			// Typed Let: check the initializer against the annotation, then bind.
			AstNode* init_d = desugar(e.children[0], tenv);
			AstNode* body_d = desugar(e.children[1], tenv);
			if (e.ann_type != null)
			{
				Type t = *e.ann_type;
				String where = string::tformat("let '%s'", e.name);
				init_d = make_check(t, init_d, tenv, where);
			}
			AstNode* n = mem::new(AstNode);
			n.type = LETREC;
			n.name = e.name;
			AstNode*[] kids = mem::new_array(AstNode*, 2);
			kids[0] = init_d;
			kids[1] = body_d;
			n.children = kids;
			return n;
		}
		case TYPEDEF:
		{
			// TypeDef(name, t, body)  =>  desugar(body, tenv_extend(tenv, name, t))
			// The body is the only thing the kernel ever sees.
			tenv = tenv_extend(tenv, e.name, *e.ret_type);
			return desugar(e.children[0], tenv);
		}
		case CONSTRUCT:
		{
			// Construct(tag, val)  =>  Record([("__tag", Lit tag), ("__val", val)])
			AstNode* val = desugar(e.children[0], tenv);
			String[] nk = mem::new_array(String, 2);
			nk[0] = "__tag"; nk[1] = "__val";
			AstNode*[] vk = mem::new_array(AstNode*, 2);
			vk[0] = make_lit(mk_str(e.name));
			vk[1] = val;
			return make_record(nk, vk);
		}
		case MATCH:
		{
			// Match(scrut, [branches])  =>
			//   Call(Lambda([s],
			//      IfChain(Gets "__tag" against each tag, bind __val to `bind`,
			//              run `branch`; default = Throw "non-exhaustive")))
			AstNode* scrut = desugar(e.children[0], tenv);
			String s = gensym("_scrut");
			// Each branch is encoded as a 3-tuple (tag, bind, body) in e.names /
			// e.children.  We store: e.names = [tag, bind] repeated, e.children = [body, ...]
			// Simpler: e.children is the [scrut, body1, body2, ...] and e.names
			// is the [tag1, bind1, tag2, bind2, ...].  Decode here.
			AstNode*[] branch_bodies = e.children[1..];
			AstNode* chain = make_throw(make_lit(mk_str("non-exhaustive match")));
			for (int i = branch_bodies.len - 1; i >= 0; i--)
			{
				String tag = e.names[2 * i];
				String bind = e.names[2 * i + 1];
				AstNode* body_branch = desugar(branch_bodies[i], tenv);
				AstNode* bound = make_call(make_lambda({ bind }, body_branch),
					{ make_get(make_var(s), make_lit(mk_str("__val"))) });
				AstNode* eq = make_call(make_prim_node("==="), {
					make_get(make_var(s), make_lit(mk_str("__tag"))),
					make_lit(mk_str(tag)),
				});
				chain = make_if(eq, bound, chain);
			}
			return make_call(make_lambda({ s }, chain), { scrut });
		}
	}
	return e;
}

// ============================================================================
// APPLY
// ============================================================================

fn EvalResult apply_fn(Value fn_val, Value[] args)
{
	if (fn_val.type == PRIMITIVE)
	{
		return prim_dispatch(fn_val.str_val, args);
	}
	if (fn_val.type == CLOSURE)
	{
		Closure* c = (Closure*)fn_val.ptr_val;
		if (args.len != c.params.len)
		{
			return { .thrown = true, .value = mk_str(string::tformat("arity error: expected %d, got %d", c.params.len, args.len)) };
		}
		Env* call_env = env_extend(c.env, c.params, args);
		return eval(c.body, call_env);
	}
	return { .thrown = true, .value = mk_str("not callable") };
}

// ============================================================================
// EVAL
// ============================================================================

fn EvalResult eval(AstNode* node, Env* env)
{
	switch (node.type)
	{
		case LIT:
			return { .value = node.literal };
		case VAR:
			bool found;
			Value v = env_lookup(env, node.name, &found);
			if (!found)
			{
				return { .thrown = true, .value = mk_str(string::tformat("unbound variable: %s", node.name)) };
			}
			return { .value = v };
		case LAMBDA:
		{
			Closure* c = new_closure();
			c.params = node.names;
			c.body = node.children[0];
			c.env = env;
			Value v;
			v.type = CLOSURE;
			v.ptr_val = c;
			return { .value = v };
		}
		case CALL:
		{
			EvalResult fn_r = eval(node.children[0], env);
			if (fn_r.thrown) return fn_r;
			// Evaluate args in order, short-circuiting on throw.
			AstNode*[] arg_nodes = node.children[1..];
			Value[] args = mem::new_array(Value, arg_nodes.len);
			for (int i = 0; i < arg_nodes.len; i++)
			{
				EvalResult a = eval(arg_nodes[i], env);
				if (a.thrown) return a;
				args[i] = a.value;
			}
			return apply_fn(fn_r.value, args);
		}
		case IF:
		{
			EvalResult c = eval(node.children[0], env);
			if (c.thrown) return c;
			if (truthy(c.value)) return eval(node.children[1], env);
			return eval(node.children[2], env);
		}
		case GET:
		{
			EvalResult o = eval(node.children[0], env);
			if (o.thrown) return o;
			EvalResult k = eval(node.children[1], env);
			if (k.thrown) return k;
			if (o.value.type == ARRAY)
			{
				if (k.value.type != NUMBER)
				{
					return { .thrown = true, .value = mk_str("type error: array index must be number") };
				}
				Array* a = (Array*)o.value.ptr_val;
				long idx = (long)k.value.num_val;
				if (idx < 0 || (sz)idx >= a.items.len)
				{
					return { .thrown = true, .value = mk_str("index out of bounds") };
				}
				return { .value = a.items[idx] };
			}
			if (o.value.type == RECORD)
			{
				if (k.value.type != STRING)
				{
					return { .thrown = true, .value = mk_str("type error: record key must be string") };
				}
				Record* r = (Record*)o.value.ptr_val;
				String key = k.value.str_val;
				foreach (i, &rk : r.keys)
				{
					if (*rk == key) return { .value = r.values[i] };
				}
				return { .thrown = true, .value = mk_str(string::tformat("no field '%s'", key)) };
			}
			return { .thrown = true, .value = mk_str("cannot index value") };
		}
		case SET:
		{
			EvalResult o = eval(node.children[0], env);
			if (o.thrown) return o;
			EvalResult k = eval(node.children[1], env);
			if (k.thrown) return k;
			EvalResult v = eval(node.children[2], env);
			if (v.thrown) return v;
			if (o.value.type == ARRAY)
			{
				if (k.value.type != NUMBER)
				{
					return { .thrown = true, .value = mk_str("type error: array index must be number") };
				}
				Array* a = (Array*)o.value.ptr_val;
				long idx = (long)k.value.num_val;
				if (idx < 0 || (sz)idx >= a.items.len)
				{
					return { .thrown = true, .value = mk_str("index out of bounds") };
				}
				a.items[idx] = v.value;
				return { .value = v.value };
			}
			if (o.value.type == RECORD)
			{
				if (k.value.type != STRING)
				{
					return { .thrown = true, .value = mk_str("type error: record key must be string") };
				}
				Record* r = (Record*)o.value.ptr_val;
				String key = k.value.str_val;
				foreach (i, &rk : r.keys)
				{
					if (*rk == key)
					{
						r.values[i] = v.value;
						return { .value = v.value };
					}
				}
				// new key: append
				String[] nk = mem::new_array(String, r.keys.len + 1);
				Value[] nv = mem::new_array(Value, r.values.len + 1);
				for (int j = 0; j < r.keys.len; j++) { nk[j] = r.keys[j]; nv[j] = r.values[j]; }
				nk[r.keys.len] = key;
				nv[r.values.len] = v.value;
				r.keys = nk;
				r.values = nv;
				return { .value = v.value };
			}
			return { .thrown = true, .value = mk_str("cannot set on value") };
		}
		case RECORD:
		{
			Record* r = new_record();
			r.keys = node.names;
			Value[] vals = mem::new_array(Value, node.children.len);
			for (int i = 0; i < node.children.len; i++)
			{
				EvalResult e = eval(node.children[i], env);
				if (e.thrown) return e;
				vals[i] = e.value;
			}
			r.values = vals;
			Value v;
			v.type = RECORD;
			v.ptr_val = r;
			return { .value = v };
		}
		case ARRAY_LIT:
		{
			Array* a = new_array();
			Value[] items = mem::new_array(Value, node.children.len);
			for (int i = 0; i < node.children.len; i++)
			{
				EvalResult e = eval(node.children[i], env);
				if (e.thrown) return e;
				items[i] = e.value;
			}
			a.items = items;
			Value v;
			v.type = ARRAY;
			v.ptr_val = a;
			return { .value = v };
		}
		case THROW:
		{
			EvalResult v = eval(node.children[0], env);
			// v.value is the thrown value regardless of v.thrown (we just propagate).
			return { .thrown = true, .value = v.value };
		}
		case TRY:
		{
			EvalResult b = eval(node.children[0], env);
			if (!b.thrown) return b;
			Env* h = env_define(env, node.name, b.value);
			return eval(node.children[1], h);
		}
		case PRIM:
		{
			Value v;
			v.type = PRIMITIVE;
			v.str_val = node.name;
			return { .value = v };
		}
		case LETREC:
		{
			Env* rec = env_define(env, node.name, mk_nil());
			EvalResult init = eval(node.children[0], rec);
			if (init.thrown) return init;
			// Patch the binding with the actual value so the closure can see itself.
			rec.map.set(node.name, init.value);
			return eval(node.children[1], rec);
		}
		case SEQ:
		case BINOP:
		case METHODCALL:
		case LET_T:
		case LAMBDA_T:
		case TYPEDEF:
		case CONSTRUCT:
		case MATCH:
			return { .thrown = true, .value = mk_str("eval: surface node reached the kernel; desugar first") };
	}
	return { .thrown = true, .value = mk_str("unknown node") };
}

// ============================================================================
// TOP-LEVEL
// ============================================================================

fn Value run(AstNode* node)
{
	@pool() {
		EvalResult r = eval(node, null);
		if (r.thrown)
		{
			Value s = show(r.value);
			io::printfn("threw: %s", s.str_val);
			return mk_nil();
		}
		Value s = show(r.value);
		io::printn(s.str_val);
		return r.value;
	};
}

fn int main(String[] args)
{
	io::printn("JS variant interpreter v0.1.0");
	return 0;
}
