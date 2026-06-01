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
	TK_SEMI, TK_COMMA, TK_DOT, TK_COLON, TK_EQ, TK_ARROW, TK_BANG,
	TK_PLUS, TK_MINUS, TK_STAR, TK_SLASH,
	TK_EQEQ, TK_NEQ, TK_LT, TK_GT, TK_LE, TK_GE,
	TK_AND, TK_OR,
	TK_KW_LET, TK_KW_FN, TK_KW_IF, TK_KW_THEN, TK_KW_ELSE,
	TK_KW_TRUE, TK_KW_FALSE, TK_KW_NIL,
	TK_KW_THROW, TK_KW_TRY, TK_KW_CATCH,
	TK_KW_TYPE, TK_KW_MATCH,
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
	else { t.kind = TK_IDENT; }
	return t;
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
	if (c == '.') { t.kind = TK_DOT; t.text = "."; l.pos++; return t; }
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
//   expr     := or_expr
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
//             | record_literal | array_literal
//             | "fn" "(" params? ")" ("->" type)? expr
//             | "if" expr "then" expr "else" expr
//             | "throw" expr
//             | "try" expr "catch" IDENT expr
//             | "match" expr "{" arm+ "}"
//   record_literal := "{" (field ("," field)*)? "}"
//   field    := IDENT ":" expr
//   array_literal  := "[" (expr ("," expr)*)? "]"
//   arm      := UPPER_IDENT "(" IDENT ")" "=>" expr
//   params   := param ("," param)*
//   param    := IDENT (":" type)?
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
	// Invalidate the lexer's peek cache so the next peek advances.
	p.lex.has_peek = false;
	p.cur = lex_peek(p.lex);
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
	// DString (no tinit) uses the heap allocator — the slice stays valid past
	// this function's stack frame, unlike a temp-allocated one.
	DString buf; buf.init(mem);
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
		Type* t = mem::new(Type);
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
			t = mem::new(Type);
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
			String[] nk = mem::new_array(String, (sz)(n + 1));
			Type*[] nt = mem::new_array(Type*, (sz)(n + 1));
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
		Type* t = mem::new(Type);
		*t = mk_trecord_ptr(keys, types);
		return t;
	}
	if (parser_check(p, TK_IDENT))
	{
		String n = parser_cur(p).text;
		parser_advance(p);
		Type* t = mem::new(Type);
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
			t = mem::new(Type);
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

fn AstNode* parse_postfix(Parser* p)
{
	AstNode* e = parse_primary(p);
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
			parser_advance(p);
			AstNode*[] args;
			int n = 0;
			if (!parser_check(p, TK_RPAREN))
			{
				for (;;)
				{
					AstNode* a = parse_or(p);
					if (p.error) return e;
					AstNode*[] na = mem::new_array(AstNode*, (sz)(n + 1));
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
				String mname = e.children[1].literal.str_val;
				// Pass user args (not the receiver) — the desugarer binds
				// the receiver as the first argument of the call.
				e = make_methodcall(recv, mname, args);
			}
			else
			{
				e = make_call(e, args);
			}
		}
		else if (parser_check(p, TK_LBRACK))
		{
			parser_advance(p);
			AstNode* idx = parse_or(p);
			if (p.error) return e;
			if (!parser_accept(p, TK_RBRACK))
			{
				parser_set_error(p, "expected ']' to close index");
				return e;
			}
			e = make_get(e, idx);
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
	String[] keys = {};
	AstNode*[] vals = {};
	int n = 0;
	if (!parser_check(p, TK_RBRACE))
	{
		for (;;)
		{
			if (!parser_check(p, TK_IDENT))
			{
				parser_set_error(p, "expected field name in record literal");
				return make_record({}, {});
			}
			String k = parser_cur(p).text;
			parser_advance(p);
			if (!parser_accept(p, TK_COLON))
			{
				parser_set_error(p, "expected ':' after record field name");
				return make_record({}, {});
			}
			AstNode* v = parse_or(p);
			if (p.error) return make_record({}, {});
			String[] nk = mem::new_array(String, (sz)(n + 1));
			AstNode*[] nv = mem::new_array(AstNode*, (sz)(n + 1));
			for (int i = 0; i < n; i++) { nk[i] = keys[i]; nv[i] = vals[i]; }
			nk[n] = k;
			nv[n] = v;
			keys = nk;
			vals = nv;
			n++;
			if (!parser_accept(p, TK_COMMA)) break;
		}
	}
	if (!parser_accept(p, TK_RBRACE))
	{
		parser_set_error(p, "expected '}' to close record");
		return make_record(keys, vals);
	}
	return make_record(keys, vals);
}

fn AstNode* parse_array_lit(Parser* p)
{
	AstNode*[] items = {};
	int n = 0;
	if (!parser_check(p, TK_RBRACK))
	{
		for (;;)
		{
			AstNode* e = parse_or(p);
			if (p.error) return make_array({});
			AstNode*[] ni = mem::new_array(AstNode*, (sz)(n + 1));
			for (int i = 0; i < n; i++) ni[i] = items[i];
			ni[n] = e;
			items = ni;
			n++;
			if (parser_accept(p, TK_COMMA)) continue;
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

fn AstNode* parse_primary(Parser* p)
{
	Token t = parser_cur(p);
	switch (t.kind)
	{
		case TK_NUM:
			parser_advance(p);
			return make_lit(mk_num(t.num_val));
		case TK_STR:
			parser_advance(p);
			return make_lit(mk_str(t.text));
		case TK_KW_TRUE:
			parser_advance(p);
			return make_lit(mk_bool(true));
		case TK_KW_FALSE:
			parser_advance(p);
			return make_lit(mk_bool(false));
		case TK_KW_NIL:
			parser_advance(p);
			return make_lit(mk_nil());
		case TK_IDENT:
			parser_advance(p);
			return make_var(t.text);
		case TK_LPAREN:
			parser_advance(p);
			AstNode* e = parse_or(p);
			if (p.error) return e;
			if (!parser_accept(p, TK_RPAREN))
			{
				parser_set_error(p, "expected ')' to close parenthesized expression");
				return e;
			}
			return e;
		case TK_LBRACE:
			parser_advance(p);
			return parse_record_lit(p);
		case TK_LBRACK:
			parser_advance(p);
			return parse_array_lit(p);
		case TK_KW_FN:
			parser_advance(p);
			if (!parser_accept(p, TK_LPAREN))
			{
				parser_set_error(p, "expected '(' after 'fn'");
				return make_lit(mk_nil());
			}
			String[] pnames = {};
			Type*[] ptypes = {};
			int pn = 0;
			if (!parser_check(p, TK_RPAREN))
			{
				for (;;)
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
					String[] npn = mem::new_array(String, (sz)(pn + 1));
					Type*[] npt = mem::new_array(Type*, (sz)(pn + 1));
					for (int i = 0; i < pn; i++) { npn[i] = pnames[i]; npt[i] = ptypes[i]; }
					npn[pn] = name;
					npt[pn] = pt;
					pnames = npn;
					ptypes = npt;
					pn++;
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
			// Function body: either a single expression, or `{ expr }` for
			// readability.  The braced form is just a wrapper.
			AstNode* body;
			if (parser_check(p, TK_LBRACE))
			{
				parser_advance(p);
				body = parse_or(p);
				if (p.error) return body;
				if (!parser_accept(p, TK_RBRACE))
				{
					parser_set_error(p, "expected '}' to close function body");
					return body;
				}
			}
			else
			{
				body = parse_or(p);
				if (p.error) return body;
			}
			if (ret != null) return make_typed_lambda(pnames, ptypes, ret, body);
			return make_lambda(pnames, body);
		case TK_KW_IF:
			parser_advance(p);
			AstNode* c = parse_or(p);
			if (p.error) return c;
			if (!parser_accept(p, TK_KW_THEN))
			{
				parser_set_error(p, "expected 'then' after if condition");
				return c;
			}
			AstNode* tt = parse_or(p);
			if (p.error) return tt;
			if (!parser_accept(p, TK_KW_ELSE))
			{
				parser_set_error(p, "expected 'else' after if-then");
				return tt;
			}
			AstNode* el = parse_or(p);
			if (p.error) return el;
			return make_if(c, tt, el);
		case TK_KW_THROW:
			parser_advance(p);
			AstNode* v = parse_or(p);
			if (p.error) return v;
			return make_throw(v);
		case TK_KW_TRY:
			parser_advance(p);
			AstNode* body_e = parse_or(p);
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
			AstNode* handler = parse_or(p);
			if (p.error) return handler;
			return make_try(body_e, cname, handler);
		case TK_KW_MATCH:
			parser_advance(p);
			AstNode* scrut = parse_or(p);
			if (p.error) return scrut;
			if (!parser_accept(p, TK_LBRACE))
			{
				parser_set_error(p, "expected '{' after 'match'");
				return scrut;
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
				AstNode* body_arm = parse_or(p);
				if (p.error) return scrut;
				String[] nt = mem::new_array(String, (sz)(an + 1));
				String[] nb = mem::new_array(String, (sz)(an + 1));
				AstNode*[] nc = mem::new_array(AstNode*, (sz)(an + 1));
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
		AstNode* init = parse_or(p);
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
	AstNode* e = parse_or(p);
	parser_accept(p, TK_SEMI);
	return e;
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
		AstNode*[] ni = mem::new_array(AstNode*, (sz)(n + 1));
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
			// Bare expression at non-final position: just sequence it via SEQ
			// and the desugarer's discard-binding keeps the env intact.
			AstNode*[] seq_items = mem::new_array(AstNode*, 2);
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
