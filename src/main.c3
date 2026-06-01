module engine;
import std::io;

// ============================================================================
// VALUE UNIVERSE
// ============================================================================

enum ValueType : char
{
	NIL,
	BOOL,
	NUMBER,
	STRING,
	ARRAY,
	RECORD,
	CLOSURE,
}

struct Value
{
	ValueType type;
	double num_val;
	bool bool_val;
	String str_val;
	void* ptr_val;
}

// ============================================================================
// AST NODES
// ============================================================================

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
}

struct AstNode
{
	NodeType type;
	AstNode* left;
	AstNode* right;
	AstNode* extra;
	String name;
	Value literal;
	AstNode*[] children;
	String[] names;
}

// ============================================================================
// ENVIRONMENT (lexical scope)
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
// EVALUATOR
// ============================================================================

fn Value eval(AstNode* node, Env* env)
{
	if (node == null)
	{
		return { .type = NIL };
	}

	switch (node.type)
	{
		case LIT:
			return node.literal;
		case VAR:
			return env_lookup(env, node.name);
		default:
			io::printfn("Unimplemented node: %s", node.type);
			return { .type = NIL };
	}
}

fn Value env_lookup(Env* env, String name)
{
	while (env != null)
	{
		foreach (&b : env.bindings)
		{
			if (b.name == name) return b.value;
		}
		env = env.parent;
	}
	io::printfn("Unbound variable: %s", name);
	return { .type = NIL };
}

// ============================================================================
// ENTRY POINT
// ============================================================================

fn int main(String[] args)
{
	io::printn("JS variant interpreter v0.1.0");
	return 0;
}
