module engine;
import std::io;

// ============================================================================
// LEXER
// ============================================================================

enum TokKind : char
{
	TK_EOF,
	TK_NUM, TK_STR, TK_IDENT,
	TK_LPAREN, TK_RPAREN, TK_LBRACE, TK_RBRACE, TK_LBRACK, TK_RBRACK,
	TK_SEMI, TK_COMMA, TK_DOT, TK_DOTDOT, TK_DOTDOTDOT, TK_COLON, TK_EQ, TK_ARROW, TK_BANG,
	TK_PLUS, TK_MINUS, TK_STAR, TK_SLASH,
	TK_EQEQ, TK_NEQ, TK_LT, TK_GT, TK_LE, TK_GE,
	TK_AND, TK_OR, TK_QUESTQUEST,
	TK_KW_LET, TK_KW_FN, TK_KW_IF, TK_KW_THEN, TK_KW_ELSE,
	TK_KW_TRUE, TK_KW_FALSE, TK_KW_NIL,
	TK_KW_THROW, TK_KW_TRY, TK_KW_CATCH,
	TK_KW_TYPE, TK_KW_MATCH,
	TK_DOLLAR,
	TK_KW_FROM, TK_KW_IMPORT,
}

struct Token
{
	TokKind kind;
	String text;
	double num_val;
	long line;
	long col;
}

struct Lexer
{
	String src;
	long pos;
	long line;
	long col;
	bool has_peek;
	Token peek_tok;
}

fn bool is_digit(char c) => c >= '0' && c <= '9';
fn bool is_alpha(char c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
fn bool is_alnum(char c) => is_digit(c) || is_alpha(c);

fn void lex_skip_ws_and_comments(Lexer* l)
{
	while (l.pos < l.src.len)
	{
		char c = l.src[l.pos];
		if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
		{
			if (c == '\n') { l.line++; l.col = 0; }
			else { l.col++; }
			l.pos++;
			continue;
		}
		if (c == '/' && l.pos + 1 < l.src.len && l.src[l.pos + 1] == '/')
		{
			while (l.pos < l.src.len && l.src[l.pos] != '\n') l.pos++;
			continue;
		}
		if (c == '/' && l.pos + 1 < l.src.len && l.src[l.pos + 1] == '*')
		{
			l.pos += 2;
			while (l.pos + 1 < l.src.len && !(l.src[l.pos] == '*' && l.src[l.pos + 1] == '/'))
			{
				if (l.src[l.pos] == '\n') { l.line++; l.col = 0; }
				l.pos++;
			}
			l.pos += 2;
			continue;
		}
		break;
	}
}

fn Token lex_number(Lexer* l, long start_line, long start_col)
{
	long start = l.pos;
	while (l.pos < l.src.len && is_digit(l.src[l.pos])) l.pos++;
	bool is_float = false;
	if (l.pos < l.src.len && l.src[l.pos] == '.' && l.pos + 1 < l.src.len && is_digit(l.src[l.pos + 1]))
	{
		is_float = true;
		l.pos++;
		while (l.pos < l.src.len && is_digit(l.src[l.pos])) l.pos++;
	}
	if (l.pos < l.src.len && (l.src[l.pos] == 'e' || l.src[l.pos] == 'E'))
	{
		is_float = true;
		l.pos++;
		if (l.pos < l.src.len && (l.src[l.pos] == '+' || l.src[l.pos] == '-')) l.pos++;
		while (l.pos < l.src.len && is_digit(l.src[l.pos])) l.pos++;
	}
	String text = l.src[start:l.pos - start];
	double v = 0.0;
	if (is_float)
	{
		long dot = -1;
		for (long i = 0; i < text.len; i++) if (text[i] == '.') { dot = i; break; }
		long e_at = -1;
		for (long i = 0; i < text.len; i++) if (text[i] == 'e' || text[i] == 'E') { e_at = i; break; }
		long int_end = dot >= 0 ? dot : (e_at >= 0 ? e_at : text.len);
		double whole = 0.0;
		for (long i = 0; i < int_end; i++) whole = whole * 10.0 + (double)(text[i] - '0');
		double frac = 0.0;
		if (dot >= 0)
		{
			long frac_end = e_at >= 0 ? e_at : text.len;
			double div = 1.0;
			for (long i = dot + 1; i < frac_end; i++) { frac = frac * 10.0 + (double)(text[i] - '0'); div *= 10.0; }
			frac = frac / div;
		}
		v = whole + frac;
		if (e_at >= 0)
		{
			long exp = 0;
			long s = e_at + 1;
			long sign = 1;
			if (s < text.len && (text[s] == '+' || text[s] == '-')) { if (text[s] == '-') sign = -1; s++; }
			for (long i = s; i < text.len; i++) exp = exp * 10 + (long)(text[i] - '0');
			exp *= sign;
			double pow10 = 1.0;
			if (exp > 0) { for (long i = 0; i < exp; i++) pow10 *= 10.0; }
			else { for (long i = 0; i < -exp; i++) pow10 /= 10.0; }
			v *= pow10;
		}
	}
	else
	{
		for (long i = 0; i < text.len; i++) v = v * 10.0 + (double)(text[i] - '0');
	}
	Token t;
	t.kind = TK_NUM;
	t.text = text;
	t.num_val = v;
	t.line = start_line;
	t.col = start_col;
	return t;
}

fn Token lex_string(Lexer* l, long start_line, long start_col)
{
	l.pos++;
	DString buf; buf.tinit();
	while (l.pos < l.src.len && l.src[l.pos] != '"')
	{
		if (l.src[l.pos] == '\\' && l.pos + 1 < l.src.len)
		{
			char esc = l.src[l.pos + 1];
			switch (esc)
			{
				case 'n': buf.append_char('\n'); break;
				case 't': buf.append_char('\t'); break;
				case 'r': buf.append_char('\r'); break;
				case '\\': buf.append_char('\\'); break;
				case '"': buf.append_char('"'); break;
				default: buf.append_char(esc); break;
			}
			l.pos += 2;
			continue;
		}
		buf.append_char(l.src[l.pos]);
		l.pos++;
	}
	if (l.pos < l.src.len) l.pos++;
	Token t;
	t.kind = TK_STR;
	t.text = buf.str_view();
	t.num_val = 0.0;
	t.line = start_line;
	t.col = start_col;
	return t;
}

fn Token lex_ident(Lexer* l, long start_line, long start_col)
{
	long start = l.pos;
	while (l.pos < l.src.len && is_alnum(l.src[l.pos])) l.pos++;
	String text = l.src[start:l.pos - start];
	Token t;
	t.text = text;
	t.num_val = 0.0;
	t.line = start_line;
	t.col = start_col;
	if (text == "let") { t.kind = TK_KW_LET; }
	else if (text == "fn") { t.kind = TK_KW_FN; }
	else if (text == "if") { t.kind = TK_KW_IF; }
	else if (text == "then") { t.kind = TK_KW_THEN; }
	else if (text == "else") { t.kind = TK_KW_ELSE; }
	else if (text == "true") { t.kind = TK_KW_TRUE; }
	else if (text == "false") { t.kind = TK_KW_FALSE; }
	else if (text == "nil") { t.kind = TK_KW_NIL; }
	else if (text == "throw") { t.kind = TK_KW_THROW; }
	else if (text == "try") { t.kind = TK_KW_TRY; }
	else if (text == "catch") { t.kind = TK_KW_CATCH; }
	else if (text == "type") { t.kind = TK_KW_TYPE; }
	else if (text == "match") { t.kind = TK_KW_MATCH; }
	else if (text == "and") { t.kind = TK_AND; }
	else if (text == "or") { t.kind = TK_OR; }
	else if (text == "from") { t.kind = TK_KW_FROM; }
	else if (text == "import") { t.kind = TK_KW_IMPORT; }
	else { t.kind = TK_IDENT; }
	return t;
}

// Module import resolution: maps (module, local_name) → primitive name.
fn String resolve_module_import(String mod, String name) {
	if (mod == "signals") {
		if (name == "get") return "signal_get";
		if (name == "set") return "signal_set";
		if (name == "signal") return "signal";
		if (name == "derived") return "derived";
		if (name == "effect") return "effect";
	}
	return name; // unknown module: return as-is
}

fn Token lex_one(Lexer* l, long start_line, long start_col)
{
	Token t;
	t.num_val = 0.0;
	t.line = start_line;
	t.col = start_col;
	char c = l.src[l.pos];
	if (c == '(') { t.kind = TK_LPAREN; t.text = "("; l.pos++; return t; }
	if (c == ')') { t.kind = TK_RPAREN; t.text = ")"; l.pos++; return t; }
	if (c == '{') { t.kind = TK_LBRACE; t.text = "{"; l.pos++; return t; }
	if (c == '}') { t.kind = TK_RBRACE; t.text = "}"; l.pos++; return t; }
	if (c == '[') { t.kind = TK_LBRACK; t.text = "["; l.pos++; return t; }
	if (c == ']') { t.kind = TK_RBRACK; t.text = "]"; l.pos++; return t; }
	if (c == ';') { t.kind = TK_SEMI; t.text = ";"; l.pos++; return t; }
	if (c == ',') { t.kind = TK_COMMA; t.text = ","; l.pos++; return t; }
	if (c == '.')
	{
		if (l.pos + 1 < l.src.len && l.src[l.pos + 1] == '.')
		{
			if (l.pos + 2 < l.src.len && l.src[l.pos + 2] == '.')
			{
				t.kind = TK_DOTDOTDOT; t.text = "..."; l.pos += 3; return t;
			}
			t.kind = TK_DOTDOT; t.text = ".."; l.pos += 2; return t;
		}
		t.kind = TK_DOT; t.text = "."; l.pos++; return t;
	}
	if (c == ':') { t.kind = TK_COLON; t.text = ":"; l.pos++; return t; }
	if (c == '+') { t.kind = TK_PLUS; t.text = "+"; l.pos++; return t; }
	if (c == '-')
	{
		if (l.pos + 1 < l.src.len && l.src[l.pos + 1] == '>')
		{
			t.kind = TK_ARROW; t.text = "->"; l.pos += 2; return t;
		}
		t.kind = TK_MINUS; t.text = "-"; l.pos++; return t;
	}
	if (c == '*') { t.kind = TK_STAR; t.text = "*"; l.pos++; return t; }
	if (c == '/') { t.kind = TK_SLASH; t.text = "/"; l.pos++; return t; }
	if (c == '$') { t.kind = TK_DOLLAR; t.text = "$"; l.pos++; return t; }
	if (c == '!')
	{
		if (l.pos + 1 < l.src.len && l.src[l.pos + 1] == '=' && l.pos + 2 < l.src.len && l.src[l.pos + 2] == '=')
		{
			t.kind = TK_NEQ; t.text = "!=="; l.pos += 3; return t;
		}
		t.kind = TK_BANG; t.text = "!"; l.pos++; return t;
	}
	if (c == '=')
	{
		if (l.pos + 1 < l.src.len && l.src[l.pos + 1] == '=' && l.pos + 2 < l.src.len && l.src[l.pos + 2] == '=')
		{
			t.kind = TK_EQEQ; t.text = "==="; l.pos += 3; return t;
		}
		t.kind = TK_EQ; t.text = "="; l.pos++; return t;
	}
	if (c == '<')
	{
		if (l.pos + 1 < l.src.len && l.src[l.pos + 1] == '=')
		{
			t.kind = TK_LE; t.text = "<="; l.pos += 2; return t;
		}
		t.kind = TK_LT; t.text = "<"; l.pos++; return t;
	}
	if (c == '>')
	{
		if (l.pos + 1 < l.src.len && l.src[l.pos + 1] == '=')
		{
			t.kind = TK_GE; t.text = ">="; l.pos += 2; return t;
		}
		t.kind = TK_GT; t.text = ">"; l.pos++; return t;
	}
	if (c == '?' && l.pos + 1 < l.src.len && l.src[l.pos + 1] == '?')
	{
		t.kind = TK_QUESTQUEST; t.text = "??"; l.pos += 2; return t;
	}
	t.kind = TK_EOF;
	t.text = "";
	return t;
}

fn Token lex_next(Lexer* l)
{
	lex_skip_ws_and_comments(l);
	if (l.pos >= l.src.len)
	{
		Token t;
		t.kind = TK_EOF;
		t.text = "";
		t.num_val = 0.0;
		t.line = l.line;
		t.col = l.col;
		return t;
	}
	long sl = l.line;
	long sc = l.col;
	char c = l.src[l.pos];
	if (is_digit(c)) return lex_number(l, sl, sc);
	if (c == '"') return lex_string(l, sl, sc);
	if (is_alpha(c)) return lex_ident(l, sl, sc);
	return lex_one(l, sl, sc);
}

fn Token lex_peek(Lexer* l)
{
	if (l.has_peek) return l.peek_tok;
	l.peek_tok = lex_next(l);
	l.has_peek = true;
	return l.peek_tok;
}

fn void lex_init(Lexer* l, String src)
{
	l.src = src;
	l.pos = 0;
	l.line = 0;
	l.col = 0;
	l.has_peek = false;
}

// ============================================================================
// PARSER
// ============================================================================
//
// Surface grammar supported by the parser:
//
//   program  := toplevel* EOF
//   toplevel := "let" IDENT (":" type)? "=" expr ";"? | expr ";"?
//   expr     := nullcoal
//   nullcoal := or ("??" or)*
//   or       := and ("or" and)*
//   and      := eq ("and" eq)*
//   eq       := cmp (("==="|"!==") cmp)*
//   cmp      := add (("<"|">"|"<="|">=") add)*
//   add      := mul (("+"|"-") mul)*
//   mul      := unary (("*"|"/") unary)*
//   unary    := ("-"|"!") unary | postfix
//   postfix  := primary postfix_op*
//   postfix_op := "." IDENT | "(" args? ")" | "[" expr "]"
//   primary  := NUM | STR | "true"|"false"|"nil" | IDENT
//             | "(" expr ")"
//             | record_literal | array_literal | block_expr
//             | "fn" IDENT? "(" params? ")" ("->" type)? expr
//             | "if" expr "then" expr "else" expr
//             | "throw" expr
//             | "try" expr "catch" IDENT expr
//             | "match" expr "{" arm+ "}"
//   record_literal := "{" IDENT ":" expr ("," IDENT ":" expr)* "}"
//   block_expr     := "{" (let_decl | fn_decl | expr) (";" ...)* "}"
//   field    := IDENT ":" expr
//   array_literal  := "[" (expr ("," expr)*)? "]"
//   arm      := UPPER_IDENT "(" IDENT ")" "=>" expr
//   params   := param ("," param)*
//   param    := IDENT (":" type)? | "{" IDENT ("," IDENT)* "}"
//   type     := "Int"|"Number"|"String"|"Bool"
//             | type "[]" | IDENT | "{" tfield ("," tfield)* "}"
//   tfield   := IDENT ":" type
//
// Note: function bodies are a single expression (no statement blocks yet).

struct Parser
{
	Lexer* lex;
	Token cur;
	bool has_cur;
	bool error;
	String error_msg;
}

fn void parser_init(Parser* p, Lexer* l)
{
	p.lex = l;
	p.error = false;
	p.error_msg = "";
	p.has_cur = false;
}

fn Token parser_advance(Parser* p)
{
	Token t = parser_cur(p);
	// If the lexer already cached the next token, that IS the new current
	// — adopt it.  Otherwise (e.g. on the very first advance), lex the
	// next token fresh.  Either way, advance the cache to the token AFTER
	// the new current so the next call sees a fresh peek.
	if (p.lex.has_peek)
	{
		p.cur   = p.lex.peek_tok;
		p.lex.peek_tok = lex_next(p.lex);
	}
	else
	{
		p.cur   = lex_next(p.lex);
		p.lex.has_peek = true;
		p.lex.peek_tok = lex_next(p.lex);
	}
	p.has_cur = true;
	return t;
}

fn Token parser_cur(Parser* p)
{
	if (!p.has_cur) { p.cur = lex_next(p.lex); p.has_cur = true; }
	return p.cur;
}

fn void parser_set_error(Parser* p, String msg)
{
	if (p.error) return;
	p.error = true;
	// tinit uses the temp allocator — the slice stays valid as long as
	// the enclosing @pool() scope is alive.
	DString buf; buf.tinit();
	Token t = parser_cur(p);
	buf.appendf("parse error at line %d col %d: %s (got '%s')", t.line + 1, t.col + 1, msg, t.text);
	p.error_msg = buf.str_view();
}

fn bool parser_check(Parser* p, TokKind k) => parser_cur(p).kind == k;
fn bool parser_accept(Parser* p, TokKind k)
{
	if (parser_cur(p).kind == k) { parser_advance(p); return true; }
	return false;
}

fn bool is_upper_first(String s) => s.len > 0 && s[0] >= 'A' && s[0] <= 'Z';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

fn bool any_typed(Type*[] ptypes)
{
	for (int i = 0; i < ptypes.len; i++) if (ptypes[i] != null) return true;
	return false;
}

fn Type* parse_type(Parser* p)
{
	if (parser_check(p, TK_IDENT) && (parser_cur(p).text == "Int" || parser_cur(p).text == "Number"
		|| parser_cur(p).text == "String" || parser_cur(p).text == "Bool"))
	{
		String n = parser_cur(p).text;
		parser_advance(p);
		Type* t = mem::tnew(Type);
		*t = mk_tname(n);
		while (parser_check(p, TK_LBRACK))
		{
			parser_advance(p);
			if (!parser_accept(p, TK_RBRACK))
			{
				parser_set_error(p, "expected ']' after '[' in type");
				return t;
			}
			Type* inner = t;
			t = mem::tnew(Type);
			*t = mk_tarray(*inner);
		}
		return t;
	}
	if (parser_check(p, TK_LBRACE))
	{
		parser_advance(p);
		String[] keys = {};
		Type*[] types = {};
		int n = 0;
		while (!parser_check(p, TK_RBRACE) && !parser_check(p, TK_EOF))
		{
			if (!parser_check(p, TK_IDENT))
			{
				parser_set_error(p, "expected field name in record type");
				return null;
			}
			String fname = parser_cur(p).text;
			parser_advance(p);
			if (!parser_accept(p, TK_COLON))
			{
				parser_set_error(p, "expected ':' after field name in record type");
				return null;
			}
			Type* ft = parse_type(p);
			if (ft == null) return null;
			String[] nk = mem::talloc_array(String, (sz)(n + 1));
			Type*[] nt = mem::talloc_array(Type*, (sz)(n + 1));
			for (int i = 0; i < n; i++) { nk[i] = keys[i]; nt[i] = types[i]; }
			nk[n] = fname;
			nt[n] = ft;
			keys = nk;
			types = nt;
			n++;
			if (!parser_accept(p, TK_COMMA)) break;
		}
		if (!parser_accept(p, TK_RBRACE))
		{
			parser_set_error(p, "expected '}' to close record type");
			return null;
		}
		Type* t = mem::tnew(Type);
		*t = mk_trecord_ptr(keys, types);
		return t;
	}
	if (parser_check(p, TK_IDENT))
	{
		String n = parser_cur(p).text;
		parser_advance(p);
		Type* t = mem::tnew(Type);
		*t = mk_tname(n);
		while (parser_check(p, TK_LBRACK))
		{
			parser_advance(p);
			if (!parser_accept(p, TK_RBRACK))
			{
				parser_set_error(p, "expected ']' after '[' in type");
				return t;
			}
			Type* inner = t;
			t = mem::tnew(Type);
			*t = mk_tarray(*inner);
		}
		return t;
	}
	parser_set_error(p, "expected type");
	return null;
}

// ---------------------------------------------------------------------------
// Precedence climbing (or -> and -> eq -> cmp -> add -> mul -> unary -> postfix)
// ---------------------------------------------------------------------------

fn AstNode* parse_or(Parser* p)
{
	AstNode* left = parse_and(p);
	while (!p.error && parser_check(p, TK_OR))
	{
		parser_advance(p);
		AstNode* right = parse_and(p);
		left = make_binop_node("or", left, right);
	}
	return left;
}

// a ?? b  →  NULLCOAL(a, b): rhs when lhs throws or is nil
fn AstNode* parse_nullcoal(Parser* p)
{
	AstNode* left = parse_or(p);
	while (!p.error && parser_check(p, TK_QUESTQUEST))
	{
		parser_advance(p);
		AstNode* right = parse_or(p);
		left = make_nullcoal(left, right);
	}
	return left;
}

fn AstNode* parse_expr(Parser* p) => parse_nullcoal(p);

fn AstNode* parse_and(Parser* p)
{
	AstNode* left = parse_eq(p);
	while (!p.error && parser_check(p, TK_AND))
	{
		parser_advance(p);
		AstNode* right = parse_eq(p);
		left = make_binop_node("and", left, right);
	}
	return left;
}

fn AstNode* parse_eq(Parser* p)
{
	AstNode* left = parse_cmp(p);
	while (!p.error && (parser_check(p, TK_EQEQ) || parser_check(p, TK_NEQ)))
	{
		String op = parser_cur(p).text;
		parser_advance(p);
		AstNode* right = parse_cmp(p);
		if (op == "===") { left = make_binop_node("===", left, right); }
		else { left = make_if(make_binop_node("===", left, right), make_lit(mk_bool(false)), make_lit(mk_bool(true))); }
	}
	return left;
}

fn AstNode* parse_cmp(Parser* p)
{
	AstNode* left = parse_add(p);
	while (!p.error && (parser_check(p, TK_LT) || parser_check(p, TK_GT)
		|| parser_check(p, TK_LE) || parser_check(p, TK_GE)))
	{
		// `<` followed by `/` is `</` (close tag); followed by an
		// UpperCamelCase ident is a JSX element open tag.  Both stop the
		// comparison chain so `< VStack >` is never parsed as an operator.
		if (parser_check(p, TK_LT)) {
			Token pk = lex_peek(p.lex);
			if (pk.kind == TK_SLASH) break;
			if (pk.kind == TK_IDENT && is_upper_first(pk.text)) break;
		}
		String op = parser_cur(p).text;
		parser_advance(p);
		AstNode* right = parse_add(p);
		left = make_binop_node(op, left, right);
	}
	return left;
}

fn AstNode* parse_add(Parser* p)
{
	AstNode* left = parse_mul(p);
	while (!p.error && (parser_check(p, TK_PLUS) || parser_check(p, TK_MINUS)))
	{
		String op = parser_cur(p).text;
		parser_advance(p);
		AstNode* right = parse_mul(p);
		left = make_binop_node(op, left, right);
	}
	return left;
}

fn AstNode* parse_mul(Parser* p)
{
	AstNode* left = parse_unary(p);
	while (!p.error && (parser_check(p, TK_STAR) || parser_check(p, TK_SLASH)))
	{
		String op = parser_cur(p).text;
		parser_advance(p);
		AstNode* right = parse_unary(p);
		left = make_binop_node(op, left, right);
	}
	return left;
}

fn AstNode* parse_unary(Parser* p)
{
	if (parser_check(p, TK_MINUS))
	{
		parser_advance(p);
		AstNode* e = parse_unary(p);
		return make_binop_node("*", make_lit(mk_num(-1.0)), e);
	}
	if (parser_check(p, TK_BANG))
	{
		parser_advance(p);
		AstNode* e = parse_unary(p);
		return make_if(e, make_lit(mk_bool(false)), make_lit(mk_bool(true)));
	}
	return parse_postfix(p);
}

// ---------------------------------------------------------------------------
// Element syntax (JSX-like, but "html-like tags are nested function calls")
//
//   <Foo />                       =>  Foo({})
//   <Foo bar="x" />               =>  Foo({bar: "x"})
//   <Foo bar="x">a</Foo>          =>  Foo({bar: "x"}, [a])
//   <Foo bar="x">a, b, c</Foo>    =>  Foo({bar: "x"}, [a, b, c])
//   <Foo bar="x">a b c</Foo>      =>  Foo({bar: "x"}, [a, b, c])
//
// Attribute values are limited to literals (string, number, bool, identifier)
// for v1.  Children are full expressions, whitespace or comma separated.
// ---------------------------------------------------------------------------

fn AstNode* parse_element(Parser* p)
{
	// Already at '<'.
	parser_advance(p);
	if (!parser_check(p, TK_IDENT))
	{
		parser_set_error(p, "expected tag name after '<'");
		return make_lit(mk_nil());
	}
	String tag = parser_cur(p).text;
	parser_advance(p);
	// Parse attributes: IDENT '=' value
	String[] attr_keys = {};
	AstNode*[] attr_vals = {};
	int an = 0;
	while (parser_check(p, TK_IDENT))
	{
		String k = parser_cur(p).text;
		parser_advance(p);
		if (!parser_accept(p, TK_EQ))
		{
			parser_set_error(p, "expected '=' after attribute name");
			return make_call(make_var(tag), { make_record({}, {}) });
		}
		AstNode* v;
		if (parser_check(p, TK_STR))
		{
			v = make_lit(mk_str(parser_cur(p).text));
			parser_advance(p);
		}
		else if (parser_check(p, TK_NUM))
		{
			v = make_lit(mk_num(parser_cur(p).num_val));
			parser_advance(p);
		}
		else if (parser_check(p, TK_KW_TRUE))
		{
			v = make_lit(mk_bool(true));
			parser_advance(p);
		}
		else if (parser_check(p, TK_KW_FALSE))
		{
			v = make_lit(mk_bool(false));
			parser_advance(p);
		}
		else if (parser_check(p, TK_IDENT))
		{
			// Allow dot-access expressions like state.width
			v = parse_postfix(p);
		}
		else if (parser_accept(p, TK_LPAREN))
		{
			// Allow arbitrary expressions in parens: attr=(expr)
			v = parse_expr(p);
			if (!parser_accept(p, TK_RPAREN))
			{
				parser_set_error(p, "expected ')' after JSX attribute expression");
				return make_call(make_var(tag), { make_record({}, {}) });
			}
		}
		else
		{
			parser_set_error(p, "expected attribute value (string, number, bool, or ident)");
			return make_call(make_var(tag), { make_record({}, {}) });
		}
		String[] nk = mem::talloc_array(String, (sz)(an + 1));
		AstNode*[] nv = mem::talloc_array(AstNode*, (sz)(an + 1));
		for (int i = 0; i < an; i++) { nk[i] = attr_keys[i]; nv[i] = attr_vals[i]; }
		nk[an] = k;
		nv[an] = v;
		attr_keys = nk;
		attr_vals = nv;
		an++;
	}
	AstNode* attrs = make_record(attr_keys, attr_vals);
	// Self-closing: '/>'
	if (parser_accept(p, TK_SLASH))
	{
		if (!parser_accept(p, TK_GT))
		{
			parser_set_error(p, "expected '>' to close self-closing element");
			return make_call(make_prim_node("__element"), { make_var(tag), attrs });
		}
		return make_call(make_prim_node("__element"), { make_var(tag), attrs });
	}
	if (!parser_accept(p, TK_GT))
	{
		parser_set_error(p, "expected '>' or '/>' to close element open tag");
		return make_call(make_var(tag), { attrs });
	}
	// Parse children: whitespace or comma separated expressions until '</'.
	AstNode*[] children = {};
	int cn = 0;
	while (!parser_check(p, TK_EOF))
	{
		// If we hit `</`, we're done with children.
		if (parser_check(p, TK_LT))
		{
			Token t1 = lex_peek(p.lex);
			if (t1.kind == TK_SLASH) break;
		}
		AstNode* child = parse_expr(p);
		if (p.error) return make_call(make_var(tag), { attrs });
		AstNode*[] nc = mem::talloc_array(AstNode*, (sz)(cn + 1));
		for (int i = 0; i < cn; i++) nc[i] = children[i];
		nc[cn] = child;
		children = nc;
		cn++;
		parser_accept(p, TK_COMMA); // optional comma separator
	}
	// Consume '</tag>'
	if (!parser_check(p, TK_LT))
	{
		parser_set_error(p, "expected '</' to close element");
		return make_call(make_var(tag), { attrs });
	}
	parser_advance(p); // <
	if (!parser_accept(p, TK_SLASH))
	{
		parser_set_error(p, "expected '/' after '<' in closing tag");
		return make_call(make_var(tag), { attrs });
	}
	if (!parser_check(p, TK_IDENT) || parser_cur(p).text != tag)
	{
		parser_set_error(p, "closing tag does not match opening tag");
		return make_call(make_var(tag), { attrs });
	}
	parser_advance(p);
	if (!parser_accept(p, TK_GT))
	{
		parser_set_error(p, "expected '>' to close closing tag");
	}
	// Build the call: __element(TagFn, attrs, child0, child1, ...).
	// __element handles memoization by slot; the component function receives
	// (props) or (props, [children]) depending on child count.
	AstNode*[] elem_args = mem::talloc_array(AstNode*, (sz)(2 + cn));
	elem_args[0] = make_var(tag);
	elem_args[1] = attrs;
	for (int i = 0; i < cn; i++) elem_args[2 + i] = children[i];
	return make_call(make_prim_node("__element"), elem_args[:2 + cn]);
}

fn AstNode* parse_postfix(Parser* p)
{
	// Element syntax: `<Tag attr=val ... />` or `<Tag ...>children</Tag>`.
	// Disambiguate from the comparison `<` by looking at the next token:
	// `< IDENT` is element, anything else is comparison.  Done here (not in
	// parse_unary) so postfix chains like `<Foo />.bar` still work.
	AstNode* e;
	if (parser_check(p, TK_LT))
	{
		Token t1 = lex_peek(p.lex);
		if (t1.kind == TK_IDENT)
		{
			e = parse_element(p);
		}
		else
		{
			e = parse_primary(p);
		}
	}
	else
	{
		e = parse_primary(p);
	}
	while (!p.error)
	{
		if (parser_check(p, TK_DOT))
		{
			parser_advance(p);
			if (!parser_check(p, TK_IDENT))
			{
				parser_set_error(p, "expected identifier after '.'");
				return e;
			}
			String fname = parser_cur(p).text;
			parser_advance(p);
			e = make_get(e, make_lit(mk_str(fname)));
		}
		else if (parser_check(p, TK_LPAREN))
		{
			long call_line = parser_cur(p).line + 1;
			parser_advance(p);
			AstNode*[] args;
			int n = 0;
			if (!parser_check(p, TK_RPAREN))
			{
				for (;;)
				{
					AstNode* a = parse_expr(p);
					if (p.error) return e;
					AstNode*[] na = mem::talloc_array(AstNode*, (sz)(n + 1));
					for (int i = 0; i < n; i++) na[i] = args[i];
					na[n] = a;
					args = na;
					n++;
					if (parser_accept(p, TK_COMMA)) continue;
					break;
				}
			}
			if (!parser_accept(p, TK_RPAREN))
			{
				parser_set_error(p, "expected ')' to close call");
				return e;
			}
			if (e.type == GET)
			{
				AstNode* recv = e.children[0];
				String mname = *as_str(e.children[1].literal);
				// Pass user args (not the receiver) — the desugarer binds
				// the receiver as the first argument of the call.
				e = lined(make_methodcall(recv, mname, args), call_line);
			}
			else
			{
				e = lined(make_call(e, args), call_line);
			}
		}
		else if (parser_check(p, TK_LBRACK))
		{
			parser_advance(p);
			// Slice: xs[i..], xs[..j], xs[i..j].  Desugar to a call of
			// the `slice` builtin with three args: (arr, start, end).
			// A missing bound is represented by the integer -1.
			if (parser_check(p, TK_DOTDOT))
			{
				parser_advance(p);
				AstNode* end = parse_expr(p);
				if (p.error) return e;
				AstNode*[] args = mem::talloc_array(AstNode*, 3);
				args[0] = e;
				args[1] = make_lit(mk_num(0.0));
				args[2] = end;
				e = make_call(make_var("slice"), args);
			}
			else
			{
				AstNode* start = parse_expr(p);
				if (p.error) return e;
				if (parser_check(p, TK_DOTDOT))
				{
					parser_advance(p);
					AstNode*[] args;
					if (parser_check(p, TK_RBRACK))
					{
						// xs[i..]  — slice to end.
						args = mem::talloc_array(AstNode*, 3);
						args[0] = e;
						args[1] = start;
						args[2] = make_lit(mk_num(-1.0));
					}
					else
					{
						AstNode* end = parse_expr(p);
						if (p.error) return e;
						args = mem::talloc_array(AstNode*, 3);
						args[0] = e;
						args[1] = start;
						args[2] = end;
					}
					e = make_call(make_var("slice"), args);
				}
				else
				{
					e = make_get(e, start);
				}
			}
			if (!parser_accept(p, TK_RBRACK))
			{
				parser_set_error(p, "expected ']' to close index or slice");
				return e;
			}
		}
		else
		{
			break;
		}
	}
	return e;
}

fn AstNode* parse_record_lit(Parser* p)
{
	// Already consumed the '{'.
	// Collect spread sources and regular fields separately.
	// { ...base, k: v }  →  record_spread(base, {k: v})
	// Multiple spreads allowed; each wraps the rest.
	AstNode*[] spreads = {};
	int sn = 0;
	String[] keys = {};
	AstNode*[] vals = {};
	int n = 0;
	if (!parser_check(p, TK_RBRACE))
	{
		for (;;)
		{
			if (parser_accept(p, TK_DOTDOTDOT))
			{
				AstNode* src = parse_expr(p);
				if (p.error) return make_record({}, {});
				AstNode*[] ns = mem::talloc_array(AstNode*, (sz)(sn + 1));
				for (int i = 0; i < sn; i++) ns[i] = spreads[i];
				ns[sn] = src;
				spreads = ns;
				sn++;
			}
			else
			{
				if (!parser_check(p, TK_IDENT))
				{
					parser_set_error(p, "expected field name or '...' in record literal");
					return make_record({}, {});
				}
				String k = parser_cur(p).text;
				parser_advance(p);
				if (!parser_accept(p, TK_COLON))
				{
					parser_set_error(p, "expected ':' after record field name");
					return make_record({}, {});
				}
				AstNode* v = parse_expr(p);
				if (p.error) return make_record({}, {});
				String[] nk = mem::talloc_array(String, (sz)(n + 1));
				AstNode*[] nv = mem::talloc_array(AstNode*, (sz)(n + 1));
				for (int i = 0; i < n; i++) { nk[i] = keys[i]; nv[i] = vals[i]; }
				nk[n] = k; nv[n] = v;
				keys = nk; vals = nv;
				n++;
			}
			if (parser_accept(p, TK_COMMA))
			{
				if (parser_check(p, TK_RBRACE)) break;
				continue;
			}
			break;
		}
	}
	if (!parser_accept(p, TK_RBRACE))
	{
		parser_set_error(p, "expected '}' to close record");
		return make_record(keys, vals);
	}
	AstNode* rec = make_record(keys, vals);
	// Wrap with record_spread calls, outermost spread first.
	// { ...a, ...b, k: v }  →  record_spread(a, record_spread(b, {k: v}))
	for (int i = sn - 1; i >= 0; i--) {
		rec = make_call(make_prim_node("record_spread"), { spreads[i], rec });
	}
	return rec;
}

fn AstNode* parse_array_lit(Parser* p)
{
	AstNode*[] items = {};
	int n = 0;
	if (!parser_check(p, TK_RBRACK))
	{
		for (;;)
		{
			AstNode* e = parse_expr(p);
			if (p.error) return make_array({});
			AstNode*[] ni = mem::talloc_array(AstNode*, (sz)(n + 1));
			for (int i = 0; i < n; i++) ni[i] = items[i];
			ni[n] = e;
			items = ni;
			n++;
			if (parser_accept(p, TK_COMMA))
			{
				// Trailing comma before `]` is fine.
				if (parser_check(p, TK_RBRACK)) break;
				continue;
			}
			break;
		}
	}
	if (!parser_accept(p, TK_RBRACK))
	{
		parser_set_error(p, "expected ']' to close array literal");
		return make_array(items);
	}
	return make_array(items);
}

// Destructuring record: one slot per param that used { x, y } syntax.
// pindex = which positional param was destructured; fields = names to extract.
struct DestructureSlot { int pindex; String[] fields; int nfields; }

// Shared helper: parse "(params) [-> ret_type] body" after "fn" has been consumed.
// Returns LAMBDA or LAMBDA_T.
fn AstNode* parse_lambda_params_and_body(Parser* p)
{
	if (!parser_accept(p, TK_LPAREN))
	{
		parser_set_error(p, "expected '(' after 'fn'");
		return make_lit(mk_nil());
	}
	String[] pnames = {};
	Type*[] ptypes = {};
	DestructureSlot[] dslots = {};
	int pn = 0;
	int dn = 0;
	if (!parser_check(p, TK_RPAREN))
	{
		for (;;)
		{
			if (parser_check(p, TK_LBRACE))
			{
				// Destructured record param: { x, y, z }
				// Synthesize a hidden param name "_p<n>" and record fields.
				parser_advance(p);
				String[] fields = {};
				int fn_ = 0;
				while (!p.error && !parser_check(p, TK_RBRACE) && !parser_check(p, TK_EOF))
				{
					if (!parser_check(p, TK_IDENT))
					{
						parser_set_error(p, "expected field name in destructuring pattern");
						return make_lit(mk_nil());
					}
					String fname = parser_cur(p).text;
					parser_advance(p);
					String[] nf = mem::talloc_array(String, (sz)(fn_ + 1));
					for (int i = 0; i < fn_; i++) nf[i] = fields[i];
					nf[fn_] = fname;
					fields = nf;
					fn_++;
					if (!parser_accept(p, TK_COMMA)) break;
				}
				if (!parser_accept(p, TK_RBRACE))
				{
					parser_set_error(p, "expected '}' to close destructuring pattern");
					return make_lit(mk_nil());
				}
				// Generate hidden param name
				String hidden = string::tformat("_p%d", pn);
				String[] npn = mem::talloc_array(String, (sz)(pn + 1));
				Type*[] npt = mem::talloc_array(Type*, (sz)(pn + 1));
				for (int i = 0; i < pn; i++) { npn[i] = pnames[i]; npt[i] = ptypes[i]; }
				npn[pn] = hidden;
				npt[pn] = null;
				pnames = npn;
				ptypes = npt;
				// Record the slot
				DestructureSlot[] nds = mem::talloc_array(DestructureSlot, (sz)(dn + 1));
				for (int i = 0; i < dn; i++) nds[i] = dslots[i];
				nds[dn] = { .pindex = pn, .fields = fields, .nfields = fn_ };
				dslots = nds;
				dn++;
				pn++;
			}
			else
			{
				if (!parser_check(p, TK_IDENT))
				{
					parser_set_error(p, "expected parameter name");
					return make_lit(mk_nil());
				}
				String name = parser_cur(p).text;
				parser_advance(p);
				Type* pt = null;
				if (parser_accept(p, TK_COLON))
				{
					pt = parse_type(p);
					if (pt == null) return make_lit(mk_nil());
				}
				String[] npn = mem::talloc_array(String, (sz)(pn + 1));
				Type*[] npt = mem::talloc_array(Type*, (sz)(pn + 1));
				for (int i = 0; i < pn; i++) { npn[i] = pnames[i]; npt[i] = ptypes[i]; }
				npn[pn] = name;
				npt[pn] = pt;
				pnames = npn;
				ptypes = npt;
				pn++;
			}
			if (parser_accept(p, TK_COMMA)) continue;
			break;
		}
	}
	if (!parser_accept(p, TK_RPAREN))
	{
		parser_set_error(p, "expected ')' to close parameter list");
		return make_lit(mk_nil());
	}
	Type* ret = null;
	if (parser_accept(p, TK_ARROW))
	{
		ret = parse_type(p);
		if (ret == null) return make_lit(mk_nil());
	}
	AstNode* body;
	if (parser_check(p, TK_LBRACE))
	{
		parser_advance(p);
		body = parse_block_contents(p);
		if (p.error) return body;
		if (!parser_accept(p, TK_RBRACE))
		{
			parser_set_error(p, "expected '}' to close function body");
			return body;
		}
	}
	else
	{
		body = parse_expr(p);
		if (p.error) return body;
	}
	// Wrap body with destructuring lets, innermost first (reverse order).
	// fn({ x, y }) body  →  fn(_p0) { let x = _p0.x ?? nil; let y = _p0.y ?? nil; body }
	// Missing fields yield nil rather than throwing, so ?? defaults work naturally.
	for (int di = dn - 1; di >= 0; di--)
	{
		DestructureSlot slot = dslots[di];
		String hidden = pnames[slot.pindex];
		for (int fi = slot.nfields - 1; fi >= 0; fi--)
		{
			String fname = slot.fields[fi];
			AstNode* field_get = make_try(
				make_get(make_var(hidden), make_lit(mk_str(fname))),
				"_", make_lit(mk_nil()));
			body = make_letrec(fname, field_get, body);
		}
	}
	if (ret != null) return make_typed_lambda(pnames, ptypes, ret, body);
	return make_lambda(pnames, body);
}

macro AstNode* lined(AstNode* node, long ln) { node.line = ln; return node; }

fn AstNode* parse_primary(Parser* p)
{
	Token t = parser_cur(p);
	long ln = t.line + 1; // convert to 1-indexed
	switch (t.kind)
	{
		case TK_NUM:
			parser_advance(p);
			return lined(make_lit(mk_num(t.num_val)), ln);
		case TK_STR:
			parser_advance(p);
			return lined(make_lit(mk_str(t.text)), ln);
		case TK_KW_TRUE:
			parser_advance(p);
			return lined(make_lit(mk_bool(true)), ln);
		case TK_KW_FALSE:
			parser_advance(p);
			return lined(make_lit(mk_bool(false)), ln);
		case TK_KW_NIL:
			parser_advance(p);
			return lined(make_lit(mk_nil()), ln);
		case TK_IDENT:
			parser_advance(p);
			return lined(make_var(t.text), ln);
		case TK_DOLLAR:
			parser_advance(p);
			if (!parser_check(p, TK_IDENT))
			{
				parser_set_error(p, "expected variable name after '$'");
				return make_lit(mk_nil());
			}
			String sig_name = parser_cur(p).text;
			parser_advance(p);
			// $x = expr  →  signal_set(x, expr)
			if (parser_accept(p, TK_EQ))
			{
				AstNode* val = parse_expr(p);
				if (p.error) return val;
				return make_call(make_var("signal_set"), { make_var(sig_name), val });
			}
			// $x  →  signal_get(x)
			return make_call(make_var("signal_get"), { make_var(sig_name) });
		case TK_LPAREN:
			parser_advance(p);
			AstNode* e = parse_expr(p);
			if (p.error) return e;
			if (!parser_accept(p, TK_RPAREN))
			{
				parser_set_error(p, "expected ')' to close parenthesized expression");
				return e;
			}
			return e;
		case TK_LBRACE:
			parser_advance(p);
			// Disambiguate: IDENT ":" → record literal, otherwise → block expression
			if ((parser_check(p, TK_IDENT) && p.lex.peek_tok.kind == TK_COLON) ||
			    parser_check(p, TK_DOTDOTDOT))
			{
				return parse_record_lit(p);
			}
			AstNode* block_body = parse_block_contents(p);
			if (p.error) return block_body;
			if (!parser_accept(p, TK_RBRACE))
			{
				parser_set_error(p, "expected '}' to close block");
				return block_body;
			}
			return block_body;
		case TK_LBRACK:
			parser_advance(p);
			return parse_array_lit(p);
		case TK_KW_FN:
			parser_advance(p);
			// fn IDENT(...) — named function at expression position; name is
			// visible inside the body (enables recursion).  Wrapped in LetRec
			// so the expression evaluates to the closure via Var(name).
			if (parser_check(p, TK_IDENT))
			{
				String name = parser_cur(p).text;
				parser_advance(p);
				AstNode* lambda = parse_lambda_params_and_body(p);
				if (p.error) return lambda;
				return make_letrec(name, lambda, make_var(name));
			}
			// fn(...) — anonymous lambda
			return parse_lambda_params_and_body(p);
		case TK_KW_IF:
			parser_advance(p);
			AstNode* c = parse_expr(p);
			if (p.error) return c;
			if (!parser_accept(p, TK_KW_THEN))
			{
				parser_set_error(p, "expected 'then' after if condition");
				return c;
			}
			AstNode* tt = parse_expr(p);
			if (p.error) return tt;
			if (!parser_accept(p, TK_KW_ELSE))
			{
				parser_set_error(p, "expected 'else' after if-then");
				return tt;
			}
			AstNode* el = parse_expr(p);
			if (p.error) return el;
			return make_if(c, tt, el);
		case TK_KW_THROW:
			parser_advance(p);
			AstNode* v = parse_expr(p);
			if (p.error) return v;
			return make_throw(v);
		case TK_KW_TRY:
			parser_advance(p);
			AstNode* body_e = parse_expr(p);
			if (p.error) return body_e;
			if (!parser_accept(p, TK_KW_CATCH))
			{
				parser_set_error(p, "expected 'catch' after try");
				return body_e;
			}
			if (!parser_check(p, TK_IDENT))
			{
				parser_set_error(p, "expected catch binding name");
				return body_e;
			}
			String cname = parser_cur(p).text;
			parser_advance(p);
			AstNode* handler = parse_expr(p);
			if (p.error) return handler;
			return make_try(body_e, cname, handler);
		case TK_KW_MATCH:
			parser_advance(p);
			AstNode* scrut = parse_expr(p);
			if (p.error) return scrut;
			if (!parser_accept(p, TK_LBRACE))
			{
				parser_set_error(p, "expected '{' after 'match'");
				return scrut;
			}
			// Peek at the first arm to decide: tagged (UpperCamelCase IDENT) or primitive.
			bool is_primitive_match =
				parser_check(p, TK_NUM) ||
				parser_check(p, TK_STR) ||
				parser_check(p, TK_KW_TRUE) ||
				parser_check(p, TK_KW_FALSE) ||
				parser_check(p, TK_KW_NIL) ||
				parser_check(p, TK_RBRACE) ||
				(parser_check(p, TK_IDENT) && !is_upper_first(parser_cur(p).text));
			if (is_primitive_match)
			{
				AstNode*[] pm_patterns = {};
				AstNode*[] pm_bodies = {};
				int pn = 0;
				while (!parser_check(p, TK_RBRACE) && !parser_check(p, TK_EOF))
				{
					// Pattern: literal, variable reference, or _ wildcard
					AstNode* pat_node;
					if (parser_check(p, TK_NUM))
					{
						pat_node = make_lit(mk_num(parser_cur(p).num_val));
						parser_advance(p);
					}
					else if (parser_check(p, TK_STR))
					{
						pat_node = make_lit(mk_str(parser_cur(p).text));
						parser_advance(p);
					}
					else if (parser_check(p, TK_KW_TRUE))
					{
						pat_node = make_lit(mk_bool(true));
						parser_advance(p);
					}
					else if (parser_check(p, TK_KW_FALSE))
					{
						pat_node = make_lit(mk_bool(false));
						parser_advance(p);
					}
					else if (parser_check(p, TK_KW_NIL))
					{
						pat_node = make_lit(mk_nil());
						parser_advance(p);
					}
					else if (parser_check(p, TK_IDENT))
					{
						// _ = wildcard; other lowercase ident = variable pattern (compare by value)
						pat_node = make_var(parser_cur(p).text);
						parser_advance(p);
					}
					else
					{
						parser_set_error(p, "expected literal, variable, or _ in match arm");
						return scrut;
					}
					if (!parser_accept(p, TK_ARROW))
					{
						parser_set_error(p, "expected '->' in match arm");
						return scrut;
					}
					AstNode* body_arm = parse_expr(p);
					if (p.error) return scrut;
					AstNode*[] np = mem::talloc_array(AstNode*, (sz)(pn + 1));
					AstNode*[] nb2 = mem::talloc_array(AstNode*, (sz)(pn + 1));
					for (int i = 0; i < pn; i++) { np[i] = pm_patterns[i]; nb2[i] = pm_bodies[i]; }
					np[pn] = pat_node; nb2[pn] = body_arm;
					pm_patterns = np; pm_bodies = nb2;
					pn++;
					parser_accept(p, TK_COMMA);
				}
				if (!parser_accept(p, TK_RBRACE))
				{
					parser_set_error(p, "expected '}' to close match");
					return scrut;
				}
				return make_pmatch(scrut, pm_patterns, pm_bodies);
			}
			String[] tags = {};
			String[] binds = {};
			AstNode*[] bodies = {};
			int an = 0;
			while (!parser_check(p, TK_RBRACE) && !parser_check(p, TK_EOF))
			{
				if (!parser_check(p, TK_IDENT) || !is_upper_first(parser_cur(p).text))
				{
					parser_set_error(p, "expected UpperCamelCase tag in match arm");
					return scrut;
				}
				String tag = parser_cur(p).text;
				parser_advance(p);
				if (!parser_accept(p, TK_LPAREN))
				{
					parser_set_error(p, "expected '(' after match tag");
					return scrut;
				}
				if (!parser_check(p, TK_IDENT))
				{
					parser_set_error(p, "expected binding in match arm");
					return scrut;
				}
				String bind = parser_cur(p).text;
				parser_advance(p);
				if (!parser_accept(p, TK_RPAREN))
				{
					parser_set_error(p, "expected ')' after match binding");
					return scrut;
				}
				if (!parser_accept(p, TK_ARROW))
				{
					parser_set_error(p, "expected '=>' in match arm");
					return scrut;
				}
				AstNode* body_arm = parse_expr(p);
				if (p.error) return scrut;
				String[] nt = mem::talloc_array(String, (sz)(an + 1));
				String[] nb = mem::talloc_array(String, (sz)(an + 1));
				AstNode*[] nc = mem::talloc_array(AstNode*, (sz)(an + 1));
				for (int i = 0; i < an; i++) { nt[i] = tags[i]; nb[i] = binds[i]; nc[i] = bodies[i]; }
				nt[an] = tag;
				nb[an] = bind;
				nc[an] = body_arm;
				tags = nt; binds = nb; bodies = nc;
				an++;
				parser_accept(p, TK_COMMA);
			}
			if (!parser_accept(p, TK_RBRACE))
			{
				parser_set_error(p, "expected '}' to close match");
				return scrut;
			}
			return make_match(scrut, tags, binds, bodies);
		default:
			parser_set_error(p, "expected expression");
			parser_advance(p);
			return make_lit(mk_nil());
	}
}

fn AstNode* parse_toplevel(Parser* p)
{
	if (parser_check(p, TK_KW_LET))
	{
		parser_advance(p);
		// let $x = expr  →  let x = signal(expr)
		if (parser_accept(p, TK_DOLLAR))
		{
			if (!parser_check(p, TK_IDENT))
			{
				parser_set_error(p, "expected name after 'let $'");
				return make_lit(mk_nil());
			}
			String name = parser_cur(p).text;
			parser_advance(p);
			if (!parser_accept(p, TK_EQ))
			{
				parser_set_error(p, "expected '=' in let $");
				return make_lit(mk_nil());
			}
			AstNode* init = parse_expr(p);
			if (p.error) return init;
			parser_accept(p, TK_SEMI);
			AstNode* sig_init = make_call(make_var("signal"), { init });
			return make_letrec(name, sig_init, make_lit(mk_nil()));
		}
		if (!parser_check(p, TK_IDENT))
		{
			parser_set_error(p, "expected name after 'let'");
			return make_lit(mk_nil());
		}
		String name = parser_cur(p).text;
		parser_advance(p);
		Type* ann = null;
		if (parser_accept(p, TK_COLON))
		{
			ann = parse_type(p);
			if (ann == null) return make_lit(mk_nil());
		}
		if (!parser_accept(p, TK_EQ))
		{
			parser_set_error(p, "expected '=' in let");
			return make_lit(mk_nil());
		}
		AstNode* init = parse_expr(p);
		if (p.error) return init;
		parser_accept(p, TK_SEMI);
		// Body is unknown here — parse_program builds a nested let chain so
		// each `let`'s name stays in scope for the rest of the program.  We
		// just emit the let with a placeholder body; parse_program will
		// re-thread the body.
		AstNode* body = make_lit(mk_nil());
		if (ann != null) return make_typed_let(name, ann, init, body);
		return make_letrec(name, init, body);
	}
	if (parser_check(p, TK_KW_FN) && lex_peek(p.lex).kind == TK_IDENT)
	{
		parser_advance(p);
		String name = parser_cur(p).text;
		parser_advance(p);
		AstNode* lambda = parse_lambda_params_and_body(p);
		if (p.error) return lambda;
		parser_accept(p, TK_SEMI);
		AstNode* body = make_lit(mk_nil());
		return make_letrec(name, lambda, body);
	}
	// from MODULE import { name, name, ... }
	if (parser_check(p, TK_KW_FROM))
	{
		parser_advance(p);
		// from "path" import *  →  loadlib("path")  (dynamic library)
		if (parser_check(p, TK_STR))
		{
			String path = parser_cur(p).text;
			parser_advance(p);
			if (!parser_accept(p, TK_KW_IMPORT))
			{
				parser_set_error(p, "expected 'import' after library path");
				return make_lit(mk_nil());
			}
			if (!parser_accept(p, TK_STAR))
			{
				parser_set_error(p, "expected '*' after 'import' for dynamic libraries");
				return make_lit(mk_nil());
			}
			parser_accept(p, TK_SEMI);
			return make_call(make_var("loadlib"), { make_lit(mk_str(path)) });
		}
		if (!parser_check(p, TK_IDENT))
		{
			parser_set_error(p, "expected module name after 'from'");
			return make_lit(mk_nil());
		}
		String mod = parser_cur(p).text;
		parser_advance(p);
		if (!parser_accept(p, TK_KW_IMPORT))
		{
			parser_set_error(p, "expected 'import' after module name");
			return make_lit(mk_nil());
		}
		if (!parser_accept(p, TK_LBRACE))
		{
			parser_set_error(p, "expected '{' after 'import'");
			return make_lit(mk_nil());
		}
		// Collect imported names.
		String[16] names_buf;
		int nn = 0;
		while (!parser_check(p, TK_RBRACE) && !parser_check(p, TK_EOF))
		{
			if (!parser_check(p, TK_IDENT))
			{
				parser_set_error(p, "expected name in import list");
				return make_lit(mk_nil());
			}
			names_buf[nn++] = parser_cur(p).text;
			parser_advance(p);
			parser_accept(p, TK_COMMA);
		}
		if (!parser_accept(p, TK_RBRACE))
		{
			parser_set_error(p, "expected '}' to close import list");
			return make_lit(mk_nil());
		}
		parser_accept(p, TK_SEMI);
		// Build nested letrec bindings: let get = signal_get; let set = signal_set; ...
		// The module table maps (module, local_name) → primitive_name.
		AstNode* body = make_lit(mk_nil());
		for (int i = nn - 1; i >= 0; i--)
		{
			String prim = resolve_module_import(mod, names_buf[i]);
			body = make_letrec(names_buf[i], make_lit(mk_prim(prim)), body);
		}
		return body;
	}
	AstNode* e = parse_expr(p);
	parser_accept(p, TK_SEMI);
	return e;
}

// parse_block_contents: parse a sequence of let-bindings and expressions
// inside { ... }, separated by optional ';'.  Builds nested LetRec chains
// so each let's name stays in scope for the rest of the block.
fn AstNode* parse_block_contents(Parser* p)
{
	AstNode*[] items = {};
	int n = 0;
	while (!parser_check(p, TK_RBRACE) && !parser_check(p, TK_EOF))
	{
		AstNode* item = parse_toplevel(p);
		if (p.error) return make_lit(mk_nil());
		AstNode*[] ni = mem::talloc_array(AstNode*, (sz)(n + 1));
		for (int i = 0; i < n; i++) ni[i] = items[i];
		ni[n] = item;
		items = ni;
		n++;
		parser_accept(p, TK_SEMI);
	}
	if (n == 0) return make_lit(mk_nil());
	AstNode* body = items[n - 1];
	for (int i = n - 2; i >= 0; i--)
	{
		AstNode* item = items[i];
		if (item.type == LETREC)
		{
			body = make_letrec(item.name, item.children[0], body);
		}
		else if (item.type == LET_T)
		{
			body = make_typed_let(item.name, item.ann_type, item.children[0], body);
		}
		else
		{
			AstNode*[] seq_items = mem::talloc_array(AstNode*, 2);
			seq_items[0] = item;
			seq_items[1] = body;
			body = make_seq(seq_items);
		}
	}
	return body;
}

fn AstNode* parse_program(Parser* p)
{
	// Collect all toplevel items, then build a nested LetRec chain so the
	// bindings stay in scope for the final expression.  The last item is
	// the body's value (it can be either a let-stmt or an expression).
	AstNode*[] items = {};
	int n = 0;
	while (!parser_check(p, TK_EOF))
	{
		AstNode* item = parse_toplevel(p);
		if (p.error) return make_lit(mk_nil());
		AstNode*[] ni = mem::talloc_array(AstNode*, (sz)(n + 1));
		for (int i = 0; i < n; i++) ni[i] = items[i];
		ni[n] = item;
		items = ni;
		n++;
	}
	if (n == 0) return make_lit(mk_nil());
	// Walk right-to-left, building nested lets.
	AstNode* body = items[n - 1];
	for (int i = n - 2; i >= 0; i--)
	{
		AstNode* item = items[i];
		// If `item` is a LetRec, take its name + init and rewrap with `body`.
		// Flatten nested LetRec chains (from from...import).
		if (item.type == LETREC)
		{
			AstNode* chain = item;
			while (chain.type == LETREC)
			{
				body = make_letrec(chain.name, chain.children[0], body);
				chain = chain.children[1];
			}
		}
		else if (item.type == LET_T)
		{
			body = make_typed_let(item.name, item.ann_type, item.children[0], body);
		}
		else
		{
			// Bare expression at non-final position: just sequence it via SEQ
			// and the desugarer's discard-binding keeps the env intact.
			AstNode*[] seq_items = mem::talloc_array(AstNode*, 2);
			seq_items[0] = item;
			seq_items[1] = body;
			body = make_seq(seq_items);
		}
	}
	return body;
}

struct ParseResult
{
	bool error;
	String message;
	AstNode* root;
}

fn ParseResult parse_source(String src)
{
	Lexer lex;
	lex_init(&lex, src);
	Parser p;
	parser_init(&p, &lex);
	parser_cur(&p);
	ParseResult res;
	res.error = false;
	res.message = "";
	res.root = parse_program(&p);
	if (p.error)
	{
		res.error = true;
		res.message = p.error_msg;
		res.root = make_lit(mk_nil());
	}
	return res;
}
