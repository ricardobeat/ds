module engine;
import std::io;
import std::core::dstring;

// ============================================================================
// FORMATTER
// ============================================================================
//
// Round-trip formatter: parse the source, then re-emit it in a canonical
// 2-space, K&R-brace style.  Comments are dropped (the lexer discards them),
// and any text that wasn't a comment is faithfully reproduced via the AST.
//
// Style (matches resources/sample.ds):
//   - 2-space indent, K&R braces
//   - Records and arrays: one element per line, trailing comma omitted
//   - Function bodies: single-line if short, block if long
//   - Let-chains: each `let` on its own line, no leading blank lines
//   - If/else, method calls, calls, and binops: single-line, parenthesised
//     only as needed for precedence.
//
// Output is heap-allocated (not temp) so the caller can return it past a
// @pool scope.

const int FMT_INDENT = 2;

fn bool fmt_is_valid_ident(String s)
{
	if (s.len == 0) return false;
	char c0 = s[0];
	if (!((c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z') || c0 == '_')) return false;
	for (long i = 1; i < s.len; i++)
	{
		char c = s[i];
		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) return false;
	}
	return true;
}

fn void fmt_key(DString* buf, AstNode* key)
{
	// If the key is a string literal that is a valid identifier, emit it
	// unquoted (the .name form).  Otherwise emit the literal as-is.
	if (key.type == LIT && is_str(key.literal) && fmt_is_valid_ident(*as_str(key.literal)))
	{
		buf.append(*as_str(key.literal));
		return;
	}
	fmt_expr(buf, key, 0);
}

fn void fmt_indent(DString* buf, int n)
{
	for (int i = 0; i < n; i++) buf.append_char(' ');
}

fn void fmt_type(DString* buf, Type* t)
{
	if (t == null) return;
	switch (t.kind)
	{
		case TNAME:
			buf.append(t.name);
			return;
		case TARRAY:
			fmt_type(buf, t.elem);
			buf.append("[]");
			return;
		case TRECORD:
			buf.append("{ ");
			for (int i = 0; i < t.keys.len; i++)
			{
				if (i > 0) buf.append(", ");
				buf.append(t.keys[i]);
				buf.append(": ");
				fmt_type(buf, t.types[i]);
			}
			buf.append(" }");
			return;
		case TSUM:
			for (int i = 0; i < t.keys.len; i++)
			{
				if (i > 0) buf.append(" | ");
				buf.append(t.keys[i]);
			}
			return;
	}
}

fn void fmt_lambda_params(DString* buf, String[] names, Type*[] types, bool emit_types)
{
	buf.append_char('(');
	for (int i = 0; i < names.len; i++)
	{
		if (i > 0) buf.append(", ");
		buf.append(names[i]);
		if (emit_types && i < types.len && types[i] != null)
		{
			buf.append(": ");
			fmt_type(buf, types[i]);
		}
	}
	buf.append_char(')');
}

// Estimate the printed width of an expression.  This is a rough heuristic:
// we walk the tree without allocating and count up a guess of the column
// width.  It's only used to decide whether to inline a function body.
fn long fmt_estimate_width(AstNode* e)
{
	if (e == null) return 0;
	switch (e.type)
	{
		case LIT:
			if (is_str(e.literal)) return (*as_str(e.literal)).len + 2;
			if (is_num(e.literal))
			{
				double n = as_num(e.literal);
				if (n == (double)(long)n) return string::tformat("%d", (long)n).len;
				return string::tformat("%f", n).len;
			}
			if (is_bool(e.literal)) return as_bool(e.literal) ? 4 : 5;
			return 3; // nil
		case VAR: return e.name.len;
		case PRIM: return e.name.len + 2; // <prim foo>
		case LAMBDA:
		case LAMBDA_T:
		{
			// "fn(params) { body }" — recurse on the body
			long w = 3; // "fn("
			for (int i = 0; i < e.names.len; i++)
			{
				if (i > 0) w += 2;
				w += e.names[i].len;
			}
			w += 2; // ") "
			w += 2 + fmt_estimate_width(e.children[0]); // "{ body }"
			return w;
		}
		case CALL:
		{
			long w = fmt_estimate_width(e.children[0]) + 1; // "f("
			for (int i = 1; i < e.children.len; i++)
			{
				if (i > 1) w += 2;
				w += fmt_estimate_width(e.children[i]);
			}
			w += 1; // ")"
			return w;
		}
		case METHODCALL:
		{
			long w = fmt_estimate_width(e.children[0]) + 1 + e.name.len + 1; // "recv.name("
			for (int i = 1; i < e.children.len; i++)
			{
				if (i > 1) w += 2;
				w += fmt_estimate_width(e.children[i]);
			}
			w += 1; // ")"
			return w;
		}
		case BINOP:
			return fmt_estimate_width(e.children[0]) + 1 + e.name.len + 1
				+ fmt_estimate_width(e.children[1]);
		case IF:
			// Heavily inflate the estimate so a lambda holding an if almost
			// always breaks the body onto its own lines (the if/then/else
			// formatters break it multi-line for any reasonable size).
			return 1000;
		case GET:
			return fmt_estimate_width(e.children[0]) + 2
				+ fmt_estimate_width(e.children[1]);
		case SET:
			return fmt_estimate_width(e.children[0]) + 2
				+ fmt_estimate_width(e.children[1]) + 3
				+ fmt_estimate_width(e.children[2]);
		case RECORD:
		{
			long w = 3; // "{}"
			for (int i = 0; i < e.children.len; i++)
			{
				w += e.names[i].len + 2 + fmt_estimate_width(e.children[i]) + 2;
			}
			return w;
		}
		case ARRAY_LIT:
		{
			long w = 2; // "[]"
			for (int i = 0; i < e.children.len; i++)
			{
				w += fmt_estimate_width(e.children[i]) + 2;
			}
			return w;
		}
		case THROW:
			return 6 + fmt_estimate_width(e.children[0]);
		case TRY:
			return 4 + fmt_estimate_width(e.children[0]) + 7
				+ 1 + fmt_estimate_width(e.children[1]);
		case LETREC:
		case LET_T:
		case TYPEDEF:
		case CONSTRUCT:
		case MATCH:
		case SEQ:
			return 100; // "big" — these are formatted multi-line anyway
	}
}

// ---------------------------------------------------------------------------
// Expression emitters
// ---------------------------------------------------------------------------

fn void fmt_record(DString* buf, AstNode* e, int indent)
{
	buf.append("{\n");
	for (int i = 0; i < e.children.len; i++)
	{
		fmt_indent(buf, indent + FMT_INDENT);
		buf.append(e.names[i]);
		buf.append(": ");
		fmt_expr(buf, e.children[i], indent + FMT_INDENT);
		buf.append(",\n");
	}
	fmt_indent(buf, indent);
	buf.append_char('}');
}

fn void fmt_array(DString* buf, AstNode* e, int indent)
{
	if (e.children.len == 0)
	{
		buf.append("[]");
		return;
	}
	buf.append("[\n");
	for (int i = 0; i < e.children.len; i++)
	{
		fmt_indent(buf, indent + FMT_INDENT);
		fmt_expr(buf, e.children[i], indent + FMT_INDENT);
		buf.append(",\n");
	}
	fmt_indent(buf, indent);
	buf.append_char(']');
}

fn void fmt_match_arms(DString* buf, AstNode* match, int indent)
{
	// match.children[0] = scrutinee, rest are arm bodies
	// match.names = [tag0, bind0, tag1, bind1, ...]
	AstNode* scrut = match.children[0];
	AstNode*[] bodies = match.children[1..];
	for (int i = 0; i < bodies.len; i++)
	{
		if (i > 0) buf.append(",\n");
		fmt_indent(buf, indent + FMT_INDENT);
		buf.append(match.names[2 * i]);
		buf.append_char('(');
		buf.append(match.names[2 * i + 1]);
		buf.append(") => ");
		fmt_expr(buf, bodies[i], indent + FMT_INDENT);
	}
	buf.append("\n");
	fmt_indent(buf, indent);
	buf.append_char('}');
}

fn void fmt_lambda(DString* buf, AstNode* e, int indent)
{
	// If param_types is empty (plain LAMBDA) or every slot is null, skip
	// annotations; otherwise emit "fn(p1: T1, p2: T2)".
	bool any_typed = false;
	for (int i = 0; i < e.param_types.len; i++)
	{
		if (e.param_types[i] != null) { any_typed = true; break; }
	}
	buf.append("fn");
	fmt_lambda_params(buf, e.names, e.param_types, any_typed);
	if (any_typed && e.ret_type != null)
	{
		buf.append(": ");
		fmt_type(buf, e.ret_type);
	}
	// Single-line if the whole body would fit on the same line.
	long body_w = fmt_estimate_width(e.children[0]);
	// "fn(...) { body }" — current indent + "fn(...) { body }"
	if ((long)indent + 3 + body_w + 3 < 70)
	{
		buf.append(" { ");
		fmt_expr(buf, e.children[0], indent);
		buf.append(" }");
		return;
	}
	buf.append(" {\n");
	fmt_indent(buf, indent + FMT_INDENT);
	fmt_expr(buf, e.children[0], indent + FMT_INDENT);
	buf.append("\n");
	fmt_indent(buf, indent);
	buf.append_char('}');
}

fn void fmt_expr(DString* buf, AstNode* e, int indent)
{
	if (e == null)
	{
		buf.append("nil");
		return;
	}
	switch (e.type)
	{
		case LIT:
			switch (tag_of(e.literal))
			{
				case NIL: buf.append("nil"); return;
				case BOOL: buf.append(as_bool(e.literal) ? "true" : "false"); return;
				case NUM:
				{
					double n = as_num(e.literal);
					if (n == (double)(long)n)
					{
						buf.append(string::tformat("%d", (long)n));
					}
					else
					{
						buf.append(string::tformat("%f", n));
					}
					return;
				}
				case STRING:
					buf.append_char('"');
					buf.append(*as_str(e.literal));
					buf.append_char('"');
					return;
				default: buf.append("?lit?"); return;
			}
		case VAR:
			buf.append(e.name);
			return;
		case PRIM: buf.append(e.name); return;
		case BINOP:
			fmt_expr(buf, e.children[0], indent);
			buf.append_char(' ');
			buf.append(e.name);
			buf.append_char(' ');
			fmt_expr(buf, e.children[1], indent);
			return;
		case CALL:
			fmt_expr(buf, e.children[0], indent);
			buf.append_char('(');
			for (int i = 1; i < e.children.len; i++)
			{
				if (i > 1) buf.append(", ");
				fmt_expr(buf, e.children[i], indent);
			}
			buf.append_char(')');
			return;
		case METHODCALL:
			fmt_expr(buf, e.children[0], indent);
			buf.append_char('.');
			buf.append(e.name);
			buf.append_char('(');
			for (int i = 1; i < e.children.len; i++)
			{
				if (i > 1) buf.append(", ");
				fmt_expr(buf, e.children[i], indent);
			}
			buf.append_char(')');
			return;
		case IF:
		{
			long cond_w = fmt_estimate_width(e.children[0]);
			long then_w = fmt_estimate_width(e.children[1]);
			long else_w = fmt_estimate_width(e.children[2]);
			long single_w = (long)indent + 3 + cond_w + 5 + then_w + 5 + else_w;
			if (single_w < 50)
			{
				buf.append("if ");
				fmt_expr(buf, e.children[0], indent);
				buf.append(" then ");
				fmt_expr(buf, e.children[1], indent);
				buf.append(" else ");
				fmt_expr(buf, e.children[2], indent);
				return;
			}
			buf.append("if ");
			fmt_expr(buf, e.children[0], indent);
			buf.append(" then\n");
			fmt_indent(buf, indent + FMT_INDENT);
			fmt_expr(buf, e.children[1], indent + FMT_INDENT);
			buf.append("\n");
			fmt_indent(buf, indent);
			buf.append("else\n");
			fmt_indent(buf, indent + FMT_INDENT);
			fmt_expr(buf, e.children[2], indent + FMT_INDENT);
			return;
		}
		case LAMBDA:
			fmt_lambda(buf, e, indent);
			return;
		case LAMBDA_T:
			fmt_lambda(buf, e, indent);
			return;
		case GET:
			fmt_expr(buf, e.children[0], indent);
			buf.append_char('.');
			fmt_key(buf, e.children[1]);
			return;
		case SET:
			fmt_expr(buf, e.children[0], indent);
			buf.append_char('.');
			fmt_key(buf, e.children[1]);
			buf.append(" = ");
			fmt_expr(buf, e.children[2], indent);
			return;
		case RECORD:
			fmt_record(buf, e, indent);
			return;
		case ARRAY_LIT:
			fmt_array(buf, e, indent);
			return;
		case THROW:
			buf.append("throw ");
			fmt_expr(buf, e.children[0], indent);
			return;
		case TRY:
			buf.append("try ");
			fmt_expr(buf, e.children[0], indent);
			buf.append(" catch ");
			buf.append(e.name);
			buf.append_char(' ');
			fmt_expr(buf, e.children[1], indent);
			return;
		case CONSTRUCT:
			buf.append(e.name);
			buf.append_char('(');
			fmt_expr(buf, e.children[0], indent);
			buf.append_char(')');
			return;
		case MATCH:
			buf.append("match ");
			fmt_expr(buf, e.children[0], indent);
			buf.append(" {\n");
			fmt_match_arms(buf, e, indent);
			return;
		case LETREC:
		case LET_T:
			// Let binding in expression position (e.g. from...import inside a block).
			// Emit as a let chain.
			{
				AstNode* chain = e;
				while (chain != null && (chain.type == LETREC || chain.type == LET_T))
				{
					fmt_indent(buf, indent + 1);
					buf.append("let ");
					buf.append(chain.name);
					buf.append(" = ");
					fmt_expr(buf, chain.children[0], indent + 1);
					buf.append(";\n");
					chain = chain.children[1];
				}
				if (chain != null)
				{
					fmt_indent(buf, indent + 1);
					fmt_expr(buf, chain, indent + 1);
				}
			}
			return;
		case TYPEDEF:
		case SEQ:
			// Block expression — emit as { ... }
			buf.append("{\n");
			for (int i = 0; i < e.children.len; i++)
			{
				fmt_indent(buf, indent + 1);
				fmt_expr(buf, e.children[i], indent + 1);
				if (i < e.children.len - 1) buf.append("\n");
			}
			fmt_indent(buf, indent);
			buf.append("\n}");
			return;
	}
}

// ---------------------------------------------------------------------------
// Top-level emitters
// ---------------------------------------------------------------------------

fn void fmt_let_chain(DString* buf, AstNode* node, int indent)
{
	if (node == null) return;
	if (node.type == LETREC)
	{
		fmt_indent(buf, indent);
		buf.append("let ");
		buf.append(node.name);
		buf.append(" = ");
		fmt_expr(buf, node.children[0], indent);
		buf.append(";\n");
		fmt_let_chain(buf, node.children[1], indent);
		return;
	}
	if (node.type == LET_T)
	{
		fmt_indent(buf, indent);
		buf.append("let ");
		buf.append(node.name);
		if (node.ann_type != null)
		{
			buf.append(": ");
			fmt_type(buf, node.ann_type);
		}
		buf.append(" = ");
		fmt_expr(buf, node.children[0], indent);
		buf.append(";\n");
		fmt_let_chain(buf, node.children[1], indent);
		return;
	}
	if (node.type == TYPEDEF)
	{
		fmt_indent(buf, indent);
		buf.append("type ");
		buf.append(node.name);
		buf.append(" = ");
		fmt_type(buf, node.ret_type);
		buf.append(";\n");
		fmt_let_chain(buf, node.children[0], indent);
		return;
	}
	// Final body expression
	fmt_indent(buf, indent);
	fmt_expr(buf, node, indent);
	buf.append_char('\n');
}

struct FormatResult
{
	bool error;
	String message;
	String output;
}

fn FormatResult format_source(String src)
{
	FormatResult res;
	res.error = false;
	res.message = "";
	res.output = "";
	ParseResult pr = parse_source(src);
	if (pr.error)
	{
		res.error = true;
		res.message = pr.message;
		return res;
	}
	DString buf; buf.tinit();
	fmt_let_chain(&buf, pr.root, 0);
	res.output = buf.str_view();
	return res;
}
