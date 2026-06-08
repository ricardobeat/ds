module engine;
import std::io;
import std::collections;
import std::collections::map;
import std::core::dstring;

// ============================================================================
// C INTEROP (plugin loading via dlopen)
// ============================================================================

extern fn void* dlopen(char* path, int mode);
extern fn void* dlsym(void* handle, char* symbol);
extern fn int dlclose(void* handle);
const int RTLD_NOW = 2;

// DsResult matches the C struct layout in ds_plugin.h: { ulong value; int thrown; }
struct DsResult {
	ulong value;
	int thrown;
}

// C-side host function signature: DsResult fn(ulong* args, int nargs)
alias DsCFn = fn DsResult(ulong* args, int nargs);

// DsApi struct matches ds_plugin.h layout (12 function pointers, 8 bytes each).
struct DsApi {
	void* mk_num;
	void* mk_nil;
	void* mk_bool;
	void* mk_str;
	void* as_num;
	void* as_bool;
	void* is_num;
	void* is_nil;
	void* is_str;
	void* as_cstr;
	void* show;
	void* register_fn;
}

// Plugin init signature: void ds_init(DsApi* api)
alias DsInitFn = fn void(DsApi*);

// Plugin C function pointers (parallel to g_host_fns, null for C3 functions).
void*[MAX_HOST_FNS] g_c_host_fns;

// Track loaded library handles for cleanup.
const int MAX_LIBS = 8;
void*[MAX_LIBS] g_lib_handles;
int g_lib_count = 0;

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

enum TypeKind : char {
	TNAME,
	TARRAY,
	TRECORD,
	TSUM
}

struct Type {
	TypeKind kind;
	String name; // TName
	Type* elem; // TArray  (heap, not by value: avoids recursive struct)
	String[] keys; // TRecord field names / TSum tag names
	Type*[] types; // TRecord field types / TSum tag types (pointers to avoid recursion)
}

fn Type mk_tname(String n) {
	Type t;
	t.kind = TNAME;
	t.name = n;
	return t;
}

fn Type mk_tarray(Type e) {
	Type t;
	t.kind = TARRAY;
	Type* p = mem::tnew(Type);
	*p = e;
	t.elem = p;
	return t;
}

fn Type mk_trecord_ptr(String[] ks, Type*[] ts) {
	assert(ks.len == ts.len);
	Type t;
	t.kind = TRECORD;
	t.keys = ks;
	t.types = ts;
	return t;
}

fn Type mk_trecord(String[] ks, Type[] ts) {
	assert(ks.len == ts.len);
	Type*[] ps = mem::talloc_array(Type*, ts.len);
	for (int i = 0; i < ts.len; i++) {
		ps[i] = mem::tnew(Type);
		*ps[i] = ts[i];
	}
	return mk_trecord_ptr(ks, ps);
}

fn Type mk_tsum(String[] tags, Type[] ts) {
	assert(tags.len == ts.len);
	Type t;
	t.kind = TSUM;
	t.keys = tags;
	Type*[] ps = mem::talloc_array(Type*, ts.len);
	for (int i = 0; i < ts.len; i++) {
		ps[i] = mem::tnew(Type);
		*ps[i] = ts[i];
	}
	t.types = ps;
	return t;
}

// Compile-time type table: name -> Type.  Linear search; tenv is tiny.
fn TypeDefEntry* tenv_lookup(TypeDefEntry* tenv, String name) {
	for (TypeDefEntry* e = tenv; e != null; e = e.next) {
		if (e.name == name) return e;
	}
	return null;
}

fn TypeDefEntry* tenv_extend(TypeDefEntry* tenv, String name, Type type) {
	TypeDefEntry* e = mem::tnew(TypeDefEntry);
	e.name = name;
	e.type = type;
	e.next = tenv;
	return e;
}
// ============================================================================
// NaN-BOXED VALUE
// ============================================================================
//
// IEEE-754 quiet NaN has the exponent 0x7FF and a non-zero mantissa; we
// define a sentinel `NAN_BITS = 0x7FF8...0` and pack type tags into the
// upper 16 bits while leaving the low 48 bits for either a payload (bool)
// or a 48-bit pointer (heap objects: Array, Record, Closure, Prim, String*).
// Real doubles don't have all those bits set, so `v & NAN_BITS != NAN_BITS`
// is the "is number" test.  Result: every Value fits in 8 bytes, so a
// stack/cache line holds 8× more values than the old 40-byte struct.

typedef Value = ulong;

const ulong NAN_BITS    = 0x7FF8000000000000UL;
const ulong TAG_MASK    = 0xFFFF000000000000UL;
const ulong PTR_MASK    = 0x0000FFFFFFFFFFFFUL;

const ulong TAG_NIL     = 0x7FFC000000000000UL;
const ulong TAG_BOOL    = 0x7FFD000000000000UL;
const ulong TAG_STR     = 0x7FFE000000000000UL;
const ulong TAG_ARRAY   = 0x7FFF000000000000UL;
const ulong TAG_RECORD  = 0x7FF9000000000000UL;
const ulong TAG_CLOSURE = 0x7FFA000000000000UL;
const ulong TAG_PRIM    = 0x7FFB000000000000UL;
const ulong TAG_SIGNAL  = 0x7FF8000000000000UL;

// High bit in Env.count signals "this Env doubles as a closure" — its
// union carries closure_params instead of bindings.
const uint CLOSURE_BIT  = 0x80000000;

fn Value val_num(double d)   => (Value)bitcast(d, ulong);
fn Value val_nil()           => (Value)TAG_NIL;
fn Value val_bool(bool b)    => (Value)(TAG_BOOL | (ulong)b);
fn Value val_str(String* p)  => (Value)(TAG_STR    | ((ulong)(uptr)p & PTR_MASK));
fn Value val_arr(Array* p)   => (Value)(TAG_ARRAY  | ((ulong)(uptr)p & PTR_MASK));
fn Value val_rec(Record* p)  => (Value)(TAG_RECORD | ((ulong)(uptr)p & PTR_MASK));
fn Value val_closure(Closure* p) => (Value)(TAG_CLOSURE | ((ulong)(uptr)p & PTR_MASK));
fn Value val_prim(Prim* p)   => (Value)(TAG_PRIM   | ((ulong)(uptr)p & PTR_MASK));
fn Value val_signal(Signal* p)  => (Value)(TAG_SIGNAL  | ((ulong)(uptr)p & PTR_MASK));

fn bool   is_num(Value v)    => ((ulong)v & NAN_BITS) != NAN_BITS;
fn bool   is_nil(Value v)    => (ulong)v == TAG_NIL;
fn bool   is_bool(Value v)   => ((ulong)v & TAG_MASK) == TAG_BOOL;
fn bool   is_str(Value v)    => ((ulong)v & TAG_MASK) == TAG_STR;
fn bool   is_arr(Value v)    => ((ulong)v & TAG_MASK) == TAG_ARRAY;
fn bool   is_rec(Value v)    => ((ulong)v & TAG_MASK) == TAG_RECORD;
fn bool   is_closure(Value v) => ((ulong)v & TAG_MASK) == TAG_CLOSURE;
fn bool   is_prim(Value v)   => ((ulong)v & TAG_MASK) == TAG_PRIM;
fn bool   is_signal(Value v)  => ((ulong)v & TAG_MASK) == TAG_SIGNAL;

fn double   as_num(Value v)    => bitcast((ulong)v, double);
fn bool     as_bool(Value v)   => (bool)((ulong)v & 1);
fn String*  as_str(Value v)    => (String*)(uptr)((ulong)v & PTR_MASK);
fn Array*   as_arr(Value v)    => (Array*)(uptr)((ulong)v & PTR_MASK);
fn Record*  as_rec(Value v)    => (Record*)(uptr)((ulong)v & PTR_MASK);
fn Closure* as_closure(Value v) => (Closure*)(uptr)((ulong)v & PTR_MASK);
fn Prim*    as_prim(Value v)   => (Prim*)(uptr)((ulong)v & PTR_MASK);
fn Signal*  as_signal(Value v)  => (Signal*)(uptr)((ulong)v & PTR_MASK);

// Convenience tag enum for runtime type queries / debug printing.
// Numeric values match the `ordinal()` of the old ValueType for tests
// that asserted on a `.type.ordinal` field.
enum ValueTag : int {
	NUM,
	NIL,
	BOOL,
	STRING,
	ARRAY,
	RECORD,
	CLOSURE,
	PRIMITIVE,
	SIGNAL,
}

fn ValueTag tag_of(Value v) {
	if (is_num(v))     return NUM;
	if (is_nil(v))     return NIL;
	if (is_bool(v))    return BOOL;
	if (is_str(v))     return STRING;
	if (is_arr(v))     return ARRAY;
	if (is_rec(v))     return RECORD;
	if (is_closure(v)) return CLOSURE;
	return PRIMITIVE;
}

// ============================================================================
// INTERN TABLE
// ============================================================================
//
// A process-global, persistent string pool.  Every distinct field name ever
// looked up gets a compact, dense `uint` atom ID (1, 2, 3, ...).  The
// `HashMap{String, uint}` is the forward direction (used at parse + eval time
// to convert a `String` key into an atom).  The `String[]` array is the
// reverse direction (used by `show()` and a few error messages to turn an
// atom back into its human-readable name).
//
// Both backing arrays are heap-allocated (`mem::new_*`) so they survive the
// `@pool` blocks used for parsing.  The map stores a copy of each string for
// the same reason — the caller's slice may be a temp.

struct InternTable {
	HashMap{String, uint}* fwd;   // String -> atom ID
	String[]               rev;   // atom ID - 1 -> name
	uint                   count; // number of atoms allocated
	uint                   cap;   // capacity of `rev`
}

InternTable g_intern;

fn void intern_init() {
	g_intern.fwd = mem::new(HashMap{String, uint});
	g_intern.fwd.init(mem, 64);
	g_intern.count = 0;
	g_intern.cap = 32;
	g_intern.rev = mem::new_array(String, g_intern.cap);
}

// Look up (or allocate) an atom ID for `s`.  The string is copied into
// heap-owned storage so callers can pass temp-pool slices.  Lazily
// initializes the table on first use so test code (which doesn't go
// through `main`) gets a valid intern table for free.
fn uint intern(String s) {
	if (g_intern.fwd == null) intern_init();
	if (try id = g_intern.fwd.get(s)) return id;
	if (g_intern.count >= g_intern.cap) {
		uint new_cap = g_intern.cap * 2;
		g_intern.rev = alloc::realloc_array(mem, g_intern.rev, String, new_cap);
		g_intern.cap = new_cap;
	}
	String heap_s = s.copy(mem);
	g_intern.count++;
	g_intern.rev[g_intern.count - 1] = heap_s;
	g_intern.fwd.set(heap_s, g_intern.count);
	return g_intern.count;
}

// Reverse lookup: atom ID -> original name.  Returns "" for out-of-range IDs
// (0 is reserved as a "no atom" sentinel; the only legitimate ID > 0).
fn String atom_name(uint id) {
	if (id == 0 || id > g_intern.count) return "";
	return g_intern.rev[id - 1];
}

// ============================================================================
// HEAP TYPES
// ============================================================================

struct Array {
	uint refcount;
	Value[] items;
}

// Record keys are interned atom IDs (`uint`) instead of full `String`s.
// GET / SET / `has_field` do a linear scan; comparing two `uint`s is ~3-4×
// faster than comparing two `String` slices, and an atom is 4 bytes instead
// of 16.  The reverse table (atom ID -> original name) lives in the global
// `g_intern` and is used only for `show()` and error messages.
struct Record {
	uint   refcount;
	uint[] keys;
	Value[] values;
}

struct Closure {
	uint refcount;
	uint[] param_ids;
	AstNode* body;
	Env* env;
}

// A primitive is a named builtin.  We carry the name as a String and dispatch
// at apply time; carrying the name keeps debugging output honest.
struct Prim {
	String name;
}

// ============================================================================
// REACTIVE TYPES (signals + derived)
// ============================================================================
//
// Signal: a mutable reactive cell.  signal_set notifies all subscribers.
// When kind == DERIVED, it is a lazy computed value that caches its result
// and re-evaluates only when a dependency changes and its value is read.
// DepNode: intrusive linked-list node for the subscriber/dep chains.

enum SignalKind : char { SIG_PLAIN, SIG_DERIVED }

struct DepNode {
	DepNode* next;
	Value    target;  // TAG_SIGNAL Value (NaN-boxed pointer)
}

struct Signal {
	uint       refcount;
	SignalKind kind;
	Value      current;    // SIG_PLAIN: the stored value; SIG_DERIVED: cached result
	bool       dirty;      // SIG_DERIVED only
	bool       running;    // SIG_DERIVED only (circular dep guard)
	Closure*   closure;    // SIG_DERIVED only (0-arg computation)
	DepNode*   deps;       // SIG_DERIVED only (what I depend on)
	DepNode*   subs;       // both: who depends on me
}

fn bool signal_is_derived(Signal* s) => s.kind == SIG_DERIVED;

// An active effect: a closure that re-runs when its deps change.
struct Effect {
	Closure* func;
	DepNode* deps;
	Effect*  next;        // global linked list of all active effects
	bool     running;     // guard against re-entrant re-runs
}

// ============================================================================
// AST NODES (kernel + a few surface that are still in the file for tests)
// ============================================================================
// 
// Uniform node: `name` for single-name nodes (VAR, PRIM, LETREC, TRY catch),
// `literal` for LIT, `names` parallel to `children` for record fields and
// lambda param names, and `children` for the rest.

enum NodeType : char {
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

struct TypeDefEntry {
	String name;
	Type type;
	TypeDefEntry* next;
}

struct AstNode {
	NodeType type;
	String name;
	uint name_id;
	Value literal;
	String[] names;
	uint[] name_ids;
	AstNode*[] children;
	// Surface-only annotation payload (LAMBDA_T, LET_T).  These are erased
	// during desugaring; the kernel evaluator never sees them.
	Type*[] param_types;
	Type* ret_type;
	Type* ann_type; // LET_T: type of the initializer
}

// ============================================================================
// BINDING (name-value pair for Env frames)
// ============================================================================

struct Binding {
	uint name_id;
	Value value;
}

// ============================================================================
// ENVIRONMENT (lexical scope, parent chain)
// ============================================================================
//
// Optimised for the hot path: single-param closures (fib, etc.) use inline
// storage inside the Env struct itself, eliminating a separate array alloc.
// Multi-param frames use a heap-allocated Binding[].

union EnvData {
	Value value;
	AstNode* lambda_node;
	Binding* bindings_ptr;
}

struct Env {
	Env* parent;
	uint refcount;
	uint count;
	uint name_id;
	EnvData data;
}

// ============================================================================
// EVAL RESULT
// ============================================================================
// 
// Throw needs to carry a value back to Try without unwinding C3's stack via a
// fault.  We return a small struct; the `thrown` flag is the discriminator.

struct EvalResult {
	bool thrown;
	Value value;
	bool is_tail;
	AstNode* tail_node;
	Env* tail_env;
}

// ============================================================================
// CONSTRUCTORS
// ============================================================================

fn Value mk_nil()    => val_nil();
fn Value mk_bool(bool b)    => val_bool(b);
fn Value mk_num(double n)   => val_num(n);

// mk_str: box a string slice. The slice itself points to backing memory
// (either static string literals or a heap-allocated concat buffer); the
// 16-byte `String` struct we wrap it in lives in the temp pool and follows
// the same lifetime as the slice. The Value only carries the 8-byte
// pointer to the `String*`.
fn Value mk_str(String s) {
	String* p = mem::tnew(String);
	*p = s;
	return val_str(p);
}

// mk_prim: the prim carries a name; we now put the `Prim` struct on the
// heap so the 8-byte Value can point at it.
fn Value mk_prim(String n) {
	Prim* p = mem::tnew(Prim);
	p.name = n;
	return val_prim(p);
}

fn Array* new_array() {
	Array* a = mem::new(Array);
	a.refcount = 1;
	return a;
}
fn Record* new_record() {
	Record* r = mem::new(Record);
	r.refcount = 1;
	return r;
}
fn Closure* new_closure() {
	Closure* c = mem::new(Closure);
	c.refcount = 1;
	return c;
}
fn Prim* new_prim(String n) {
	Prim* p = mem::tnew(Prim);
	p.name = n;
	return p;
}

fn Signal* new_signal(Value init) {
	Signal* s = mem::new(Signal);
	s.refcount = 1;
	s.kind = SIG_PLAIN;
	s.current = init;
	s.dirty = false;
	s.running = false;
	s.closure = null;
	s.deps = null;
	s.subs = null;
	return s;
}

fn Signal* new_derived(Closure* closure) {
	Signal* s = mem::new(Signal);
	s.refcount = 1;
	s.kind = SIG_DERIVED;
	s.current = mk_nil();
	s.dirty = true;
	s.running = false;
	s.closure = closure;
	s.deps = null;
	s.subs = null;
	return s;
}

fn Effect* new_effect(Closure* func) {
	Effect* e = mem::new(Effect);
	e.func = func;
	e.deps = null;
	e.next = null;
	e.running = false;
	return e;
}

fn AstNode* make_lit(Value v) {
	AstNode* n = mem::tnew(AstNode);
	n.type = LIT;
	n.literal = v;
	return n;
}

fn AstNode* make_var(String name) {
	AstNode* n = mem::tnew(AstNode);
	n.type = VAR;
	n.name = name;
	n.name_id = intern(name);
	return n;
}

fn AstNode* make_lambda(String[] params, AstNode* body) {
	// Copy `params` to heap — the caller's slice literal `{ "x", "y" }` is a
	// stack temp and would dangle once we return.
	AstNode* n = mem::tnew(AstNode);
	n.type = LAMBDA;
	String[] heap_params = mem::talloc_array(String, params.len);
	uint[] param_ids = mem::talloc_array(uint, params.len);
	for (int i = 0; i < params.len; i++) {
		heap_params[i] = params[i];
		param_ids[i] = intern(params[i]);
	}
	n.names = heap_params;
	n.name_ids = param_ids;
	AstNode*[] kids = mem::talloc_array(AstNode*, 1);
	kids[0] = body;
	n.children = kids;
	return n;
}

fn AstNode* make_call(AstNode* fn_node, AstNode*[] args) {
	AstNode*[] kids = mem::talloc_array(AstNode*, args.len + 1);
	kids[0] = fn_node;
	for (int i = 0; i < args.len; i++) kids[i + 1] = args[i];
	AstNode* n = mem::tnew(AstNode);
	n.type = CALL;
	n.children = kids;
	return n;
}

fn AstNode* make_if(AstNode* c, AstNode* t, AstNode* e) {
	AstNode* n = mem::tnew(AstNode);
	n.type = IF;
	AstNode*[] kids = mem::talloc_array(AstNode*, 3);
	kids[0] = c;
	kids[1] = t;
	kids[2] = e;
	n.children = kids;
	return n;
}

fn AstNode* make_record(String[] keys, AstNode*[] vals) {
	assert(keys.len == vals.len);
	// Same heap-copy rationale as make_lambda: `keys` is usually a stack temp.
	AstNode* n = mem::tnew(AstNode);
	n.type = RECORD;
	String[] heap_keys = mem::talloc_array(String, keys.len);
	uint[] key_ids = mem::talloc_array(uint, keys.len);
	for (int i = 0; i < keys.len; i++) {
		heap_keys[i] = keys[i];
		key_ids[i] = intern(keys[i]);
	}
	n.names = heap_keys;
	n.name_ids = key_ids;
	n.children = vals;
	return n;
}

fn AstNode* make_array(AstNode*[] items) {
	AstNode* n = mem::tnew(AstNode);
	n.type = ARRAY_LIT;
	n.children = items;
	return n;
}

fn AstNode* make_get(AstNode* obj, AstNode* key) {
	AstNode* n = mem::tnew(AstNode);
	n.type = GET;
	AstNode*[] kids = mem::talloc_array(AstNode*, 2);
	kids[0] = obj;
	kids[1] = key;
	n.children = kids;
	return n;
}

fn AstNode* make_set(AstNode* obj, AstNode* key, AstNode* val) {
	AstNode* n = mem::tnew(AstNode);
	n.type = SET;
	AstNode*[] kids = mem::talloc_array(AstNode*, 3);
	kids[0] = obj;
	kids[1] = key;
	kids[2] = val;
	n.children = kids;
	return n;
}

fn AstNode* make_throw(AstNode* v) {
	AstNode* n = mem::tnew(AstNode);
	n.type = THROW;
	AstNode*[] kids = mem::talloc_array(AstNode*, 1);
	kids[0] = v;
	n.children = kids;
	return n;
}

fn AstNode* make_try(AstNode* body, String cname, AstNode* handler) {
	AstNode* n = mem::tnew(AstNode);
	n.type = TRY;
	n.name = cname;
	n.name_id = intern(cname);
	AstNode*[] kids = mem::talloc_array(AstNode*, 2);
	kids[0] = body;
	kids[1] = handler;
	n.children = kids;
	return n;
}

fn AstNode* make_prim_node(String name) {
	AstNode* n = mem::tnew(AstNode);
	n.type = PRIM;
	n.name = name;
	n.name_id = intern(name);
	return n;
}

fn AstNode* make_letrec(String name, AstNode* init, AstNode* body) {
	AstNode* n = mem::tnew(AstNode);
	n.type = LETREC;
	n.name = name;
	n.name_id = intern(name);
	AstNode*[] kids = mem::talloc_array(AstNode*, 2);
	kids[0] = init;
	kids[1] = body;
	n.children = kids;
	return n;
}

fn AstNode* make_seq(AstNode*[] exprs) {
	AstNode* n = mem::tnew(AstNode);
	n.type = SEQ;
	n.children = exprs;
	return n;
}

fn AstNode* make_binop_node(String op, AstNode* lhs, AstNode* rhs) {
	AstNode* n = mem::tnew(AstNode);
	n.type = BINOP;
	n.name = op;
	n.name_id = intern(op);
	AstNode*[] kids = mem::talloc_array(AstNode*, 2);
	kids[0] = lhs;
	kids[1] = rhs;
	n.children = kids;
	return n;
}

fn AstNode* make_methodcall(AstNode* recv, String name, AstNode*[] args) {
	AstNode* n = mem::tnew(AstNode);
	n.type = METHODCALL;
	n.name = name;
	n.name_id = intern(name);
	AstNode*[] kids = mem::talloc_array(AstNode*, args.len + 1);
	kids[0] = recv;
	for (int i = 0; i < args.len; i++) kids[i + 1] = args[i];
	n.children = kids;
	return n;
}

// ============================================================================
// VALUE HELPERS
// ============================================================================

fn bool truthy(Value v) {
	if (is_nil(v)) return false;
	if (is_bool(v)) return as_bool(v);
	return true;
}

// ---------------------------------------------------------------------------
// Surface constructors (Rung 1 + Rung 2) — exposed to both tests and parser
// ---------------------------------------------------------------------------

fn AstNode* make_typed_lambda(String[] names, Type*[] param_types, Type* ret_type, AstNode* body) {
	AstNode* n = mem::tnew(AstNode);
	n.type = LAMBDA_T;
	String[] heap_names = mem::talloc_array(String, names.len);
	uint[] name_ids_arr = mem::talloc_array(uint, names.len);
	for (int i = 0; i < names.len; i++) {
		heap_names[i] = names[i];
		name_ids_arr[i] = intern(names[i]);
	}
	n.names = heap_names;
	n.name_ids = name_ids_arr;
	n.param_types = param_types;
	n.ret_type = ret_type;
	AstNode*[] kids = mem::talloc_array(AstNode*, 1);
	kids[0] = body;
	n.children = kids;
	return n;
}

fn AstNode* make_typed_let(String name, Type* ann_type, AstNode* init, AstNode* body) {
	AstNode* n = mem::tnew(AstNode);
	n.type = LET_T;
	n.name = name;
	n.name_id = intern(name);
	n.ann_type = ann_type;
	AstNode*[] kids = mem::talloc_array(AstNode*, 2);
	kids[0] = init;
	kids[1] = body;
	n.children = kids;
	return n;
}

fn AstNode* make_typedef(String name, Type* t, AstNode* body) {
	AstNode* n = mem::tnew(AstNode);
	n.type = TYPEDEF;
	n.name = name;
	n.name_id = intern(name);
	n.ret_type = t;
	AstNode*[] kids = mem::talloc_array(AstNode*, 1);
	kids[0] = body;
	n.children = kids;
	return n;
}

fn AstNode* make_construct(String tag, AstNode* val) {
	AstNode* n = mem::tnew(AstNode);
	n.type = CONSTRUCT;
	n.name = tag;
	n.name_id = intern(tag);
	AstNode*[] kids = mem::talloc_array(AstNode*, 1);
	kids[0] = val;
	n.children = kids;
	return n;
}

fn AstNode* make_match(AstNode* scrut, String[] tags, String[] binds, AstNode*[] bodies) {
	assert(tags.len == binds.len);
	assert(tags.len == bodies.len);
	AstNode* n = mem::tnew(AstNode);
	n.type = MATCH;
	String[] nm = mem::talloc_array(String, 2 * tags.len);
	uint[] nm_ids = mem::talloc_array(uint, 2 * tags.len);
	AstNode*[] kids = mem::talloc_array(AstNode*, bodies.len + 1);
	kids[0] = scrut;
	for (int i = 0; i < tags.len; i++) {
		nm[2 * i] = tags[i];
		nm[2 * i + 1] = binds[i];
		nm_ids[2 * i] = intern(tags[i]);
		nm_ids[2 * i + 1] = intern(binds[i]);
		kids[i + 1] = bodies[i];
	}
	n.names = nm;
	n.name_ids = nm_ids;
	n.children = kids;
	return n;
}

fn bool strict_eq(Value a, Value b) {
	if ((ulong)a != (ulong)b) {
		// Different raw bits — could still be equal NaN numbers; we
		// treat NaN-boxed identity as strict_eq at the bit level. Two
		// numbers are equal iff their bits match (i.e. as_num is equal).
		if (is_num(a) && is_num(b)) return as_num(a) == as_num(b);
		// Strings compare content.
		if (is_str(a) && is_str(b)) return *as_str(a) == *as_str(b);
		// Primitives compare name.
		if (is_prim(a) && is_prim(b)) return as_prim(a).name == as_prim(b).name;
		// nil == nil handled by the raw-bit check above.
		// Array/Record/Closure: same pointer (already covered by raw-bit).
		return false;
	}
	// Raw bits equal — including same-pointer heap objects and identical
	// small payloads.
	return true;
}

fn Value show(Value v) {
	if (is_nil(v)) return mk_str("nil");
	if (is_bool(v)) return mk_str(as_bool(v) ? "true" : "false");
	if (is_num(v)) {
		double n = as_num(v);
		if (n == (double)(long)n) {
			return mk_str(string::tformat("%d", (long)n));
		}
		return mk_str(string::tformat("%s", n));
	}
	if (is_str(v)) return mk_str(string::tformat("%s", *as_str(v)));
	if (is_arr(v)) {
		Array* a = as_arr(v);
		DString buf;
		buf.init(mem);
		buf.append_char('[');
		for (int i = 0; i < a.items.len; i++) {
			if (i > 0) buf.append(", ");
			Value s = show(a.items[i]);
			buf.append(*as_str(s));
		}
		buf.append_char(']');
		return mk_str(buf.str_view());
	}
	if (is_rec(v)) {
		Record* r = as_rec(v);
		DString buf;
		buf.init(mem);
		buf.append_char('{');
		for (int i = 0; i < r.keys.len; i++) {
			if (i > 0) buf.append(", ");
			buf.append(atom_name(r.keys[i]));
			buf.append(": ");
			Value s = show(r.values[i]);
			buf.append(*as_str(s));
		}
		buf.append_char('}');
		return mk_str(buf.str_view());
	}
	if (is_closure(v)) {
		Closure* c = as_closure(v);
		DString buf;
		buf.init(mem);
		buf.append("<closure(");
		for (int i = 0; i < c.param_ids.len; i++) {
			if (i > 0) buf.append(", ");
			buf.append(atom_name(c.param_ids[i]));
		}
		buf.append(")>");
		return mk_str(buf.str_view());
	}
	if (is_prim(v)) return mk_str(string::tformat("<prim %s>", as_prim(v).name));
	if (is_signal(v)) {
		Signal* sig = as_signal(v);
		if (signal_is_derived(sig)) {
			if (sig.dirty) return mk_str("<derived (dirty)>");
			Value s = show(sig.current);
			return mk_str(string::tformat("<derived %s>", *as_str(s)));
		}
		Value s = show(sig.current);
		return mk_str(string::tformat("<signal %s>", *as_str(s)));
	}
	return mk_nil();
}

// ============================================================================
// ENV HELPERS
// ============================================================================

// --- Reference counting for heap-allocated objects ---

fn void rc_inc_env(Env* e) {
	if (e != null) e.refcount++;
}

fn void rc_dec_env(Env* e) {
	if (e == null) return;
	e.refcount--;
	if (e.refcount == 0) {
		// rc_dec bindings
		if (e.count == 1 && !(e.count & CLOSURE_BIT)) {
			rc_dec_val(e.data.value);
		} else if (e.count > 1 && !(e.count & CLOSURE_BIT)) {
			Binding* bp = e.data.bindings_ptr;
			for (uint i = 0; i < e.count; i++) {
				rc_dec_val(bp[i].value);
			}
		}
		rc_dec_env(e.parent);
		mem::free(e);
	}
}

fn void rc_inc_val(Value v) {
	if (is_arr(v)) {
		as_arr(v).refcount++;
	} else if (is_rec(v)) {
		as_rec(v).refcount++;
	} else if (is_closure(v)) {
		as_closure(v).refcount++;
	}
}

fn void rc_dec_val(Value v) {
	if (is_arr(v)) {
		Array* a = as_arr(v);
		a.refcount--;
		if (a.refcount == 0) mem::free(a);
	} else if (is_rec(v)) {
		Record* r = as_rec(v);
		r.refcount--;
		if (r.refcount == 0) mem::free(r);
	} else if (is_closure(v)) {
		Closure* c = as_closure(v);
		c.refcount--;
		if (c.refcount == 0) {
			rc_dec_env(c.env);
			mem::free(c);
		}
	}
}

// Single-param fast path: zero array allocations for the hot fib/closure case.
fn Env* env_extend1(Env* parent, uint name_id, Value value) {
	Env* e = mem::new(Env);
	e.parent = parent;
	e.count = 1;
	e.name_id = name_id;
	e.data.value = value;
	return e;
}

// Multi-param path: wraps caller-provided arrays into a Binding[].
fn Env* env_extend(Env* parent, uint[] name_ids, Value[] values) {
	int n = name_ids.len;
	Env* e = mem::new(Env);
	e.parent = parent;
	if (n == 1) {
		e.count = 1;
		e.name_id = name_ids[0];
		e.data.value = values[0];
	} else {
		e.count = (uint)n;
		Binding* bp = mem::talloc_array(Binding, n);
		for (int i = 0; i < n; i++) {
			bp[i] = { .name_id = name_ids[i], .value = values[i] };
		}
		e.data.bindings_ptr = bp;
	}
	return e;
}

// Single-binding define (LETREC, TRY catch): inline, no array alloc.
fn Env* env_define(Env* parent, uint name_id, Value v) {
	Env* e = mem::new(Env);
	e.parent = parent;
	e.count = 1;
	e.name_id = name_id;
	e.data.value = v;
	return e;
}

// LetRec+Lambda define: the Env doubles as a closure, carrying the
// lambda's param_ids and body inline.  The body pointer is stored in
// inline_value (reinterpreted as a raw pointer — unused as a Value for
// closure envs).  The CALL fast path detects `count & CLOSURE_BIT` and
// calls the closure directly, avoiding a separate Closure heap alloc.
fn Env* env_define_closure(Env* parent, uint name_id, AstNode* lambda_node) {
	Env* e = mem::new(Env);
	e.parent = parent;
	e.count = 1 | CLOSURE_BIT;
	e.name_id = name_id;
	e.data.lambda_node = lambda_node;
	return e;
}

fn Value env_lookup(Env* env, uint name_id, bool* found = null, Env** source = null) {
	Env* cur = env;
	while (cur != null) {
		if (cur.count == 1 || (cur.count & CLOSURE_BIT)) {
			if (cur.name_id == name_id) {
				if (found != null) *found = true;
				if (source != null) *source = cur;
				return cur.data.value;
			}
		} else {
			Binding* bp = cur.data.bindings_ptr;
			for (uint i = 0; i < cur.count; i++) {
				if (bp[i].name_id == name_id) {
					if (found != null) *found = true;
					return bp[i].value;
				}
			}
		}
		cur = cur.parent;
	}
	if (found != null) *found = false;
	return mk_nil();
}

fn void env_set(Env* env, uint name_id, Value v) {
	Env* cur = env;
	while (cur != null) {
		if (cur.count == 1 || (cur.count & CLOSURE_BIT)) {
			if (cur.name_id == name_id) {
				cur.data.value = v;
				return;
			}
		} else {
			Binding* bp = cur.data.bindings_ptr;
			for (uint i = 0; i < cur.count; i++) {
				if (bp[i].name_id == name_id) {
					bp[i].value = v;
					return;
				}
			}
		}
		cur = cur.parent;
	}
	if (env.count == 1) {
		Binding* bp = mem::talloc_array(Binding, 2);
		bp[0] = { .name_id = env.name_id, .value = env.data.value };
		bp[1] = { .name_id = name_id, .value = v };
		env.data.bindings_ptr = bp;
		env.count = 2;
	} else {
		Binding* old = env.data.bindings_ptr;
		long old_len = env.count;
		Binding* grown = mem::talloc_array(Binding, old_len + 1);
		for (int i = 0; i < old_len; i++) grown[i] = old[i];
		grown[old_len] = { .name_id = name_id, .value = v };
		env.data.bindings_ptr = grown;
		env.count = (uint)(old_len + 1);
	}
}

// ============================================================================
// PRIMITIVES
// ============================================================================
// 
// Each primitive returns an EvalResult because some (like `array_all`) need
// control flow that would otherwise re-enter eval in a confusing way.

// ============================================================================
// HOST FUNCTION TABLE (for embedding)
// ============================================================================

alias HostFn = fn EvalResult(Value[] args);

const int MAX_HOST_FNS = 64;
HostFn[MAX_HOST_FNS] g_host_fns;
String[MAX_HOST_FNS] g_host_fn_names;
int g_host_fn_count = 0;

fn bool register_host_fn(String name, HostFn func) {
	if (g_host_fn_count >= MAX_HOST_FNS) return false;
	g_host_fn_names[g_host_fn_count] = name;
	g_host_fns[g_host_fn_count] = func;
	g_host_fn_count++;
	return true;
}

fn bool register_c_host_fn(String name, void* c_fn) {
	if (g_host_fn_count >= MAX_HOST_FNS) return false;
	g_host_fn_names[g_host_fn_count] = name;
	g_host_fns[g_host_fn_count] = null;
	g_c_host_fns[g_host_fn_count] = c_fn;
	g_host_fn_count++;
	return true;
}

fn bool has_host_fn(String name) {
	for (int i = 0; i < g_host_fn_count; i++) {
		if (name == g_host_fn_names[i]) return true;
	}
	return false;
}

fn EvalResult call_host_fn(String name, Value[] args) {
	for (int i = 0; i < g_host_fn_count; i++) {
		if (name == g_host_fn_names[i]) {
			if (g_c_host_fns[i] != null) return call_c_plugin(g_c_host_fns[i], args);
			return g_host_fns[i](args);
		}
	}
	return { .thrown = true, .value = mk_str("host function not found") };
}

// Adapter: convert between C3 Value[] and C DsValue*/nargs, call the C function.
fn EvalResult call_c_plugin(void* c_fn, Value[] args) {
	ulong[16] c_args;
	int nargs = (int)args.len;
	for (int i = 0; i < nargs && i < 16; i++) {
		c_args[i] = (ulong)args[i];
	}
	DsCFn fn_ptr = (DsCFn)c_fn;
	DsResult r = fn_ptr(&c_args, nargs);
	return { .thrown = r.thrown != 0, .value = (Value)r.value };
}

// ============================================================================
// PLUGIN API (DsApi wrappers + loadlib primitive)
// ============================================================================

fn ulong api_mk_num(double d) => (ulong)mk_num(d);
fn ulong api_mk_nil() => (ulong)mk_nil();
fn ulong api_mk_bool(int b) => (ulong)mk_bool(b != 0);
fn double api_as_num(ulong v) => as_num((Value)v);
fn int api_as_bool(ulong v) => as_bool((Value)v) ? 1 : 0;
fn int api_is_num(ulong v) => is_num((Value)v) ? 1 : 0;
fn int api_is_nil(ulong v) => is_nil((Value)v) ? 1 : 0;
fn int api_is_str(ulong v) => is_str((Value)v) ? 1 : 0;

fn ulong api_mk_str(char* c) {
	sz len = 0;
	while (c[len] != 0) len++;
	String s = (String)c[0:len];
	return (ulong)mk_str(s);
}

fn char* api_as_cstr(ulong v) {
	String* sp = as_str((Value)v);
	return sp.ptr;
}

fn char* api_show(ulong v) {
	Value s = show((Value)v);
	String* sp = as_str(s);
	return sp.ptr;
}

fn int api_register_fn(char* name, void* c_fn) {
	sz len = 0;
	while (name[len] != 0) len++;
	String s = (String)name[0:len];
	bool ok = register_c_host_fn(s, c_fn);
	if (ok && builtin_env != null) {
		uint id = intern(s);
		Binding new_binding = { .name_id = id, .value = mk_prim(s) };
		Binding* old = builtin_env.data.bindings_ptr;
		uint n = builtin_env.count;
		Binding* grown = mem::talloc_array(Binding, (sz)(n + 1));
		for (uint i = 0; i < n; i++) grown[i] = old[i];
		grown[n] = new_binding;
		builtin_env.data.bindings_ptr = grown;
		builtin_env.count = n + 1;
	}
	return ok ? 1 : 0;
}

fn EvalResult loadlib_fn(Value[] args) {
	if (!is_str(args[0])) {
		return { .thrown = true, .value = mk_str("loadlib expects a string path") };
	}
	char* path = as_str(args[0]).ptr;
	void* handle = dlopen(path, RTLD_NOW);
	if (handle == null) {
		return { .thrown = true, .value = mk_str("loadlib: failed to open library") };
	}
	void* init_sym = dlsym(handle, "ds_init");
	if (init_sym == null) {
		dlclose(handle);
		return { .thrown = true, .value = mk_str("loadlib: no ds_init symbol found") };
	}
	DsApi* api = mem::new(DsApi);
	api.mk_num      = (void*)&api_mk_num;
	api.mk_nil      = (void*)&api_mk_nil;
	api.mk_bool     = (void*)&api_mk_bool;
	api.mk_str      = (void*)&api_mk_str;
	api.as_num      = (void*)&api_as_num;
	api.as_bool     = (void*)&api_as_bool;
	api.is_num      = (void*)&api_is_num;
	api.is_nil      = (void*)&api_is_nil;
	api.is_str      = (void*)&api_is_str;
	api.as_cstr     = (void*)&api_as_cstr;
	api.show        = (void*)&api_show;
	api.register_fn = (void*)&api_register_fn;
	DsInitFn init_fn = (DsInitFn)init_sym;
	init_fn(api);
	if (g_lib_count < MAX_LIBS) {
		g_lib_handles[g_lib_count] = handle;
		g_lib_count++;
	}
	return { .value = mk_nil() };
}

// ============================================================================
// REACTIVE MACHINERY (signals, derived, effects)
// ============================================================================

// Global subscriber tracking: when non-null, any signal_get will register
// the active subscriber as a dependency of the signal being read.
void*  g_active_subscriber;   // Effect* or Derived*
bool   g_active_is_derived;

// Global linked list of all active effects (for cleanup).
Effect* g_effects;

// Element stable-ref state.
int g_element_slot;

fn void dep_push(DepNode** list, Value target) {
	// Avoid duplicate entries — check if target already in list.
	for (DepNode* n = *list; n != null; n = n.next) {
		if (n.target == target) return;
	}
	DepNode* node = mem::new(DepNode);
	node.next = *list;
	node.target = target;
	*list = node;
}

// Register a signal read: link the signal to the active subscriber bidirectionally.
fn void reactive_track(Signal* sig) {
	if (g_active_subscriber == null) return;
	Value sig_val = val_signal(sig);
	// Add signal to the active subscriber's dep list.
	if (g_active_is_derived) {
		Signal* sub = (Signal*)(uptr)g_active_subscriber;
		dep_push(&sub.deps, sig_val);
	} else {
		Effect* e = (Effect*)(uptr)g_active_subscriber;
		dep_push(&e.deps, sig_val);
	}
	// Add the active subscriber to the signal's sub list.
	// Encode derived subscribers as TAG_SIGNAL, effect subscribers as TAG_CLOSURE.
	if (g_active_is_derived) {
		dep_push(&sig.subs, val_signal((Signal*)(uptr)g_active_subscriber));
	} else {
		dep_push(&sig.subs, val_closure(((Effect*)(uptr)g_active_subscriber).func));
	}
}

// Mark a derived (and transitively its derived subscribers) as needing recomputation.
fn void mark_dirty(Signal* d) {
	if (d.dirty) return;
	d.dirty = true;
	for (DepNode* sub = d.subs; sub != null; sub = sub.next) {
		if (is_signal(sub.target)) {
			Signal* s = as_signal(sub.target);
			if (signal_is_derived(s)) mark_dirty(s);
		}
	}
}

// Re-run an effect: clear its old deps, invoke the closure with tracking on.
fn void effect_rerun(Effect* e) {
	if (e.running) return; // prevent re-entrant re-runs
	e.running = true;
	void* prev_sub = g_active_subscriber;
	bool prev_kind = g_active_is_derived;
	g_active_subscriber = e;
	g_active_is_derived = false;
	e.deps = null;
	// Use eval directly (apply_fn returns tail-call thunks).
	eval(e.func.body, e.func.env);
	g_active_subscriber = prev_sub;
	g_active_is_derived = prev_kind;
	e.running = false;
}

// Walk a subscriber list: mark deriveds dirty, re-run effects.
fn void notify_subs(DepNode* subs) {
	for (DepNode* sub = subs; sub != null; sub = sub.next) {
		if (is_signal(sub.target)) {
			Signal* s = as_signal(sub.target);
			if (signal_is_derived(s)) mark_dirty(s);
		} else if (is_closure(sub.target)) {
			for (Effect* e = g_effects; e != null; e = e.next) {
				if (val_closure(e.func) == sub.target) {
					effect_rerun(e);
					break;
				}
			}
		}
	}
}

// Evaluate a derived: recompute if dirty, cache the result.
fn Value derived_evaluate(Signal* d) {
	if (!d.dirty) return d.current;
	if (d.running) return d.current;
	d.running = true;
	void* prev_sub = g_active_subscriber;
	bool prev_kind = g_active_is_derived;
	g_active_subscriber = d;
	g_active_is_derived = true;
	d.deps = null;
	// Use eval() directly (not apply_fn, which returns tail-call thunks).
	Env* call_env = d.closure.env;
	if (d.closure.param_ids.len > 0) {
		call_env = env_extend(d.closure.env, d.closure.param_ids, {});
	}
	EvalResult r = eval(d.closure.body, call_env);
	if (!r.thrown) d.current = r.value;
	d.dirty = false;
	d.running = false;
	g_active_subscriber = prev_sub;
	g_active_is_derived = prev_kind;
	return d.current;
}

// ============================================================================
// PRIMITIVE DISPATCH
// ============================================================================

fn EvalResult prim_dispatch(String name, Value[] args) {
	switch (name) {
		case "+":
			if (is_num(args[0]) && is_num(args[1])) {
				return { .value = mk_num(as_num(args[0]) + as_num(args[1])) };
			}
			if (is_str(args[0]) && is_str(args[1])) {
				return { .value = mk_str((*as_str(args[0])).tconcat(*as_str(args[1]))) };
			}
			// Mixed string+number: coerce via show()
			if (is_str(args[0]) || is_str(args[1])) {
				Value s0 = is_str(args[0]) ? args[0] : show(args[0]);
				Value s1 = is_str(args[1]) ? args[1] : show(args[1]);
				return { .value = mk_str((*as_str(s0)).tconcat(*as_str(s1))) };
			}
			return { .thrown = true, .value = mk_str("type error: + expects number or string") };
		case "-":
			if (!is_num(args[0]) || !is_num(args[1])) {
				return { .thrown = true, .value = mk_str("type error: - expects numbers") };
			}
			return { .value = mk_num(as_num(args[0]) - as_num(args[1])) };
		case "*":
			if (!is_num(args[0]) || !is_num(args[1])) {
				return { .thrown = true, .value = mk_str("type error: * expects numbers") };
			}
			return { .value = mk_num(as_num(args[0]) * as_num(args[1])) };
		case "/":
			if (!is_num(args[0]) || !is_num(args[1])) {
				return { .thrown = true, .value = mk_str("type error: / expects numbers") };
			}
			if (as_num(args[1]) == 0.0) {
				return { .thrown = true, .value = mk_str("division by zero") };
			}
			return { .value = mk_num(as_num(args[0]) / as_num(args[1])) };
		case "===":
			return { .value = mk_bool(strict_eq(args[0], args[1])) };
		case "<":
			if (!is_num(args[0]) || !is_num(args[1])) {
				return { .thrown = true, .value = mk_str("type error: < expects numbers") };
			}
			return { .value = mk_bool(as_num(args[0]) < as_num(args[1])) };
		case ">":
			if (!is_num(args[0]) || !is_num(args[1])) {
				return { .thrown = true, .value = mk_str("type error: > expects numbers") };
			}
			return { .value = mk_bool(as_num(args[0]) > as_num(args[1])) };
		case "<=":
			if (!is_num(args[0]) || !is_num(args[1])) {
				return { .thrown = true, .value = mk_str("type error: <= expects numbers") };
			}
			return { .value = mk_bool(as_num(args[0]) <= as_num(args[1])) };
		case ">=":
			if (!is_num(args[0]) || !is_num(args[1])) {
				return { .thrown = true, .value = mk_str("type error: >= expects numbers") };
			}
			return { .value = mk_bool(as_num(args[0]) >= as_num(args[1])) };
		case "and":
			return { .value = truthy(args[0]) ? args[1] : args[0] };
		case "or":
			return { .value = truthy(args[0]) ? args[0] : args[1] };
		case "is_number": return { .value = mk_bool(is_num(args[0])) };
		case "is_string": return { .value = mk_bool(is_str(args[0])) };
		case "is_bool":   return { .value = mk_bool(is_bool(args[0])) };
		case "is_array":  return { .value = mk_bool(is_arr(args[0])) };
		case "is_record": return { .value = mk_bool(is_rec(args[0])) };
		case "is_nil":    return { .value = mk_bool(is_nil(args[0])) };
		case "has_field":
			if (!is_rec(args[0])) {
				return { .thrown = true, .value = mk_str("type error: has_field expects record") };
			}
			Record* r = as_rec(args[0]);
			if (!is_str(args[1])) {
				return { .thrown = true, .value = mk_str("type error: has_field expects string key") };
			}
			uint want = intern(*as_str(args[1]));
			foreach (&key : r.keys) {
				if (*key == want) return { .value = mk_bool(true) };
			}
			return { .value = mk_bool(false) };
		case "len":
			if (is_arr(args[0])) {
				Array* a = as_arr(args[0]);
				return { .value = mk_num((double)a.items.len) };
			}
			if (is_str(args[0])) {
				return { .value = mk_num((double)(*as_str(args[0])).len) };
			}
			return { .thrown = true, .value = mk_str("type error: len expects array or string") };
		case "push":
			if (!is_arr(args[0])) {
				return { .thrown = true, .value = mk_str("type error: push expects array") };
			}
			Array* a = as_arr(args[0]);
			Value[] grown = mem::talloc_array(Value, a.items.len + 1);
			for (int i = 0; i < a.items.len; i++) grown[i] = a.items[i];
			grown[a.items.len] = args[1];
			a.items = grown;
			return { .value = mk_nil() };
		case "array_all":

		{
			// array_all(arr, pred)  =>  true if pred(x) is truthy for every x in arr
			if (!is_arr(args[0])) {
				return { .thrown = true, .value = mk_str("type error: array_all expects array") };
			}
			if (!is_closure(args[1])) {
				return { .thrown = true, .value = mk_str("type error: array_all expects closure") };
			}
			Array* a = as_arr(args[0]);
			foreach (&item : a.items) {
				EvalResult r = apply_fn(args[1], { *item });
				if (r.thrown) return r;
				if (!truthy(r.value)) return { .value = mk_bool(false) };
			}
			return { .value = mk_bool(true) };
		}
		case "slice":
		{
			// slice(arr, start, end)  =>  a fresh array of arr[start..end].
			// start and end are numbers; end of -1 means "to the end".
			if (!is_arr(args[0])) {
				return { .thrown = true, .value = mk_str("type error: slice expects array") };
			}
			Array* a = as_arr(args[0]);
			long len = (long)a.items.len;
			long start = (long)as_num(args[1]);
			long end   = (long)as_num(args[2]);
			if (start < 0) start = len + start;
			if (end   < 0) end   = len;
			if (start < 0)         start = 0;
			if (start > len)       start = len;
			if (end   < start)     end   = start;
			if (end   > len)       end   = len;
			long n = end - start;
			Value[] out = mem::talloc_array(Value, (sz)n);
			for (long i = 0; i < n; i++) out[i] = a.items[start + i];
			Array* r = new_array();
			r.items = out;
			return { .value = val_arr(r) };
		}
		case "print":
			foreach (arg : args) {
				Value s = show(arg);
				io::printn(*as_str(s));
			}
			return { .value = mk_nil() };
		case "signal":
		{
			// signal(initial_value) => Signal value
			Signal* sig = new_signal(args[0]);
			return { .value = val_signal(sig) };
		}
		case "signal_get":
		{
			// signal_get(signal_or_derived) => current value
			if (!is_signal(args[0])) {
				return { .thrown = true, .value = mk_str("$: not a signal — did a local variable shadow the signal?") };
			}
			Signal* sig = as_signal(args[0]);
			reactive_track(sig);
			if (signal_is_derived(sig)) {
				return { .value = derived_evaluate(sig) };
			}
			return { .value = sig.current };
		}
		case "signal_set":
		{
			// signal_set(signal, new_value) => nil
			if (!is_signal(args[0])) {
				return { .thrown = true, .value = mk_str("type error: signal_set expects signal") };
			}
			Signal* sig = as_signal(args[0]);
			if (signal_is_derived(sig)) {
				return { .thrown = true, .value = mk_str("type error: signal_set expects a plain signal, not a derived") };
			}
			sig.current = args[1];
			notify_subs(sig.subs);
			return { .value = mk_nil() };
		}
		case "derived":
		{
			// derived(fn) => derived signal (lazy computed)
			if (!is_closure(args[0])) {
				return { .thrown = true, .value = mk_str("type error: derived expects closure") };
			}
			Signal* d = new_derived(as_closure(args[0]));
			return { .value = val_signal(d) };
		}
		case "effect":
		{
			// effect(fn) => unsubscribe closure
			if (!is_closure(args[0])) {
				return { .thrown = true, .value = mk_str("type error: effect expects closure") };
			}
			Effect* e = new_effect(as_closure(args[0]));
			// Link into global effect list.
			e.next = g_effects;
			g_effects = e;
			// Run the effect once with tracking.
			effect_rerun(e);
			// Return an unsubscribe closure that removes this effect.
			// We use a prim-call: Call(Prim("__unsub"), [Lit(effect_as_value)])
			// But we can't easily create a closure at runtime.  Instead, return
			// the effect pointer as a Value so the user can pass it to __unsub.
			// For simplicity, just return nil for now (effects live until program end).
			return { .value = mk_nil() };
		}
		case "__element":
		{
			// __element(tag, props, ...children) => { __tag, __props, __children, __id }
			// Provides stable identity for JSX-like elements.
			if (args.len < 2) {
				return { .thrown = true, .value = mk_str("type error: __element expects at least (tag, props)") };
			}
			Value tag = args[0];
			Value props = args[1];
			// Build children array from remaining args.
			int nkids = (int)args.len - 2;
			Value[] kids = mem::talloc_array(Value, (sz)nkids);
			for (int i = 0; i < nkids; i++) kids[i] = args[i + 2];
			Array* kids_arr = new_array();
			kids_arr.items = kids;
			int slot = g_element_slot;
			g_element_slot++;
			// Build result record.
			uint[] atom_keys = mem::talloc_array(uint, 4);
			atom_keys[0] = intern("__tag"); atom_keys[1] = intern("__props");
			atom_keys[2] = intern("__children"); atom_keys[3] = intern("__id");
			Value[] vals = mem::talloc_array(Value, 4);
			vals[0] = tag; vals[1] = props; vals[2] = val_arr(kids_arr); vals[3] = mk_num((double)slot);
			Record* r = new_record();
			r.keys = atom_keys;
			r.values = vals;
			return { .value = val_rec(r) };
		}
		case "__begin_render":
		{
			// Reset the element cursor for a new render pass.
			g_element_slot = 0;
			return { .value = mk_nil() };
		}
	}
	// loadlib: dynamic plugin loading
	if (name == "loadlib") {
		return loadlib_fn(args);
	}
	// Check host function table (registered by embedder)
	if (has_host_fn(name)) {
		return call_host_fn(name, args);
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

fn AstNode* desugar_seq_kids(AstNode*[] exprs) {
	// Seq([a, b, ...])   =>   Call(Lambda(["_"], rest), [a])
	// with the base case Seq([]) => Lit(nil), Seq([a]) => desugar(a).
	if (exprs.len == 0) return make_lit(mk_nil());
	if (exprs.len == 1) return desugar(exprs[0], null);
	AstNode* head   = desugar(exprs[0], null);
	AstNode*[] rest = mem::talloc_array(AstNode*, exprs.len - 1);
	for (int i = 1; i < exprs.len; i++) rest[i - 1] = exprs[i];
	return make_call(make_lambda({ "_" }, desugar_seq_kids(rest)), { head });
}

// Desugar every child of an already-kernel node, then rebuild it.
fn AstNode* desugar_with_kids(NodeType t, AstNode*[] kids, TypeDefEntry* tenv) {
	AstNode*[] out = mem::talloc_array(AstNode*, kids.len);
	for (int i = 0; i < kids.len; i++) out[i] = desugar(kids[i], tenv);
	AstNode* n = mem::tnew(AstNode);
	n.type = t;
	n.children = out;
	return n;
}

int gensym_counter;
fn String gensym(String prefix) {
	gensym_counter++;
	return string::tformat("%s%d", prefix, gensym_counter);
}

// type_pred: build a kernel boolean AST that is true iff `val` matches type t.
// `val` is the already-desugared kernel expression being checked.
fn AstNode* type_pred(Type t, AstNode* val, TypeDefEntry* tenv) {
	switch (t.kind) {
		case TNAME:
			if (t.name == "Int" || t.name == "Number") {
				return make_call(make_prim_node("is_number"), { val });
			}
			if (t.name == "String") {
				return make_call(make_prim_node("is_string"), { val });
			}
			if (t.name == "Bool") {
				return make_call(make_prim_node("is_bool"), { val });
			}
			if (tenv_lookup(tenv, t.name) != null) {
				return type_pred(tenv_lookup(tenv, t.name).type, val, tenv);
			}
			// unknown: gradual-typing escape hatch — be permissive.
			return make_lit(mk_bool(true));
		case TARRAY:

			{
				// is_array AND every element matches (via array_all + a lambda predicate)
				String e           = gensym("_e");
				AstNode* e_var     = make_var(e);
				AstNode* elem_pred = make_lambda({ e }, type_pred(*t.elem, e_var, tenv));
				return make_call(make_prim_node("array_all"), { val, elem_pred });
			}
		case TRECORD:

			{
				// is_record AND every named field present and matching.
				// Folded into a right-nested If.
				AstNode* result = make_lit(mk_bool(true));
				for (int i = t.keys.len - 1; i >= 0; i--) {
					String fname    = t.keys[i];
					Type ftype      = *t.types[i];
					AstNode* fval   = make_get(val, make_lit(mk_str(fname)));
					AstNode* fcheck = type_pred(ftype, fval, tenv);
					AstNode* has    = make_call(make_prim_node("has_field"), { val, make_lit(mk_str(fname)) });
					result = make_if(has, make_if(fcheck, result, make_lit(mk_bool(false))), make_lit(mk_bool(false)));
				}
				return make_if(make_call(make_prim_node("is_record"), { val }), result, make_lit(mk_bool(false)));
			}
		case TSUM:

			{
				// is_record AND __tag is one of the listed tags.
				AstNode* result = make_lit(mk_bool(false));
				for (int i = 0; i < t.keys.len; i++) {
					String tag = t.keys[i];
					AstNode* eq = make_call(
						make_prim_node("==="),
						{ make_get(val, make_lit(mk_str("__tag"))), make_lit(mk_str(tag)), }
					);
					result = make_if(eq, make_lit(mk_bool(true)), result);
				}
				return make_if(make_call(make_prim_node("is_record"), { val }), result, make_lit(mk_bool(false)));
			}
	}
}

// make_check: wrap an already-desugared kernel expression `expr_kernel` so
// that it is re-evaluated exactly once, asserted against type t, and either
// returned or thrown.  Mirrors the reference's `make_check`.
fn AstNode* make_check(Type t, AstNode* expr_kernel, TypeDefEntry* tenv, String where) {
	String v       = gensym("_v");
	AstNode* v_var = make_var(v);
	AstNode* pred  = type_pred(t, v_var, tenv);
	String msg     = string::tformat("type error at %s: expected %s", where, type_name(t));
	AstNode* err   = make_throw(make_lit(mk_str(msg)));
	AstNode* body  = make_if(pred, v_var, err);
	return make_call(make_lambda({ v }, body), { expr_kernel });
}

fn String type_name(Type t) {
	switch (t.kind) {
		case TNAME: return t.name;
		case TARRAY: return string::tformat("Array<%s>", type_name(*t.elem));
		case TRECORD:

			{
				@pool() {
					DString buf;
					buf.tinit();
					buf.append_char('{');
					for (int i = 0; i < t.keys.len; i++) {
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
					for (int i = 0; i < t.keys.len; i++) {
						if (i > 0) buf.append(" | ");
						buf.append(t.keys[i]);
					}
					return buf.str_view();
				};
			}
	}
}

fn AstNode* desugar(AstNode* e, TypeDefEntry* tenv) {
	switch (e.type) {
		case LIT:
		case VAR:
		case PRIM:
			return e;
		case LAMBDA:

			{
				// A lambda's body might be a SEQ or other surface form; desugar it.
				AstNode* n = mem::tnew(AstNode);
				n.type = LAMBDA;
				n.names = e.names;
				n.name_ids = e.name_ids;
				AstNode*[] kids = mem::talloc_array(AstNode*, e.children.len);
				for (int i = 0; i < e.children.len; i++) kids[i] = desugar(e.children[i], tenv);
				n.children = kids;
				return n;
			}
		case CALL: return desugar_with_kids(CALL, e.children, tenv);
		case IF: return desugar_with_kids(IF, e.children, tenv);
		case GET: return desugar_with_kids(GET, e.children, tenv);
		case SET: return desugar_with_kids(SET, e.children, tenv);
		case RECORD:

			{
				// Record has parallel `names` and `children`; desugar children only.
				AstNode* n = mem::tnew(AstNode);
				n.type = RECORD;
				n.names = e.names;
				n.name_ids = e.name_ids;
				AstNode*[] out = mem::talloc_array(AstNode*, e.children.len);
				for (int i = 0; i < e.children.len; i++) out[i] = desugar(e.children[i], tenv);
				n.children = out;
				return n;
			}
		case ARRAY_LIT: return desugar_with_kids(ARRAY_LIT, e.children, tenv);
		case THROW: return desugar_with_kids(THROW, e.children, tenv);
		case TRY:

			{
				AstNode* n = mem::tnew(AstNode);
				n.type = TRY;
				n.name = e.name;
				n.name_id = e.name_id;
				AstNode*[] out = mem::talloc_array(AstNode*, e.children.len);
				for (int i = 0; i < e.children.len; i++) out[i] = desugar(e.children[i], tenv);
				n.children = out;
				return n;
			}
		case LETREC:

			{
				AstNode* n = mem::tnew(AstNode);
				n.type = LETREC;
				n.name = e.name;
				n.name_id = e.name_id;
				AstNode*[] out = mem::talloc_array(AstNode*, e.children.len);
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
				String m        = e.name;
				AstNode* recv   = desugar(e.children[0], tenv);
				AstNode*[] args = mem::talloc_array(AstNode*, e.children.len - 1);
				for (int i = 1; i < e.children.len; i++) args[i - 1] = desugar(e.children[i], tenv);
				AstNode*[] call_args = mem::talloc_array(AstNode*, args.len + 1);
				call_args[0] = make_var("r");
				for (int i = 0; i < args.len; i++) call_args[i + 1] = args[i];
				AstNode* get  = make_get(make_var("r"), make_lit(mk_str(m)));
				AstNode* call = make_call(get, call_args);
				AstNode* lam  = make_lambda({ "r" }, call);
				return make_call(lam, { recv });
			}
		case LAMBDA_T:

			{
				// Typed Lambda: strip annotations, wrap body in checks for params and return.
				//   Lambda(xs:[name,Type?], ret:Type?, body)
				//   => Lambda(xs, Check(ret, Bind(_r, body)))
				AstNode* body_d     = desugar(e.children[0], tenv);
				String[] heap_names = mem::talloc_array(String, e.names.len);
				for (int i = 0; i < e.names.len; i++) heap_names[i] = e.names[i];
				// Param checks
				AstNode* checked = body_d;
				for (int i = e.param_types.len - 1; i >= 0; i--) {
					if (e.param_types[i] != null) {
						String pname  = heap_names[i];
						Type pt       = *e.param_types[i];
						AstNode* v    = make_var(pname);
						AstNode* pred = type_pred(pt, v, tenv);
						String msg    = string::tformat("type error at param '%s': expected %s", pname, type_name(pt));
						checked = make_if(pred, checked, make_throw(make_lit(mk_str(msg))));
					}
				}
				// Return check
				if (e.ret_type != null) {
					String rname            = gensym("_ret");
					Type rt                 = *e.ret_type;
					AstNode* rv             = make_var(rname);
					AstNode* pred           = type_pred(rt, rv, tenv);
					String msg              = string::tformat("type error at return value: expected %s", type_name(rt));
					AstNode* return_checked = make_if(pred, rv, make_throw(make_lit(mk_str(msg))));
					AstNode* bind           = make_lambda({ rname }, return_checked);
					checked = make_call(bind, { checked });
				}
				AstNode* n = mem::tnew(AstNode);
				n.type = LAMBDA;
				n.names = heap_names;
				n.name_ids = e.name_ids;
				AstNode*[] kids = mem::talloc_array(AstNode*, 1);
				kids[0] = checked;
				n.children = kids;
				return n;
			}
		case LET_T:

			{
				// Typed Let: check the initializer against the annotation, then bind.
				AstNode* init_d = desugar(e.children[0], tenv);
				AstNode* body_d = desugar(e.children[1], tenv);
				if (e.ann_type != null) {
					Type t       = *e.ann_type;
					String where = string::tformat("let '%s'", e.name);
					init_d = make_check(t, init_d, tenv, where);
				}
				AstNode* n = mem::tnew(AstNode);
				n.type = LETREC;
				n.name = e.name;
				n.name_id = e.name_id;
				AstNode*[] kids = mem::talloc_array(AstNode*, 2);
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
				String[] nk  = mem::talloc_array(String, 2);
				nk[0] = "__tag";
				nk[1] = "__val";
				AstNode*[] vk = mem::talloc_array(AstNode*, 2);
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
				String s       = gensym("_scrut");
				// Each branch is encoded as a 3-tuple (tag, bind, body) in e.names /



				// e.children.  We store: e.names = [tag, bind] repeated, e.children = [body, ...]

				// Simpler: e.children is the [scrut, body1, body2, ...] and e.names

				// is the [tag1, bind1, tag2, bind2, ...].  Decode here.

				AstNode*[] branch_bodies = e.children[1..];
				AstNode* chain           = make_throw(make_lit(mk_str("non-exhaustive match")));
				for (int i = branch_bodies.len - 1; i >= 0; i--) {
					String tag           = e.names[2 * i];
					String bind          = e.names[2 * i + 1];
					AstNode* body_branch = desugar(branch_bodies[i], tenv);
					AstNode* bound = make_call(
						make_lambda({ bind }, body_branch),
						{ make_get(make_var(s), make_lit(mk_str("__val"))) }
					);
					AstNode* eq = make_call(
						make_prim_node("==="),
						{ make_get(make_var(s), make_lit(mk_str("__tag"))), make_lit(mk_str(tag)), }
					);
					chain = make_if(eq, bound, chain);
				}
				return make_call(make_lambda({ s }, chain), { scrut });
			}
	}
}

// ============================================================================
// APPLY
// ============================================================================

fn EvalResult apply_fn(Value fn_val, Value[] args) {
	if (is_prim(fn_val)) {
		return prim_dispatch(as_prim(fn_val).name, args);
	}
	if (is_closure(fn_val)) {
		Closure* c = as_closure(fn_val);
		if (args.len != c.param_ids.len) {
			return {
				.thrown = true,
				.value = mk_str(string::tformat("arity error: expected %d, got %d", c.param_ids.len, args.len))
			};
		}
		if (args.len == 1) {
			Env* call_env = env_extend1(c.env, c.param_ids[0], args[0]);
			return { .is_tail = true, .tail_node = c.body, .tail_env = call_env };
		}
		Env* call_env = env_extend(c.env, c.param_ids, args);
		return { .is_tail = true, .tail_node = c.body, .tail_env = call_env };
	}
	return { .thrown = true, .value = mk_str("not callable") };
}

// ============================================================================
// EVAL
// ============================================================================

// TCO trampoline: loop instead of recursing so tail calls use constant C stack.
// Flat hot path: inlines single-param CALL(VAR→CLOSURE_BIT) to skip eval_step.
fn EvalResult eval(AstNode* node, Env* env) {
	while (true) {
		// --- Flat hot path: single-param tail call via CLOSURE_BIT ---
		if (node.type == CALL && node.children[0].type == VAR) {
			bool found;
			Env* source;
			env_lookup(env, node.children[0].name_id, &found, &source);
			if (found && source != null && (source.count & CLOSURE_BIT)) {
				AstNode* lambda = source.data.lambda_node;
				int argc = node.children.len - 1;
				if (argc == lambda.name_ids.len) {
					if (argc == 1) {
						EvalResult a = eval(node.children[1], env);
						if (a.thrown) return a;
						env = env_extend1(source, lambda.name_ids[0], a.value);
						node = lambda.children[0];
						continue;
					}
				}
			}
		}
		// --- Slow path ---
		EvalResult r = eval_step(node, env);
		if (!r.is_tail) return r;
		node = r.tail_node;
		env = r.tail_env;
	}
}

fn EvalResult eval_step(AstNode* node, Env* env) {
	switch (node.type) {
		case LIT:
			return { .value = node.literal };
		case VAR:
			bool found;
			Env* source;
			Value v = env_lookup(env, node.name_id, &found, &source);
			if (!found) {
				return { .thrown = true, .value = mk_str(string::tformat("unbound variable: %s", node.name)) };
			}
			// Lazy Closure creation: if `v` was found in an inline closure
			// env (CLOSURE_BIT), the binding has no Value — create a real
			// Closure on the fly so the value can be passed around.
			if (source != null && (source.count & CLOSURE_BIT)) {
				AstNode* lambda = source.data.lambda_node;
				Closure* c = new_closure();
						rc_inc_env(source);
				c.param_ids = lambda.name_ids;
				c.body = lambda.children[0];
				c.env = source;
				return { .value = val_closure(c) };
			}
			return { .value = v };
		case LAMBDA:

		{
			Closure* c = new_closure();
			rc_inc_env(env);
			c.param_ids = node.name_ids;
			c.body = node.children[0];
			c.env = env;
			return { .value = val_closure(c) };
		}
		case CALL:

		{
			// Fast path: primitive call — skip closure/apply_fn overhead entirely.
			// Evaluates args into a stack buffer and dispatches directly, avoiding
			// Prim heap allocation, args Value[] heap allocation, and env_extend.
			if (node.children[0].type == PRIM) {
				int argc = node.children.len - 1;
				Value[8] stack_buf;
				for (int i = 0; i < argc; i++) {
					EvalResult a = eval(node.children[i + 1], env);
					if (a.thrown) return a;
					stack_buf[i] = a.value;
				}
				// Ultra-fast path: inline numeric binops without string switch.
				String pname = node.children[0].name;
				if (argc == 2) {
					Value av = stack_buf[0];
					Value bv = stack_buf[1];
					if (is_num(av) && is_num(bv)) {
						double da = as_num(av);
						double db = as_num(bv);
						if (pname == "+") return { .value = val_num(da + db) };
						if (pname == "-") return { .value = val_num(da - db) };
						if (pname == "*") return { .value = val_num(da * db) };
						if (pname == "/") {
							if (db == 0.0) return { .thrown = true, .value = mk_str("division by zero") };
							return { .value = val_num(da / db) };
						}
						if (pname == "<")  return { .value = val_bool(da < db) };
						if (pname == ">")  return { .value = val_bool(da > db) };
						if (pname == "<=") return { .value = val_bool(da <= db) };
						if (pname == ">=") return { .value = val_bool(da >= db) };
					}
					if (pname == "===") return { .value = val_bool(strict_eq(av, bv)) };
					if (pname == "and") return { .value = truthy(av) ? bv : av };
					if (pname == "or")  return { .value = truthy(av) ? av : bv };
				}
				if (argc == 1) {
					Value av = stack_buf[0];
					if (pname == "is_number") return { .value = val_bool(is_num(av)) };
					if (pname == "is_string") return { .value = val_bool(is_str(av)) };
					if (pname == "is_bool")   return { .value = val_bool(is_bool(av)) };
					if (pname == "is_array")  return { .value = val_bool(is_arr(av)) };
					if (pname == "is_record") return { .value = val_bool(is_rec(av)) };
					if (pname == "is_nil")    return { .value = val_bool(is_nil(av)) };
					if (pname == "len") {
						if (is_arr(av)) return { .value = val_num((double)as_arr(av).items.len) };
						if (is_str(av)) return { .value = val_num((double)(*as_str(av)).len) };
					}
				}
				return prim_dispatch(pname, stack_buf[0:argc]);
			}
			// Fast path: direct VAR → Closure call — skip general eval/apply_fn.
			if (node.children[0].type == VAR) {
				bool found;
				Env* source;
				Value fn_val = env_lookup(env, node.children[0].name_id, &found, &source);
				if (found) {
					// Ultra-fast path: inline closure env (LetRec+Lambda).
					// No Closure object — metadata lives in the Env itself.
					if (source != null && (source.count & CLOSURE_BIT)) {
						AstNode* lambda = source.data.lambda_node;
						int argc = node.children.len - 1;
						if (argc == lambda.name_ids.len) {
							if (argc == 1) {
								EvalResult a = eval(node.children[1], env);
								if (a.thrown) return a;
								Env* call_env = env_extend1(source, lambda.name_ids[0], a.value);
								return { .is_tail = true, .tail_node = lambda.children[0], .tail_env = call_env };
							}
							Value[8] stack_buf;
							for (int i = 0; i < argc; i++) {
								EvalResult a = eval(node.children[i + 1], env);
								if (a.thrown) return a;
								stack_buf[i] = a.value;
							}
							Env* call_env = env_extend(source, lambda.name_ids, stack_buf[0:argc]);
							return { .is_tail = true, .tail_node = lambda.children[0], .tail_env = call_env };
						}
					}
					// Normal Closure path — skip general eval/apply_fn.
					if (is_closure(fn_val)) {
						Closure* c = as_closure(fn_val);
						int argc = node.children.len - 1;
						if (argc == c.param_ids.len) {
							// Ultra-fast path: single-param closure (fib hot path).
							// Avoids the intermediate Value[] args allocation entirely.
							if (argc == 1) {
								EvalResult a = eval(node.children[1], env);
								if (a.thrown) return a;
								Env* call_env = env_extend1(c.env, c.param_ids[0], a.value);
								return { .is_tail = true, .tail_node = c.body, .tail_env = call_env };
							}
							Value[] args = mem::talloc_array(Value, argc);
							for (int i = 0; i < argc; i++) {
								EvalResult a = eval(node.children[i + 1], env);
								if (a.thrown) return a;
								args[i] = a.value;
							}
							Env* call_env = env_extend(c.env, c.param_ids, args);
							return { .is_tail = true, .tail_node = c.body, .tail_env = call_env };
						}
					}
				}
				// Fall through: resolve fn_val via general path below if not a direct closure
				// Reconstruct the function value for the general path.
			}
			EvalResult fn_r = eval(node.children[0], env);
			if (fn_r.thrown) return fn_r;
			// Evaluate args in order, short-circuiting on throw.
			AstNode*[] arg_nodes = node.children[1..];
			Value[] args         = mem::talloc_array(Value, arg_nodes.len);
			for (int i = 0; i < arg_nodes.len; i++) {
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
			if (truthy(c.value)) return { .is_tail = true, .tail_node = node.children[1], .tail_env = env };
			return { .is_tail = true, .tail_node = node.children[2], .tail_env = env };
		}
		case GET:

		{
			EvalResult o = eval(node.children[0], env);
			if (o.thrown) return o;
			EvalResult k = eval(node.children[1], env);
			if (k.thrown) return k;
			if (is_arr(o.value)) {
				if (!is_num(k.value)) {
					return { .thrown = true, .value = mk_str("type error: array index must be number") };
				}
				Array* a = as_arr(o.value);
				long idx = (long)as_num(k.value);
				if (idx < 0 || (sz)idx >= a.items.len) {
					return { .thrown = true, .value = mk_str("index out of bounds") };
				}
				return { .value = a.items[idx] };
			}
			if (is_rec(o.value)) {
				if (!is_str(k.value)) {
					return { .thrown = true, .value = mk_str("type error: record key must be string") };
				}
				Record* r = as_rec(o.value);
				String  kk = *as_str(k.value);
				uint    want = intern(kk);
				foreach (i, &rk : r.keys) {
					if (*rk == want) return { .value = r.values[i] };
				}
				return { .thrown = true, .value = mk_str(string::tformat("no field '%s'", kk)) };
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
			if (is_arr(o.value)) {
				if (!is_num(k.value)) {
					return { .thrown = true, .value = mk_str("type error: array index must be number") };
				}
				Array* a = as_arr(o.value);
				long idx = (long)as_num(k.value);
				if (idx < 0 || (sz)idx >= a.items.len) {
					return { .thrown = true, .value = mk_str("index out of bounds") };
				}
				a.items[idx] = v.value;
				return { .value = v.value };
			}
			if (is_rec(o.value)) {
				if (!is_str(k.value)) {
					return { .thrown = true, .value = mk_str("type error: record key must be string") };
				}
				Record* r   = as_rec(o.value);
				String  kk  = *as_str(k.value);
				uint    want = intern(kk);
				foreach (i, &rk : r.keys) {
					if (*rk == want) {
						r.values[i] = v.value;
						return { .value = v.value };
					}
				}
				// new key: append.  Heap-allocate (not temp pool) so the
				// grown slice outlives this eval's @pool frame.
				uint[]  nk = mem::new_array(uint, r.keys.len + 1);
				Value[] nv = mem::new_array(Value, r.values.len + 1);
				for (int j = 0; j < r.keys.len; j++) {
					nk[j] = r.keys[j];
					nv[j] = r.values[j];
				}
				nk[r.keys.len] = want;
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
			// Use pre-interned name_ids from the AST (no runtime intern() call).
			r.keys = node.name_ids;
			Value[] vals = mem::talloc_array(Value, node.children.len);
			for (int i = 0; i < node.children.len; i++) {
				EvalResult e = eval(node.children[i], env);
				if (e.thrown) return e;
				vals[i] = e.value;
			}
			r.values = vals;
			return { .value = val_rec(r) };
		}
		case ARRAY_LIT:

		{
			Array* a      = new_array();
			Value[] items = mem::talloc_array(Value, node.children.len);
			for (int i = 0; i < node.children.len; i++) {
				EvalResult e = eval(node.children[i], env);
				if (e.thrown) return e;
				items[i] = e.value;
			}
			a.items = items;
			return { .value = val_arr(a) };
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
			Env* h = env_define(env, node.name_id, b.value);
			return { .is_tail = true, .tail_node = node.children[1], .tail_env = h };
		}
		case PRIM:

		{
			return { .value = mk_prim(node.name) };
		}
		case LETREC:

		{
			// Fast path: if init is a Lambda, create an inline closure env
			// — no separate Closure heap allocation needed.
			if (node.children[0].type == LAMBDA) {
				Env* rec = env_define_closure(env, node.name_id, node.children[0]);
				return { .is_tail = true, .tail_node = node.children[1], .tail_env = rec };
			}
			Env* rec = env_define(env, node.name_id, mk_nil());
			EvalResult init = eval(node.children[0], rec);
			if (init.thrown) return init;
			rec.data.value = init.value;
			return { .is_tail = true, .tail_node = node.children[1], .tail_env = rec };
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
}

// ============================================================================
// TOP-LEVEL
// ============================================================================

// Builtin env: a parent env that maps the names of every primitive
// (len, push, print, ...) to PRIMITIVE values.  This makes primitives
// callable as ordinary functions: `len(arr)` works because `len` resolves
// to a PRIMITIVE that apply_fn dispatches to prim_dispatch.
//
// The eval entry point passes this as the root of every program's
// environment chain.
Env* builtin_env;

fn Env* make_builtin_env()
{
	String[] names = {
		"+", "-", "*", "/",
		"===", "<", ">", "<=", ">=",
		"and", "or",
		"is_number", "is_string", "is_bool", "is_array", "is_record", "is_nil",
		"has_field", "len", "push", "print", "array_all", "slice",
		"signal", "signal_get", "signal_set", "derived", "effect",
		"__element", "__begin_render",
		"loadlib",
	};
	Env* e = mem::tnew(Env);
	e.parent = null;
	e.count = names.len;
	Binding* bp = mem::talloc_array(Binding, names.len);
	for (int i = 0; i < names.len; i++)
	{
		bp[i] = { .name_id = intern(names[i]), .value = mk_prim(names[i]) };
	}
	e.data.bindings_ptr = bp;
	return e;
}

fn Value run(AstNode* node) {
	@pool() {
		EvalResult r = eval(node, builtin_env);
		if (r.thrown) {
			Value s = show(r.value);
			io::printfn("threw: %s", *as_str(s));
			return mk_nil();
		}
		Value s = show(r.value);
		io::printn(*as_str(s));
		return r.value;
	};
}

// Run a parsed program: desugar the surface AST, then evaluate.  Prints the
// value of the last expression.
fn Value run_source(String src)
{
	@pool() {
		ParseResult pr = parse_source(src);
		if (pr.error)
		{
			io::printfn("%s", pr.message);
			return mk_nil();
		}
		AstNode* kernel = desugar(pr.root, null);
		return run(kernel);
	};
}

// VM-based runner: compile to bytecode, then execute in the VM.
fn Value run_vm(Chunk* chunk) {
	@pool() {
		EvalResult r = vm_execute(chunk);
		if (r.thrown) {
			Value s = show(r.value);
			io::printfn("threw: %s", *as_str(s));
			return mk_nil();
		}
		Value s = show(r.value);
		io::printn(*as_str(s));
		return r.value;
	};
}

fn Value run_source_vm(String src)
{
	@pool() {
		ParseResult pr = parse_source(src);
		if (pr.error)
		{
			io::printfn("%s", pr.message);
			return mk_nil();
		}
		AstNode* kernel = desugar(pr.root, null);
		Chunk* chunk = compile(kernel);
		return run_vm(chunk);
	};
}


