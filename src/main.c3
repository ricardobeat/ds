module engine;
import std::io;
import std::collections;
import std::core::dstring;

// ============================================================================
// VALUE UNIVERSE
// ============================================================================
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
}

struct AstNode
{
	NodeType type;
	String name;
	Value literal;
	String[] names;
	AstNode*[] children;
}

// ============================================================================
// ENVIRONMENT (lexical scope, parent chain)
// ============================================================================

struct Binding
{
	String name;
	Value value;
}

struct Env
{
	Binding[] bindings;
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
	Binding[] b = mem::new_array(Binding, names.len);
	for (int i = 0; i < names.len; i++)
	{
		b[i].name = names[i];
		b[i].value = values[i];
	}
	e.bindings = b;
	return e;
}

fn Env* env_define(Env* parent, String name, Value v)
{
	Env* e = mem::new(Env);
	e.parent = parent;
	Binding[] b = mem::new_array(Binding, 1);
	b[0].name = name;
	b[0].value = v;
	e.bindings = b;
	return e;
}

fn Value env_lookup(Env* env, String name, bool* found = null)
{
	Env* cur = env;
	while (cur != null)
	{
		foreach (&b : cur.bindings)
		{
			if (b.name == name)
			{
				if (found != null) *found = true;
				return b.value;
			}
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
		foreach (&b : cur.bindings)
		{
			if (b.name == name) { b.value = v; return; }
		}
		cur = cur.parent;
	}
	// Unbound assignment: create a binding on the innermost scope, matching JS-y
	// "set adds" behavior so things don't disappear silently.
	env.bindings = mem::new_array(Binding, env.bindings.len + 1);
	env.bindings[env.bindings.len - 1] = { .name = name, .value = v };
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
	if (exprs.len == 1) return desugar(exprs[0]);
	AstNode* head = desugar(exprs[0]);
	AstNode*[] rest = mem::new_array(AstNode*, exprs.len - 1);
	for (int i = 1; i < exprs.len; i++) rest[i - 1] = exprs[i];
	return make_call(make_lambda({ "_" }, desugar_seq_kids(rest)), { head });
}

// Desugar every child of an already-kernel node, then rebuild it.
fn AstNode* desugar_with_kids(NodeType t, AstNode*[] kids)
{
	AstNode*[] out = mem::new_array(AstNode*, kids.len);
	for (int i = 0; i < kids.len; i++) out[i] = desugar(kids[i]);
	AstNode* n = mem::new(AstNode);
	n.type = t;
	n.children = out;
	return n;
}

fn AstNode* desugar(AstNode* e)
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
			for (int i = 0; i < e.children.len; i++) kids[i] = desugar(e.children[i]);
			n.children = kids;
			return n;
		}
		case CALL:    return desugar_with_kids(CALL, e.children);
		case IF:      return desugar_with_kids(IF, e.children);
		case GET:     return desugar_with_kids(GET, e.children);
		case SET:     return desugar_with_kids(SET, e.children);
		case RECORD:
		{
			// Record has parallel `names` and `children`; desugar children only.
			AstNode* n = mem::new(AstNode);
			n.type = RECORD;
			n.names = e.names;
			AstNode*[] out = mem::new_array(AstNode*, e.children.len);
			for (int i = 0; i < e.children.len; i++) out[i] = desugar(e.children[i]);
			n.children = out;
			return n;
		}
		case ARRAY_LIT: return desugar_with_kids(ARRAY_LIT, e.children);
		case THROW:     return desugar_with_kids(THROW, e.children);
		case TRY:
		{
			AstNode* n = mem::new(AstNode);
			n.type = TRY;
			n.name = e.name;
			AstNode*[] out = mem::new_array(AstNode*, e.children.len);
			for (int i = 0; i < e.children.len; i++) out[i] = desugar(e.children[i]);
			n.children = out;
			return n;
		}
		case LETREC:
		{
			AstNode* n = mem::new(AstNode);
			n.type = LETREC;
			n.name = e.name;
			AstNode*[] out = mem::new_array(AstNode*, e.children.len);
			for (int i = 0; i < e.children.len; i++) out[i] = desugar(e.children[i]);
			n.children = out;
			return n;
		}
		case SEQ:
			return desugar_seq_kids(e.children);
		case BINOP:
		{
			// BinOp(op, lhs, rhs)  =>  Call(Prim(op), [lhs', rhs'])
			AstNode* lhs = desugar(e.children[0]);
			AstNode* rhs = desugar(e.children[1]);
			return make_call(make_prim_node(e.name), { lhs, rhs });
		}
		case METHODCALL:
		{
			// recv.m(args)  =>  Call(Lambda([r], Call(Get(Var r, m), [Var r, ...args])), [recv])
			// The receiver is bound once; the field lookup runs once; the call passes
			// the receiver as explicit self.  Matches the Go-style / reference design.
			String m = e.name;
			AstNode* recv = desugar(e.children[0]);
			AstNode*[] args = mem::new_array(AstNode*, e.children.len - 1);
			for (int i = 1; i < e.children.len; i++) args[i - 1] = desugar(e.children[i]);
			AstNode*[] call_args = mem::new_array(AstNode*, args.len + 1);
			call_args[0] = make_var("r");
			for (int i = 0; i < args.len; i++) call_args[i + 1] = args[i];
			AstNode* get = make_get(make_var("r"), make_lit(mk_str(m)));
			AstNode* call = make_call(get, call_args);
			AstNode* lam = make_lambda({ "r" }, call);
			return make_call(lam, { recv });
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
			rec.bindings[0].value = init.value;
			return eval(node.children[1], rec);
		}
		case SEQ:
		case BINOP:
		case METHODCALL:
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
