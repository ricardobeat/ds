// CLI entry point for the engine executable.
// Separated from the library code so embedding targets don't get a
// duplicate main().

module engine;
import std::io;

fn void register_cli_modules() {
    // Register the signals module so standalone scripts can use `from signals import`.
    // milktea and keys require a real host and are intentionally omitted here.
    register_module("signals", engine_mk_record(
        { "get", "set", "signal", "derived", "effect" },
        { mk_prim("signal_get"), mk_prim("signal_set"), mk_prim("signal"),
          mk_prim("derived"), mk_prim("effect") }
    ));
}

fn int main(String[] args) {
    intern_init();
    builtin_env = make_builtin_env();
    register_cli_modules();
    if (args.len < 2) {
        io::printn("usage:");
        io::printn("  engine run <file.ds>     evaluate a script and print the result");
        io::printn("  engine fmt <file.ds>     print the source re-formatted in canonical style");
        io::printn("  engine vm <file.ds>      evaluate via bytecode VM");
        return 0;
    }
    if (args[1] == "fmt") {
        if (args.len < 3) {
            io::printn("usage: engine fmt <file.ds>");
            return 1;
        }
        char[]? contents = file::load_temp(args[2]);
        if (catch err = contents) {
            io::printfn("error: could not read %s", args[2]);
            return 1;
        }
        FormatResult fr = format_source((String)contents);
        if (fr.error) {
            io::printfn("%s", fr.message);
            return 1;
        }
        io::print(fr.output);
        return 0;
    }
    if (args[1] == "run") {
        if (args.len < 3) {
            io::printn("usage: engine run <file.ds>");
            return 1;
        }
        char[]? contents = file::load_temp(args[2]);
        if (catch err = contents) {
            io::printfn("error: could not read %s", args[2]);
            return 1;
        }
        run_source((String)contents);
        return 0;
    }
    if (args[1] == "vm") {
        if (args.len < 3) {
            io::printn("usage: engine vm <file.ds>");
            return 1;
        }
        char[]? contents = file::load_temp(args[2]);
        if (catch err = contents) {
            io::printfn("error: could not read %s", args[2]);
            return 1;
        }
        run_source_vm((String)contents);
        return 0;
    }
    // Default: treat args[1] as a script to run (backwards-compatible).
    char[]? contents = file::load_temp(args[1]);
    if (catch err = contents) {
        io::printfn("error: could not read %s", args[1]);
        return 1;
    }
    run_source((String)contents);
    return 0;
}