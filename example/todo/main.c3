// Todo app host: registers milktea + glaze bindings for DS scripts,
// then loads and runs todo.ds.
//
// Build: c3c build todo
// Run:   ./build/todo

module todo_app;

import std::io;
import std::core::dstring;
import std::core::mem;
import milktea;
import glaze;
import xray;
import engine;

// ── DS-callable Value helpers ─────────────────────────────────────

fn String val_str(Value v) => engine::engine_as_str(v);
fn double  val_num(Value v) => engine::engine_as_num(v);
fn bool    val_bool(Value v) => engine::engine_as_bool(v);
fn bool    val_is_str(Value v) => engine::engine_is_str(v);
fn bool    val_is_num(Value v) => engine::engine_is_num(v);
fn bool    val_is_nil(Value v) => engine::engine_is_nil(v);
fn bool    val_is_bool(Value v) => engine::engine_is_bool(v);
fn bool    val_is_arr(Value v) => engine::engine_is_array(v);
fn bool    val_is_rec(Value v) => engine::engine_is_record(v);

fn Value str_val(String s) => engine::engine_mk_str(s);
fn Value num_val(double d)  => engine::engine_mk_num(d);
fn Value nil_val()          => engine::engine_mk_nil();
fn Value bool_val(bool b)   => engine::engine_mk_bool(b);

fn Value rec_get(Value v, String f) => engine::engine_record_get(v, f);
fn int   arr_len(Value v)  => engine::engine_array_len(v);
fn Value arr_get(Value v, int i) => engine::engine_array_get(v, i);

// ── Node tree renderer ────────────────────────────────────────────
// Components return node records with __type field.
// render_node walks the tree and produces a styled string.

fn glaze::Style node_style(Value node) @local {
	glaze::Style s = glaze::style();
	Value fg = rec_get(node, "fg");
	if (val_is_str(fg)) s = s.with_fg(val_str(fg));
	Value bg = rec_get(node, "bg");
	if (val_is_str(bg)) s = s.with_bg(val_str(bg));
	Value bold = rec_get(node, "bold");
	if (val_is_bool(bold) && val_bool(bold)) s = s.bold(true);
	Value italic = rec_get(node, "italic");
	if (val_is_bool(italic) && val_bool(italic)) s = s.italic(true);
	Value w = rec_get(node, "width");
	if (val_is_num(w)) s = s.width((int)val_num(w));
	Value h = rec_get(node, "height");
	if (val_is_num(h)) s = s.height((int)val_num(h));
	Value border = rec_get(node, "border");
	if (val_is_str(border)) {
		String bname = val_str(border);
		if (bname == "rounded") { s = s.border(glaze::rounded_border()); }
		else if (bname == "normal") { s = s.border(glaze::normal_border()); }
		Value border_fg = rec_get(node, "border_fg");
		if (val_is_str(border_fg)) { s = s.border_fg(glaze::color_hex(val_str(border_fg))); }
	}
	// Full padding: pt/pr/pb/pl override padding_x/padding_y
	Value pt = rec_get(node, "pt"); Value pr = rec_get(node, "pr");
	Value pb = rec_get(node, "pb"); Value pl = rec_get(node, "pl");
	bool has_full_pad = val_is_num(pt) || val_is_num(pr) || val_is_num(pb) || val_is_num(pl);
	if (has_full_pad) {
		int ipt = val_is_num(pt) ? (int)val_num(pt) : 0;
		int ipr = val_is_num(pr) ? (int)val_num(pr) : 0;
		int ipb = val_is_num(pb) ? (int)val_num(pb) : 0;
		int ipl = val_is_num(pl) ? (int)val_num(pl) : 0;
		s = s.padding(ipt, ipr, ipb, ipl);
	} else {
		Value px = rec_get(node, "padding_x");
		Value py = rec_get(node, "padding_y");
		int ipx = val_is_num(px) ? (int)val_num(px) : 0;
		int ipy = val_is_num(py) ? (int)val_num(py) : 0;
		if (ipx > 0 || ipy > 0) s = s.padding(ipy, ipx, ipy, ipx);
	}
	// Alignment
	Value align_h = rec_get(node, "align_h");
	Value align_v = rec_get(node, "align_v");
	if (val_is_str(align_h) || val_is_str(align_v)) {
		glaze::Position h_pos = glaze::Position.LEFT;
		glaze::Position v_pos = glaze::Position.TOP;
		if (val_is_str(align_h)) {
			String ah = val_str(align_h);
			if (ah == "center") { h_pos = glaze::Position.CENTER; }
			else if (ah == "right") { h_pos = glaze::Position.RIGHT; }
		}
		if (val_is_str(align_v)) {
			String av = val_str(align_v);
			if (av == "center") { v_pos = glaze::Position.CENTER; }
			else if (av == "bottom") { v_pos = glaze::Position.BOTTOM; }
		}
		s = s.align(h_pos, v_pos);
	}
	return s;
}

fn String render_node(Value node) @local {
	if (val_is_str(node)) return val_str(node);
	if (!val_is_rec(node)) return "";

	Value type_v = rec_get(node, "__type");
	if (!val_is_str(type_v)) {
		// plain string from style_render calls
		return "";
	}
	String t = val_str(type_v);

	if (t == "text") {
		String content = val_is_str(rec_get(node, "value")) ? val_str(rec_get(node, "value")) : "";
		glaze::Style s = glaze::style();
		Value fg = rec_get(node, "fg");
		if (val_is_str(fg)) s = s.with_fg(val_str(fg));
		Value bold = rec_get(node, "bold");
		if (val_is_bool(bold) && val_bool(bold)) s = s.bold(true);
		Value italic = rec_get(node, "italic");
		if (val_is_bool(italic) && val_bool(italic)) s = s.italic(true);
		Value w = rec_get(node, "width");
		if (val_is_num(w)) s = s.width((int)val_num(w));
		String rendered = s.render(content).copy(mem);
		// dim and reverse via SGR wrapping (glaze Style doesn't have these)
		Value dim = rec_get(node, "dim");
		if (val_is_bool(dim) && val_bool(dim)) rendered = string::tformat("\x1b[2m%s\x1b[0m", rendered);
		Value reverse = rec_get(node, "reverse");
		if (val_is_bool(reverse) && val_bool(reverse)) rendered = string::tformat("\x1b[7m%s\x1b[0m", rendered);
		return rendered;
	}

	if (t == "vstack") {
		Value children = rec_get(node, "children");
		if (!val_is_arr(children)) return "";
		int n = arr_len(children);
		int gap = val_is_num(rec_get(node, "gap")) ? (int)val_num(rec_get(node, "gap")) : 0;
		String[] parts = mem::talloc_array(String, (sz)(n + (n - 1) * gap));
		int out_idx = 0;
		for (int i = 0; i < n; i++) {
			if (i > 0 && gap > 0) {
				for (int g = 0; g < gap; g++) {
					parts[out_idx++] = "";
				}
			}
			parts[out_idx++] = render_node(arr_get(children, i));
		}
		if (out_idx == 0) return "";
		return glaze::join_vertical_arr(glaze::Position.LEFT, parts[:out_idx]).copy(mem);
	}

	if (t == "hstack") {
		Value children = rec_get(node, "children");
		if (!val_is_arr(children)) return "";
		int n = arr_len(children);
		if (n == 0) return "";
		int gap = val_is_num(rec_get(node, "gap")) ? (int)val_num(rec_get(node, "gap")) : 0;
		int total_w = val_is_num(rec_get(node, "width")) ? (int)val_num(rec_get(node, "width")) : 0;

		// Parse constraints: DS array of strings e.g. ["fill", "len:1", "min:4"].
		Value constraints_v = rec_get(node, "constraints");
		bool has_constraints = val_is_arr(constraints_v) && total_w > 0;

		String[] parts = mem::talloc_array(String, (sz)n);
		if (has_constraints) {
			xray::Constraint[] cs = mem::talloc_array(xray::Constraint, (sz)n);
			for (int i = 0; i < n; i++) {
				Value cv = arr_get(constraints_v, i);
				String s = val_is_str(cv) ? val_str(cv) : "fill";
				int col = -1;
				foreach (j, c : s) { if (c == ':') { col = (int)j; break; } }
				String kind = col >= 0 ? s[0:(sz)col] : s;
				int arg = 1;
				if (col >= 0) {
					String tail = s[(sz)(col + 1):(sz)(s.len - (sz)col - 1)];
					if (try v = tail.to_int()) arg = (int)v;
				}
				if (kind == "len") {
					cs[i] = xray::constraint_len(arg);
				} else if (kind == "min") {
					cs[i] = xray::constraint_min(arg);
				} else if (kind == "max") {
					cs[i] = xray::constraint_max(arg);
				} else {
					cs[i] = xray::constraint_fill(arg);
				}
			}
			xray::Rect[64] rects;
			xray::Rect area = xray::new_rect(0, 0, total_w, 1);
			int nc = xray::layout_h_gap(area, cs[:n], gap, rects[:n]);
			for (int i = 0; i < nc; i++) {
				String raw = render_node(arr_get(children, i));
				parts[i] = glaze::style().width(rects[i].w).render(raw).copy(mem);
			}
		} else {
			for (int i = 0; i < n; i++) {
				parts[i] = render_node(arr_get(children, i));
			}
		}
		return glaze::join_horizontal_arr(glaze::Position.TOP, parts[:n], gap).copy(mem);
	}

	if (t == "box") {
		Value child = rec_get(node, "child");
		String inner = val_is_nil(child) ? "" : render_node(child);
		glaze::Style s = node_style(node);
		return s.render(inner).copy(mem);
	}

	if (t == "divider") {
		int w = val_is_num(rec_get(node, "width")) ? (int)val_num(rec_get(node, "width")) : 40;
		String ch = val_is_str(rec_get(node, "char")) ? val_str(rec_get(node, "char")) : "─";
		DString ds = dstring::new_with_capacity(mem, (sz)(w * 4));
		defer ds.free();
		for (int i = 0; i < w; i++) ds.append_string(ch);
		String line = string::tformat("\x1b[2m%s\x1b[0m", ds.str_view());
		return line;
	}

	// fallback: unknown node type → empty string
	return "";
}

// ── DS model bridge ───────────────────────────────────────────────

Value g_model_rec;
Value g_state;

struct DsModel { bool _pad; }

fn milktea::Cmd DsModel.init(DsModel* self) @dynamic {
	Value init_fn = rec_get(g_model_rec, "init");
	if (!engine::engine_is_closure(init_fn)) {
		io::eprintfn("[debug] init field is not a closure");
		return null;
	}
	EvalResult r = engine::engine_call(init_fn, {});
	if (r.thrown) {
		io::eprintfn("[debug] init threw: %s", engine::engine_show(r.value));
	} else {
		g_state = r.value;
	}
	return milktea::tick(80);
}

fn milktea::Cmd DsModel.update(DsModel* self, milktea::Msg msg) @dynamic {
	Value update_fn = rec_get(g_model_rec, "update");

	if (msg.kind == milktea::MsgKind.KEY) {
		if (msg.key.code == milktea::KeyCode.CTRL_C) return milktea::quit();
		if (msg.key.rune == 'q') return milktea::quit();
	}

	Value msg_val;
	switch (msg.kind) {
		case milktea::MsgKind.KEY:
			char rune = msg.key.rune;
			int  code = (int)msg.key.code;
			Value key_rec = engine::engine_mk_record(
				{ "code", "rune", "ctrl" },
				{ num_val((double)code),
				  str_val(rune == 0 ? "" : string::tformat("%c", rune)),
				  bool_val(msg.key.ctrl) });
			msg_val = engine::engine_mk_tagged("Key", key_rec);
		case milktea::MsgKind.WINDOW_SIZE:
			Value size_rec = engine::engine_mk_record(
				{ "width", "height" },
				{ num_val((double)msg.window_size.width),
				  num_val((double)msg.window_size.height) });
			msg_val = engine::engine_mk_tagged("WindowSize", size_rec);
		case milktea::MsgKind.TICK:
			msg_val = engine::engine_mk_tagged("Tick", nil_val());
		default:
			msg_val = engine::engine_mk_tagged("None", nil_val());
	}

	EvalResult r = engine::engine_call(update_fn, { g_state, msg_val });
	if (!r.thrown) g_state = r.value;

	if (engine::engine_is_record(g_state)) {
		Value quit_v = rec_get(g_state, "quit");
		if (engine::engine_is_bool(quit_v) && val_bool(quit_v)) {
			return milktea::quit();
		}
	}
	if (msg.kind == milktea::MsgKind.TICK) return milktea::tick(80);
	return null;
}

fn milktea::View DsModel.view(DsModel* self) @dynamic {
	engine::engine_begin_render();
	Value view_fn = rec_get(g_model_rec, "view");
	EvalResult r  = engine::engine_call(view_fn, { g_state });
	if (r.thrown) {
		return milktea::new_view(string::tformat("view error: %s", engine::engine_show(r.value)));
	}
	// Accept either a string (legacy) or a node tree record
	String output;
	if (engine::engine_is_str(r.value)) {
		output = val_str(r.value);
	} else if (engine::engine_is_record(r.value)) {
		output = render_node(r.value);
	} else {
		return milktea::new_view(string::tformat("view: unexpected value: %s", engine::engine_show(r.value)));
	}
	return milktea::new_view(output);
}

// ── milktea bindings ──────────────────────────────────────────────

fn EvalResult ds_run_model(Value[] args) {
	if (args.len < 1 || !val_is_rec(args[0])) {
		return { .thrown = true, .value = str_val("run_model(model)") };
	}
	g_model_rec = args[0];
	g_state     = nil_val();
	DsModel m;
	if (catch err = milktea::@run_program(&m)) {
		return { .thrown = true, .value = str_val(string::tformat("milktea error: %s", err)) };
	}
	return { .value = nil_val() };
}

// Key code constants
fn EvalResult ds_key_enter(Value[] args)     { return { .value = num_val((double)(int)milktea::KeyCode.ENTER) }; }
fn EvalResult ds_key_backspace(Value[] args) { return { .value = num_val((double)(int)milktea::KeyCode.BACKSPACE) }; }
fn EvalResult ds_key_esc(Value[] args)       { return { .value = num_val((double)(int)milktea::KeyCode.ESC) }; }
fn EvalResult ds_key_up(Value[] args)        { return { .value = num_val((double)(int)milktea::KeyCode.UP) }; }
fn EvalResult ds_key_down(Value[] args)      { return { .value = num_val((double)(int)milktea::KeyCode.DOWN) }; }
fn EvalResult ds_key_left(Value[] args)      { return { .value = num_val((double)(int)milktea::KeyCode.LEFT) }; }
fn EvalResult ds_key_right(Value[] args)     { return { .value = num_val((double)(int)milktea::KeyCode.RIGHT) }; }
fn EvalResult ds_key_rune(Value[] args)      { return { .value = num_val((double)(int)milktea::KeyCode.RUNE) }; }
fn EvalResult ds_key_ctrl_c(Value[] args)    { return { .value = num_val((double)(int)milktea::KeyCode.CTRL_C) }; }
fn EvalResult ds_key_delete(Value[] args)    { return { .value = num_val((double)(int)milktea::KeyCode.DELETE) }; }

// ── Native node constructors ──────────────────────────────────────
// These are the "native" leaf/layout nodes that the C3 renderer knows about.

// Text({ value, bold, dim, fg, italic, width, reverse }) → node
fn EvalResult ds_text(Value[] args) {
	if (args.len < 1 || !val_is_rec(args[0])) return { .value = str_val("") };
	Value opts = args[0];
	Value node = engine::engine_mk_record(
		{ "__type", "value", "bold", "dim", "italic", "fg", "width", "reverse" },
		{ str_val("text"),
		  rec_get(opts, "value"),
		  rec_get(opts, "bold"),
		  rec_get(opts, "dim"),
		  rec_get(opts, "italic"),
		  rec_get(opts, "fg"),
		  rec_get(opts, "width"),
		  rec_get(opts, "reverse") });
	return { .value = node };
}

// StatusBar({ text }) → node
fn EvalResult ds_status_bar(Value[] args) {
	if (args.len < 1 || !val_is_rec(args[0])) return { .value = str_val("") };
	Value opts = args[0];
	Value text = rec_get(opts, "text");
	Value node = engine::engine_mk_record(
		{ "__type", "value", "dim" },
		{ str_val("text"), text, bool_val(true) });
	return { .value = node };
}

// TextInput({ prefix, value, focused }) → node
fn EvalResult ds_text_input(Value[] args) {
	if (args.len < 1 || !val_is_rec(args[0])) return { .value = str_val("") };
	Value opts = args[0];
	Value prefix  = val_is_str(rec_get(opts, "prefix"))  ? rec_get(opts, "prefix")  : str_val("> ");
	Value value   = val_is_str(rec_get(opts, "value"))   ? rec_get(opts, "value")   : str_val("");
	Value focused = val_is_bool(rec_get(opts, "focused")) ? rec_get(opts, "focused") : bool_val(false);
	bool is_focused = val_bool(focused);
	String row = string::tformat("%s%s", val_str(prefix), val_str(value));
	Value node = engine::engine_mk_record(
		{ "__type", "value", "reverse", "dim" },
		{ str_val("text"), str_val(row), bool_val(is_focused), bool_val(!is_focused) });
	return { .value = node };
}

// List({ items, cursor, render_item }) → node
// render_item is a DS closure: fn(item, selected) → string
fn EvalResult ds_list(Value[] args) {
	if (args.len < 1 || !val_is_rec(args[0])) return { .value = str_val("") };
	Value opts        = args[0];
	Value items       = rec_get(opts, "items");
	Value cursor_v    = rec_get(opts, "cursor");
	Value render_item = rec_get(opts, "render_item");
	if (!val_is_arr(items)) {
		Value empty = engine::engine_mk_record({ "__type", "value", "dim" }, { str_val("text"), str_val("  No items."), bool_val(true) });
		return { .value = empty };
	}
	int n = arr_len(items);
	int cursor = val_is_num(cursor_v) ? (int)val_num(cursor_v) : 0;
	if (n == 0) {
		Value empty = engine::engine_mk_record({ "__type", "value", "dim" }, { str_val("text"), str_val("  No items."), bool_val(true) });
		return { .value = empty };
	}
	// Build child node array: one text_node per item
	Value* child_arr = mem::new_array(Value, (sz)n);
	for (int i = 0; i < n; i++) {
		Value item = arr_get(items, i);
		bool selected = (i == cursor);
		String label = "";
		if (engine::engine_is_closure(render_item)) {
			EvalResult r = engine::engine_call(render_item, { item, bool_val(selected) });
			if (!r.thrown && engine::engine_is_str(r.value)) {
				label = val_str(r.value);
			}
		}
		String row_text = string::tformat("  %s", label);
		Value row_node = engine::engine_mk_record(
			{ "__type", "value", "reverse" },
			{ str_val("text"), str_val(row_text), bool_val(selected) });
		child_arr[i] = row_node;
	}
	Value children = engine::engine_mk_array(child_arr[:n]);
	Value node = engine::engine_mk_record(
		{ "__type", "gap", "children" },
		{ str_val("vstack"), num_val(0), children });
	return { .value = node };
}

// vstack(props, children) → node
// props can be a record {gap, ...} (from JSX) or a number (direct gap)
fn EvalResult ds_vstack(Value[] args) {
	Value props = args.len >= 1 ? args[0] : nil_val();
	Value children = args.len >= 2 ? args[1] : nil_val();
	Value gap;
	if (val_is_num(props)) {
		gap = props;
	} else if (val_is_rec(props)) {
		gap = rec_get(props, "gap");
		if (val_is_nil(gap)) { gap = num_val(0); }
	} else {
		gap = num_val(0);
	}
	Value node = engine::engine_mk_record(
		{ "__type", "gap", "children" },
		{ str_val("vstack"), gap, children });
	return { .value = node };
}

// hstack(props, children) → node
// props: { gap, width, constraints: ["fill", "len:N", ...] }
fn EvalResult ds_hstack(Value[] args) {
	Value props = args.len >= 1 ? args[0] : nil_val();
	Value children = args.len >= 2 ? args[1] : nil_val();
	Value gap, width, constraints;
	if (val_is_num(props)) {
		gap = props;
		width = nil_val();
		constraints = nil_val();
	} else if (val_is_rec(props)) {
		gap = rec_get(props, "gap");
		if (val_is_nil(gap)) { gap = num_val(0); }
		width = rec_get(props, "width");
		constraints = rec_get(props, "constraints");
	} else {
		gap = num_val(0);
		width = nil_val();
		constraints = nil_val();
	}
	Value node = engine::engine_mk_record(
		{ "__type", "gap", "width", "constraints", "children" },
		{ str_val("hstack"), gap, width, constraints, children });
	return { .value = node };
}

// Box(opts, child) → node
// opts: { border, border_fg, fg, bg, bold, padding_x, padding_y, pt, pr, pb, pl, width, height, align_h, align_v }
fn EvalResult ds_box(Value[] args) {
	Value opts  = args.len >= 1 && val_is_rec(args[0]) ? args[0] : nil_val();
	// args[1] is a DS array of children (from __element); take the first.
	Value child = nil_val();
	if (args.len >= 2) {
		Value kids_v = args[1];
		if (val_is_arr(kids_v) && arr_len(kids_v) > 0) {
			child = arr_get(kids_v, 0);
		} else {
			child = kids_v;
		}
	}
	bool has = val_is_rec(opts);
	Value node = engine::engine_mk_record(
		{ "__type", "child", "border", "border_fg", "fg", "bg", "bold",
		  "padding_x", "padding_y", "pt", "pr", "pb", "pl",
		  "width", "height", "align_h", "align_v" },
		{ str_val("box"), child,
		  has ? rec_get(opts, "border")     : nil_val(),
		  has ? rec_get(opts, "border_fg")  : nil_val(),
		  has ? rec_get(opts, "fg")         : nil_val(),
		  has ? rec_get(opts, "bg")         : nil_val(),
		  has ? rec_get(opts, "bold")       : nil_val(),
		  has ? rec_get(opts, "padding_x")  : nil_val(),
		  has ? rec_get(opts, "padding_y")  : nil_val(),
		  has ? rec_get(opts, "pt")         : nil_val(),
		  has ? rec_get(opts, "pr")         : nil_val(),
		  has ? rec_get(opts, "pb")         : nil_val(),
		  has ? rec_get(opts, "pl")         : nil_val(),
		  has ? rec_get(opts, "width")      : nil_val(),
		  has ? rec_get(opts, "height")     : nil_val(),
		  has ? rec_get(opts, "align_h")    : nil_val(),
		  has ? rec_get(opts, "align_v")    : nil_val() });
	return { .value = node };
}

// Divider(props) → node  (props: {width, char})
fn EvalResult ds_divider(Value[] args) {
	Value props = args.len >= 1 ? args[0] : nil_val();
	Value w, ch;
	if (val_is_rec(props)) {
		w  = rec_get(props, "width");
		ch = rec_get(props, "char");
	} else {
		w  = nil_val();
		ch = nil_val();
	}
	Value node = engine::engine_mk_record(
		{ "__type", "width", "char" },
		{ str_val("divider"), w, ch });
	return { .value = node };
}

// ── Math utilities ────────────────────────────────────────────────

fn EvalResult ds_math_floor(Value[] args) {
	if (args.len < 1 || !val_is_num(args[0])) return { .value = num_val(0) };
	return { .value = num_val((double)(long)val_num(args[0])) };
}
fn EvalResult ds_math_ceil(Value[] args) {
	if (args.len < 1 || !val_is_num(args[0])) return { .value = num_val(0) };
	double d = val_num(args[0]);
	long i = (long)d;
	return { .value = num_val((double)(d > (double)i ? i + 1 : i)) };
}
fn EvalResult ds_math_round(Value[] args) {
	if (args.len < 1 || !val_is_num(args[0])) return { .value = num_val(0) };
	double d = val_num(args[0]);
	long i = (long)(d + 0.5);
	return { .value = num_val((double)i) };
}
fn EvalResult ds_math_abs(Value[] args) {
	if (args.len < 1 || !val_is_num(args[0])) return { .value = num_val(0) };
	double d = val_num(args[0]);
	return { .value = num_val(d < 0 ? -d : d) };
}
fn EvalResult ds_math_max(Value[] args) {
	if (args.len < 2) return { .value = num_val(0) };
	double a = val_is_num(args[0]) ? val_num(args[0]) : 0;
	double b = val_is_num(args[1]) ? val_num(args[1]) : 0;
	return { .value = num_val(a > b ? a : b) };
}
fn EvalResult ds_math_min(Value[] args) {
	if (args.len < 2) return { .value = num_val(0) };
	double a = val_is_num(args[0]) ? val_num(args[0]) : 0;
	double b = val_is_num(args[1]) ? val_num(args[1]) : 0;
	return { .value = num_val(a < b ? a : b) };
}

// ── Progress bar ──────────────────────────────────────────────────

// progress_bar(opts) → string
// opts: { width, pct, fill, empty, fill_color, empty_color }
// fill_color / empty_color: hex strings or nil
fn EvalResult ds_progress_bar(Value[] args) {
	if (args.len < 1 || !val_is_rec(args[0])) return { .value = str_val("[          ]") };
	Value opts = args[0];
	int width    = val_is_num(rec_get(opts, "width"))  ? (int)val_num(rec_get(opts, "width"))  : 20;
	int pct      = val_is_num(rec_get(opts, "pct"))    ? (int)val_num(rec_get(opts, "pct"))    : 0;
	String fill  = val_is_str(rec_get(opts, "fill"))   ? val_str(rec_get(opts, "fill"))   : "█";
	String empty = val_is_str(rec_get(opts, "empty"))  ? val_str(rec_get(opts, "empty"))  : "░";
	String fill_hex  = val_is_str(rec_get(opts, "fill_color"))  ? val_str(rec_get(opts, "fill_color"))  : "";
	String empty_hex = val_is_str(rec_get(opts, "empty_color")) ? val_str(rec_get(opts, "empty_color")) : "";
	glaze::Color fc = fill_hex.len  > 0 ? glaze::color_hex(fill_hex)  : glaze::color_none();
	glaze::Color ec = empty_hex.len > 0 ? glaze::color_hex(empty_hex) : glaze::color_none();
	String bar = glaze::progress_bar(width, pct, fill, empty, fc, ec).copy(mem);
	return { .value = str_val(bar) };
}

// ── String utilities ──────────────────────────────────────────────

// str_repeat(s, n) → string
fn EvalResult ds_str_repeat(Value[] args) {
	if (args.len < 2) return { .value = str_val("") };
	String s = val_is_str(args[0]) ? val_str(args[0]) : "";
	int n    = val_is_num(args[1]) ? (int)val_num(args[1]) : 0;
	if (n <= 0 || s.len == 0) return { .value = str_val("") };
	DString d = dstring::new(mem, s);
	for (int i = 1; i < n; i++) d.append_string(s);
	return { .value = str_val(d.str_view()) };
}

// num_to_str(n) → string  (integer formatting)
fn EvalResult ds_num_to_str(Value[] args) {
	if (args.len < 1 || !val_is_num(args[0])) return { .value = str_val("0") };
	double d = val_num(args[0]);
	long   i = (long)d;
	if ((double)i == d) {
		return { .value = str_val(string::tformat("%d", (int)i).copy(mem)) };
	}
	return { .value = str_val(string::tformat("%g", d).copy(mem)) };
}

// str_pad_left(s, width, pad_char) → string
fn EvalResult ds_str_pad_left(Value[] args) {
	if (args.len < 2) return { .value = str_val("") };
	String s     = val_is_str(args[0]) ? val_str(args[0]) : "";
	int width    = val_is_num(args[1]) ? (int)val_num(args[1]) : 0;
	String pad_c = args.len >= 3 && val_is_str(args[2]) ? val_str(args[2]) : " ";
	int cur = glaze::string_width(s);
	if (cur >= width) return { .value = str_val(s) };
	DString d = dstring::new(mem, s);
	int deficit = width - cur;
	for (int i = 0; i < deficit; i++) d.append_string(pad_c);
	d.append_string(s);
	return { .value = str_val(d.str_view()) };
}

// str_pad_right(s, width, pad_char) → string
fn EvalResult ds_str_pad_right(Value[] args) {
	if (args.len < 2) return { .value = str_val("") };
	String s     = val_is_str(args[0]) ? val_str(args[0]) : "";
	int width    = val_is_num(args[1]) ? (int)val_num(args[1]) : 0;
	String pad_c = args.len >= 3 && val_is_str(args[2]) ? val_str(args[2]) : " ";
	int cur = glaze::string_width(s);
	if (cur >= width) return { .value = str_val(s) };
	DString d = dstring::new(mem, s);
	d.append_string(s);
	int deficit = width - cur;
	for (int i = 0; i < deficit; i++) d.append_string(pad_c);
	return { .value = str_val(d.str_view()) };
}

// ── glaze layout helpers (kept for backwards compat / ad-hoc use) ─

fn EvalResult ds_join_vertical(Value[] args) {
	if (args.len < 2) return { .value = str_val("") };
	String a = val_is_str(args[0]) ? val_str(args[0]) : "";
	String b = val_is_str(args[1]) ? val_str(args[1]) : "";
	return { .value = str_val(glaze::join_vertical(glaze::Position.LEFT, a, b).copy(mem)) };
}

fn EvalResult ds_join_horizontal(Value[] args) {
	if (args.len < 2) return { .value = str_val("") };
	String a   = val_is_str(args[0]) ? val_str(args[0]) : "";
	String b   = val_is_str(args[1]) ? val_str(args[1]) : "";
	int    gap = args.len >= 3 && val_is_num(args[2]) ? (int)val_num(args[2]) : 1;
	return { .value = str_val(glaze::join_horizontal(a, b, gap).copy(mem)) };
}

fn EvalResult ds_style_render(Value[] args) {
	if (args.len < 2) return { .value = str_val("") };
	Value opts    = args[0];
	String content = val_is_str(args[1]) ? val_str(args[1]) : "";

	glaze::Style s = glaze::style();
	bool is_dim = false;
	bool is_reverse = false;

	if (val_is_rec(opts)) {
		Value fg = rec_get(opts, "fg");
		if (val_is_str(fg)) s = s.with_fg(val_str(fg));
		Value bg = rec_get(opts, "bg");
		if (val_is_str(bg)) s = s.with_bg(val_str(bg));
		Value bold = rec_get(opts, "bold");
		if (val_is_bool(bold) && val_bool(bold)) s = s.bold(true);
		Value italic = rec_get(opts, "italic");
		if (val_is_bool(italic) && val_bool(italic)) s = s.italic(true);
		Value dim = rec_get(opts, "dim");
		is_dim = val_is_bool(dim) && val_bool(dim);
		Value reverse = rec_get(opts, "reverse");
		is_reverse = val_is_bool(reverse) && val_bool(reverse);
		Value border = rec_get(opts, "border");
		if (val_is_str(border)) {
			String bname = val_str(border);
			if (bname == "rounded") { s = s.border(glaze::rounded_border()); }
			else if (bname == "normal") { s = s.border(glaze::normal_border()); }
			Value border_fg = rec_get(opts, "border_fg");
			if (val_is_str(border_fg)) { s = s.border_fg(glaze::color_hex(val_str(border_fg))); }
		}
		// Full padding
		Value pt2 = rec_get(opts, "pt"); Value pr2 = rec_get(opts, "pr");
		Value pb2 = rec_get(opts, "pb"); Value pl2 = rec_get(opts, "pl");
		bool full_pad = val_is_num(pt2) || val_is_num(pr2) || val_is_num(pb2) || val_is_num(pl2);
		if (full_pad) {
			s = s.padding(
				val_is_num(pt2) ? (int)val_num(pt2) : 0,
				val_is_num(pr2) ? (int)val_num(pr2) : 0,
				val_is_num(pb2) ? (int)val_num(pb2) : 0,
				val_is_num(pl2) ? (int)val_num(pl2) : 0);
		} else {
			Value px = rec_get(opts, "padding_x");
			Value py = rec_get(opts, "padding_y");
			int ipx = val_is_num(px) ? (int)val_num(px) : 0;
			int ipy = val_is_num(py) ? (int)val_num(py) : 0;
			if (ipx > 0 || ipy > 0) s = s.padding(ipy, ipx, ipy, ipx);
		}
		Value w = rec_get(opts, "width");
		if (val_is_num(w)) s = s.width((int)val_num(w));
		Value h = rec_get(opts, "height");
		if (val_is_num(h)) s = s.height((int)val_num(h));
	}

	String rendered = s.render(content).copy(mem);
	if (is_dim)     rendered = string::tformat("\x1b[2m%s\x1b[0m", rendered);
	if (is_reverse) rendered = string::tformat("\x1b[7m%s\x1b[0m", rendered);
	return { .value = str_val(rendered) };
}

fn EvalResult ds_string_width(Value[] args) {
	if (args.len < 1 || !val_is_str(args[0])) return { .value = num_val(0) };
	return { .value = num_val((double)glaze::string_width(val_str(args[0]))) };
}

fn EvalResult ds_str_slice(Value[] args) {
	if (args.len < 3 || !val_is_str(args[0])) return { .value = str_val("") };
	String s  = val_str(args[0]);
	long start = (long)val_num(args[1]);
	long end   = (long)val_num(args[2]);
	if (start < 0) start = (long)s.len + start;
	if (end   < 0) end   = (long)s.len;
	if (start < 0)           start = 0;
	if (start > (long)s.len) start = (long)s.len;
	if (end   < start)       end   = start;
	if (end   > (long)s.len) end   = (long)s.len;
	return { .value = str_val(s[(sz)start:(sz)(end - start)].copy(mem)) };
}

fn EvalResult ds_str_concat(Value[] args) {
	if (args.len < 2) return { .value = str_val("") };
	String a = val_is_str(args[0]) ? val_str(args[0]) : "";
	String b = val_is_str(args[1]) ? val_str(args[1]) : "";
	DString d = dstring::new(mem, a);
	d.append_string(b);
	return { .value = str_val(d.str_view()) };
}

// ── Entry point ───────────────────────────────────────────────────

fn int main(String[] args) {
	engine::engine_init();

	engine::engine_register("run_model",    &ds_run_model);

	engine::engine_register("KEY_ENTER",     &ds_key_enter);
	engine::engine_register("KEY_BACKSPACE", &ds_key_backspace);
	engine::engine_register("KEY_ESC",       &ds_key_esc);
	engine::engine_register("KEY_UP",        &ds_key_up);
	engine::engine_register("KEY_DOWN",      &ds_key_down);
	engine::engine_register("KEY_LEFT",      &ds_key_left);
	engine::engine_register("KEY_RIGHT",     &ds_key_right);
	engine::engine_register("KEY_RUNE",      &ds_key_rune);
	engine::engine_register("KEY_CTRL_C",    &ds_key_ctrl_c);
	engine::engine_register("KEY_DELETE",    &ds_key_delete);

	// Native node constructors — registered both as _node variants and as
	// component names (VStack, HStack, Text, Box, Divider) so DS code can
	// use them directly without wrapper boilerplate.
	engine::engine_register("text_node",    &ds_text);
	engine::engine_register("vstack_node",  &ds_vstack);
	engine::engine_register("hstack_node",  &ds_hstack);
	engine::engine_register("box_node",     &ds_box);
	engine::engine_register("divider_node", &ds_divider);
	engine::engine_register("Text",         &ds_text);
	engine::engine_register("VStack",       &ds_vstack);
	engine::engine_register("HStack",       &ds_hstack);
	engine::engine_register("Box",          &ds_box);
	engine::engine_register("Divider",      &ds_divider);
	engine::engine_register("StatusBar",    &ds_status_bar);
	engine::engine_register("TextInput",    &ds_text_input);
	engine::engine_register("List",         &ds_list);

	// Progress bar
	engine::engine_register("progress_bar",    &ds_progress_bar);

	// String utilities
	engine::engine_register("str_repeat",      &ds_str_repeat);
	engine::engine_register("num_to_str",      &ds_num_to_str);
	engine::engine_register("str_pad_left",    &ds_str_pad_left);
	engine::engine_register("str_pad_right",   &ds_str_pad_right);

	// Math utilities
	engine::engine_register("floor",           &ds_math_floor);
	engine::engine_register("ceil",            &ds_math_ceil);
	engine::engine_register("round",           &ds_math_round);
	engine::engine_register("abs",             &ds_math_abs);
	engine::engine_register("max",             &ds_math_max);
	engine::engine_register("min",             &ds_math_min);

	// Kept for ad-hoc use
	engine::engine_register("join_vertical",   &ds_join_vertical);
	engine::engine_register("join_horizontal", &ds_join_horizontal);
	engine::engine_register("style_render",    &ds_style_render);
	engine::engine_register("string_width",    &ds_string_width);
	engine::engine_register("str_slice",       &ds_str_slice);
	engine::engine_register("str_concat",      &ds_str_concat);

	String script_path = args.len >= 2 ? args[1] : "example/todo/todo.ds";
	char[]? contents = file::load_temp(script_path);
	if (catch err = contents) {
		io::printfn("error: could not read %s", script_path);
		return 1;
	}

	EvalResult r = engine::engine_eval_result((String)contents);
	if (r.thrown) {
		io::printfn("error: %s", engine::engine_show(r.value));
		return 1;
	}
	return 0;
}
