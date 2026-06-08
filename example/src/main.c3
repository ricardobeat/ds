// Example: embedding the engine in a host program.
//
// This program demonstrates:
//   1. Initializing the engine
//   2. Registering a host function (fetch_url) that scripts can call
//   3. Evaluating scripts and reading results
//   4. Marshalling values between host and script
//
// Build: c3c build host-example
// Run:   ./build/host-example

module host_example;
import std::io;
import engine;

// ── A host function that scripts can call by name ────────────────
// Host functions receive Value[] args and return EvalResult.
// Use engine::engine_is_* / engine::engine_as_* to read args.

fn EvalResult host_add_one(Value[] args) {
	if (!engine::engine_is_num(args[0])) {
		return { .thrown = true, .value = engine::engine_mk_str("add_one expects a number") };
	}
	double n = engine::engine_as_num(args[0]);
	return { .value = engine::engine_mk_num(n + 1.0) };
}

fn EvalResult host_greet(Value[] args) {
	if (!engine::engine_is_str(args[0])) {
		return { .thrown = true, .value = engine::engine_mk_str("greet expects a string") };
	}
	String name = engine::engine_as_str(args[0]);
	return { .value = engine::engine_mk_str(string::tformat("Hello, %s!", name)) };
}

fn int main(String[] args) {
	io::printn("=== Engine Embedding Example ===");
	io::printn("");

	// 1. Initialize the engine
	engine::engine_init();

	// 2. Register host functions
	engine::engine_register("add_one", &host_add_one);
	engine::engine_register("greet", &host_greet);
	io::printn("[host] Registered host functions: add_one, greet");

	// 3. Evaluate simple expressions
	io::printn("--- Simple expressions ---");

	Value r1 = engine::engine_eval("1 + 2 * 3");
	io::printfn("  1 + 2 * 3 = %d", (int)engine::engine_as_num(r1));

	Value r2 = engine::engine_eval("\"hello\" + \" \" + \"world\"");
	io::printfn("  string concat = %s", engine::engine_as_str(r2));

	// 4. Evaluate a script that calls host functions
	io::printn("");
	io::printn("--- Calling host functions ---");

	Value r3 = engine::engine_eval("add_one(41)");
	io::printfn("  add_one(41) = %d", (int)engine::engine_as_num(r3));

	Value r4 = engine::engine_eval("greet(\"World\")");
	io::printfn("  greet(\"World\") = %s", engine::engine_as_str(r4));

	// 5. Evaluate a script with let bindings and host function
	io::printn("");
	io::printn("--- Script with logic ---");

	String script = `let double = fn(x) { x * 2 };
let result = add_one(double(10));
result`;
	Value r5 = engine::engine_eval(script);
	io::printfn("  add_one(double(10)) = %d", (int)engine::engine_as_num(r5));

	// 6. Evaluate a script that uses records
	io::printn("");
	io::printn("--- Records ---");

	String script2 = `let person = { name: "Alice", age: 30 };
greet(person.name)`;
	Value r6 = engine::engine_eval(script2);
	io::printfn("  greet(person.name) = %s", engine::engine_as_str(r6));

	// 7. Error handling
	io::printn("");
	io::printn("--- Error handling ---");

	EvalResult r7 = engine::engine_eval_result("add_one(\"not a number\")");
	if (r7.thrown) {
		io::printfn("  caught error: %s", engine::engine_show(r7.value));
	}

	// 8. Type checking results
	io::printn("");
	io::printn("--- Type checking ---");

	Value r8 = engine::engine_eval("42");
	io::printfn("  is_num(42) = %s", engine::engine_is_num(r8) ? "true" : "false");

	Value r9 = engine::engine_eval("\"hello\"");
	io::printfn("  is_str(\"hello\") = %s", engine::engine_is_str(r9) ? "true" : "false");

	Value r10 = engine::engine_eval("true");
	io::printfn("  is_bool(true) = %s", engine::engine_is_bool(r10) ? "true" : "false");

	Value r11 = engine::engine_eval("nil");
	io::printfn("  is_nil(nil) = %s", engine::engine_is_nil(r11) ? "true" : "false");

	io::printn("");
	io::printn("=== Done ===");
	return 0;
}
