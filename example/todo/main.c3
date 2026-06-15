// Todo app: milktea TUI with embedded DS scripting.
//
// DS scripts can call:
//   add(text)       — add a todo item
//   toggle(index)   — toggle done state
//   remove(index)   — remove an item
//   list()          — returns array of { text, done } records
//   clear_done()    — remove all completed items
//
// Build: c3c build todo
// Run:   ./build/todo

module todo_app;

import std::io;
import std::core::dstring;
import std::core::mem;
import milktea;
import engine;

// ── Todo state ────────────────────────────────────────────────────

const int MAX_TODOS = 64;

struct Todo {
	String text;
	bool done;
}

Todo[MAX_TODOS] g_todos;
int g_count = 0;

fn void todo_add(String text) {
	if (g_count >= MAX_TODOS) return;
	// Copy text into heap so it survives the engine pool
	DString d = dstring::new(mem, text);
	g_todos[g_count] = { .text = d.str_view(), .done = false };
	g_count++;
}

fn void todo_toggle(int i) {
	if (i < 0 || i >= g_count) return;
	g_todos[i].done = !g_todos[i].done;
}

fn void todo_remove(int i) {
	if (i < 0 || i >= g_count) return;
	for (int j = i; j < g_count - 1; j++) {
		g_todos[j] = g_todos[j + 1];
	}
	g_count--;
}

fn void todo_clear_done() {
	int w = 0;
	for (int r = 0; r < g_count; r++) {
		if (!g_todos[r].done) {
			g_todos[w++] = g_todos[r];
		}
	}
	g_count = w;
}

// ── DS host functions ─────────────────────────────────────────────

fn EvalResult ds_add(Value[] args) {
	if (args.len < 1 || !engine::engine_is_str(args[0])) {
		return { .thrown = true, .value = engine::engine_mk_str("add(text: string)") };
	}
	todo_add(engine::engine_as_str(args[0]));
	return { .value = engine::engine_mk_num((double)g_count) };
}

fn EvalResult ds_toggle(Value[] args) {
	if (args.len < 1 || !engine::engine_is_num(args[0])) {
		return { .thrown = true, .value = engine::engine_mk_str("toggle(index: number)") };
	}
	todo_toggle((int)engine::engine_as_num(args[0]));
	return { .value = engine::engine_mk_nil() };
}

fn EvalResult ds_remove(Value[] args) {
	if (args.len < 1 || !engine::engine_is_num(args[0])) {
		return { .thrown = true, .value = engine::engine_mk_str("remove(index: number)") };
	}
	todo_remove((int)engine::engine_as_num(args[0]));
	return { .value = engine::engine_mk_nil() };
}

fn EvalResult ds_list(Value[] args) {
	// Return an array of records: [{ text, done }, ...]
	// Build the DS source on the fly from the current state
	DString src = dstring::temp();
	src.append_string("[");
	for (int i = 0; i < g_count; i++) {
		if (i > 0) src.append_string(", ");
		src.append_string("{ text: \"");
		src.append_string(g_todos[i].text);
		src.append_string("\", done: ");
		src.append_string(g_todos[i].done ? "true" : "false");
		src.append_string(" }");
	}
	src.append_string("]");
	Value result = engine::engine_eval(src.str_view());
	return { .value = result };
}

fn EvalResult ds_clear_done(Value[] args) {
	todo_clear_done();
	return { .value = engine::engine_mk_nil() };
}

// ── TUI Model ─────────────────────────────────────────────────────

// App modes
enum Mode : char { LIST, SCRIPT, RESULT }

struct App {
	Mode mode;
	int cursor;        // selected todo index
	int width;
	int height;
	// Script editor state
	DString script_buf;
	String last_result;
	bool last_error;
	// Status line message
	String status;
}

const String BOLD   = "\x1b[1m";
const String DIM    = "\x1b[2m";
const String GREEN  = "\x1b[32m";
const String YELLOW = "\x1b[33m";
const String CYAN   = "\x1b[36m";
const String RED    = "\x1b[31m";
const String RESET  = "\x1b[0m";
const String INVERT = "\x1b[7m";

fn Cmd App.init(App* self) @dynamic {
	self.script_buf = dstring::new(mem);
	self.last_result = "";
	self.status = "q:quit  n:new  space:toggle  d:delete  /:script";
	return null;
}

fn View App.view(App* self) @dynamic {
	DString out = dstring::temp();

	// Header
	out.append_string(BOLD);
	out.append_string(CYAN);
	out.append_string("  ✓ Todo\n");
	out.append_string(RESET);
	out.append_string("  ");
	for (int i = 0; i < self.width - 4; i++) out.append_string("─");
	out.append_char('\n');

	if (self.mode == Mode.SCRIPT || self.mode == Mode.RESULT) {
		// Script pane
		out.append_string("\n");
		out.append_string(BOLD);
		out.append_string("  DS Script  ");
		out.append_string(DIM);
		out.append_string("(ESC to go back, Enter to run)\n");
		out.append_string(RESET);
		out.append_string("  > ");
		out.append_string(self.script_buf.str_view());
		out.append_string("\x1b[K\n");

		if (self.last_result.len > 0) {
			out.append_string("\n");
			out.append_string(self.last_error ? RED : GREEN);
			out.append_string("  ");
			out.append_string(self.last_error ? "Error: " : "→ ");
			out.append_string(self.last_result);
			out.append_string(RESET);
			out.append_char('\n');
		}

		out.append_string("\n");
		out.append_string(DIM);
		out.append_string("  Available: add(text)  toggle(i)  remove(i)  list()  clear_done()\n");
		out.append_string(RESET);
	} else {
		// Todo list
		if (g_count == 0) {
			out.append_string("\n");
			out.append_string(DIM);
			out.append_string("  No todos yet. Press n to add one.\n");
			out.append_string(RESET);
		} else {
			out.append_char('\n');
			for (int i = 0; i < g_count; i++) {
				bool sel = (i == self.cursor);
				if (sel) {
					out.append_string(INVERT);
					out.append_string("  ");
				} else {
					out.append_string("  ");
				}
				if (g_todos[i].done) {
					out.append_string(GREEN);
					out.append_string("✓ ");
					out.append_string(DIM);
				} else {
					out.append_string(DIM);
					out.append_string("○ ");
					out.append_string(RESET);
				}
				out.append_string(g_todos[i].text);
				if (sel) out.append_string(RESET);
				out.append_char('\n');
			}
		}
	}

	// Status bar
	out.append_char('\n');
	out.append_string(DIM);
	out.append_string("  ");
	out.append_string(self.status);
	out.append_string(RESET);
	out.append_char('\n');

	return milktea::new_view(out.str_view());
}

fn Cmd App.update(App* self, Msg msg) @dynamic {
	if (msg.kind == MsgKind.WINDOW_SIZE) {
		self.width  = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}
	if (msg.kind != MsgKind.KEY) return null;

	KeyMsg k = msg.key;

	switch (self.mode) {
		case LIST:
			switch (k.code) {
				case CTRL_C:
				case ESC:
					return milktea::quit();
				case RUNE:
					switch (k.rune) {
						case 'q':
							return milktea::quit();
						case 'n':
							// Quick-add a numbered todo via the script pane
							self.script_buf.clear();
							self.script_buf.append_string("add(\"New task\")");
							self.last_result = "";
							self.mode = Mode.SCRIPT;
							self.status = "Enter to run · ESC to cancel";
						case ' ':
							todo_toggle(self.cursor);
						case 'd':
							todo_remove(self.cursor);
							if (self.cursor >= g_count && self.cursor > 0) self.cursor--;
						case '/':
							self.script_buf.clear();
							self.last_result = "";
							self.mode = Mode.SCRIPT;
							self.status = "Enter to run · ESC to cancel";
					}
				case UP:
					if (self.cursor > 0) self.cursor--;
				case DOWN:
					if (self.cursor < g_count - 1) self.cursor++;
				default: break;
			}
		case SCRIPT:
		case RESULT:
			switch (k.code) {
				case ESC:
					self.mode = Mode.LIST;
					self.status = "q:quit  n:new  space:toggle  d:delete  /:script";
				case ENTER:
					self.run_script();
					self.mode = Mode.RESULT;
				case BACKSPACE:
					if (self.script_buf.len() > 0) {
						self.script_buf.chop(self.script_buf.len() - 1);
					}
				case RUNE:
					self.script_buf.append_char(k.rune);
				default: break;
			}
	}
	return null;
}

fn void App.run_script(App* self) {
	String src = self.script_buf.str_view();
	if (src.len == 0) return;

	EvalResult r = engine::engine_eval_result(src);
	if (r.thrown) {
		self.last_error  = true;
		self.last_result = engine::engine_show(r.value).copy(mem);
	} else {
		self.last_error  = false;
		self.last_result = engine::engine_show(r.value).copy(mem);
	}
	// Clamp cursor in case list changed
	if (self.cursor >= g_count && g_count > 0) self.cursor = g_count - 1;
	if (g_count == 0) self.cursor = 0;
}

// ── Entry point ───────────────────────────────────────────────────

fn int main(String[] args) {
	engine::engine_init();
	engine::engine_register("add",        &ds_add);
	engine::engine_register("toggle",     &ds_toggle);
	engine::engine_register("remove",     &ds_remove);
	engine::engine_register("list",       &ds_list);
	engine::engine_register("clear_done", &ds_clear_done);

	// Seed with a couple of example todos
	todo_add("Buy milk");
	todo_add("Write more DS code");
	todo_add("Ship it");

	App app;
	return milktea::@run(&app);
}
