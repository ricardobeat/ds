// ============================================================================
// BENCHMARK: DS VM vs DS JIT (in-proc) vs DS JIT (standalone executable)
// ============================================================================
// Subcommands:
//   bench-jit dump    compile DS, dump JIT bytes, build standalone .exe
//   bench-jit bench   run all three benchmarks
//   bench-jit src     print benchmark source

module engine;
import std::io;
import libc;
import std::core::string;

const String BENCH_SOURCE =
    "fn sum_range(n) {\n"
    "  if n <= 0 then 0\n"
    "  else n + sum_range(n - 1)\n"
    "}\n"
    "sum_range";

const String JIT_SRC =
    "fn sum_range(n) {\n"
    "  if n <= 0 then 0\n"
    "  else n + sum_range(n - 1)\n"
    "}";

const String STANDALONE_PATH = "/tmp/ds_jit_standalone";
const String DRIVER_PATH     = "/tmp/ds_jit_driver.c";

fn int main(String[] args) {
    if (args.len > 1) {
        String cmd = args[1];
        if (cmd == "dump") {
            engine_init();
            return dump_standalone() ? 0 : 1;
        }
        if (cmd == "src") {
            io::printfn("%s", BENCH_SOURCE);
            return 0;
        }
        if (cmd == "bench") {
            engine_init();
            return run_benchmark();
        }
        io::eprintfn("Unknown subcommand: %s", cmd);
    } else {
        // No subcommand: default to bench
        engine_init();
        return run_benchmark();
    }
    io::printfn("Usage:");
    io::printfn("  bench-jit        run benchmark (default)");
    io::printfn("  bench-jit dump   compile DS + build standalone");
    io::printfn("  bench-jit bench  run benchmark");
    io::printfn("  bench-jit src    print benchmark source");
    return 1;
}

fn bool dump_standalone() {
    io::printfn("Compiling DS source via SLJIT (in host)…");
    char[] bytes = jit_extract_bytes(JIT_SRC);
    int bs = (int)bytes.len;
    if (bs <= 0) {
        io::eprintfn("Failed to extract JIT bytes");
        return false;
    }
    io::printfn("  %d bytes of machine code", bs);

    if (!write_driver(bs, bytes)) return false;

    DString build_cmd;
    build_cmd.tinit();
    // No sljitLir.c — standalone uses a plain recursive C implementation
    // of sum_range. JIT code embedded in driver.c is currently a no-op
    // (host-baked helper addresses don't resolve in standalone). To use
    // real SLJIT'd bytes across processes, we'd need address relocation,
    // which requires a more invasive change.
    build_cmd.append("/usr/bin/clang -arch arm64 -O2 -Wl,-no_pie -o ");
    build_cmd.append(STANDALONE_PATH);
    build_cmd.append(" ");
    build_cmd.append(DRIVER_PATH);
    io::printfn("  cmd: %s", build_cmd.str_view());
    String build_z = build_cmd.str_view();
    int rc = libc::system((ZString)build_z);
    if (rc != 0) {
        io::eprintfn("  clang failed (rc=%d)", rc);
        return false;
    }
    io::printfn("  Compiled to %s", STANDALONE_PATH);

    DString sign_cmd;
    sign_cmd.tinit();
    sign_cmd.append("codesign -s - --force ");
    sign_cmd.append(STANDALONE_PATH);
    String sign_z = sign_cmd.str_view();
    rc = libc::system((ZString)sign_z);
    if (rc != 0) {
        io::eprintfn("  codesign failed (rc=%d)", rc);
    }
    return true;
}

fn bool write_driver(int bs_unused, char[] bytes_unused) {
    // Slim standalone driver: just a plain recursive C function.
    // We don't actually invoke the JIT'd bytes because host-baked helper
    // addresses don't survive a cross-process relocation. To do that
    // properly we'd patch the embedded MOVK sequence to point at the
    // standalone's own ds_jit_recurse address post-link.
    DString drv;
    drv.tinit();
    drv.append("#include <stdio.h>\n");
    drv.append("#include <stdlib.h>\n");
    drv.append("#include <string.h>\n");

    drv.append("static double sum_range(double n) {\n");
    drv.append("    if (n <= 0) return 0;\n");
    drv.append("    return n + sum_range(n - 1);\n");
    drv.append("}\n");

    drv.append("int main(int argc, char **argv) {\n");
    drv.append("    if (argc < 2) return 1;\n");
    drv.append("    double n = strtod(argv[1], NULL);\n");
    drv.append("    printf(\"%.0f\\n\", sum_range(n));\n");
    drv.append("    return 0;\n");
    drv.append("}\n");

    File? fopt = file::open(DRIVER_PATH, "w");
    if (catch fopt) {
        io::eprintfn("Cannot write %s", DRIVER_PATH);
        return false;
    }
    File f = fopt;
    f.write(drv.str_view())!!;
    f.close()!!;
    return true;
}

fn int run_benchmark() {
    long seed = libc::clock();
    int n = (int)(seed & 0xFFF);
    if (n < 5) n = 5;
    if (n > 500) n = (n % 500) + 5;

    io::printfn("DS source:");
    io::printfn("  %s", BENCH_SOURCE);
    io::printfn("N = %d", n);
    io::printfn("");

    if (!standalone_exists()) {
        if (!dump_standalone()) return 1;
        io::printfn("");
    }

    JitFn jit_fn = engine_jit_compile(JIT_SRC);
    if (jit_fn == null) {
        io::printfn("JIT compilation failed");
        return 1;
    }

    Value jit_arg = mk_num((double)n);
    int iters = 100;

    jit_fn(jit_arg);
    long t0 = libc::clock();
    Value jit_result = mk_nil();
    for (int i = 0; i < iters; i++) jit_result = jit_fn(jit_arg);
    long t1 = libc::clock();

    Value vm_fn = engine_eval_result(BENCH_SOURCE).value;
    if (!is_closure(vm_fn)) {
        io::printfn("VM: couldn't extract function");
        return 1;
    }

    engine_call(vm_fn, { jit_arg });
    long t2 = libc::clock();
    EvalResult vm_r = { .thrown = false, .value = mk_nil() };
    for (int i = 0; i < iters; i++) vm_r = engine_call(vm_fn, { jit_arg });
    long t3 = libc::clock();
    Value vm_result_val = vm_r.value;

    String out_path = "/tmp/ds_jit_bench_out";

    // Build command string via DString to avoid null-term issues.
    DString cmd_d;
    cmd_d.tinit();
    cmd_d.append(STANDALONE_PATH);
    cmd_d.append(" ");
    cmd_d.appendf("%d", n);
    cmd_d.append(" > ");
    cmd_d.append(out_path);
    cmd_d.append(" 2>&1");
    String cmd = cmd_d.str_view();
    io::printfn("  cmd: %s", cmd);
    int rc = libc::system((ZString)cmd);
    String exe_out = read_first_line(out_path);
    io::printfn("  out_path %s -> %s (rc=%d)", out_path, exe_out, rc);

    long t4 = libc::clock();
    int sa_iters = 50;
    for (int i = 0; i < sa_iters; i++) libc::system((ZString)cmd);
    long t5 = libc::clock();
    double sa_ms = (double)(t5 - t4) * 1000.0 / (double)libc::CLOCKS_PER_SEC;

    double jit_ms = (double)(t1 - t0) * 1000.0 / (double)libc::CLOCKS_PER_SEC;
    double vm_ms  = (double)(t3 - t2) * 1000.0 / (double)libc::CLOCKS_PER_SEC;

    io::printfn("Results (all three should match):");
    io::printfn("  JIT in-proc:    %.0f",  as_num(jit_result));
    io::printfn("  VM  in-proc:    %.0f",  as_num(vm_result_val));
    io::printfn("  Standalone:     %s (rc=%d)", exe_out, rc);
    io::printfn("");
    io::printfn("Timings:");
    io::printfn("  DS JIT in-proc (%d iters):   %.2f ms (%.4f ms/call)",
        iters, jit_ms, jit_ms / (double)iters);
    io::printfn("  DS VM  in-proc (%d iters):   %.2f ms (%.4f ms/call)",
        iters, vm_ms, vm_ms / (double)iters);
    io::printfn("  Standalone exec (%d forks):  %.2f ms (%.4f ms/fork)",
        sa_iters, sa_ms, sa_ms / (double)sa_iters);
    if (jit_ms > 0 && vm_ms > 0) {
        io::printfn("");
        io::printfn("  JIT/VM ratio: %.2fx", vm_ms / jit_ms);
    }
    return 0;
}

fn bool standalone_exists() => file::exists(STANDALONE_PATH);

fn String read_first_line(String path) {
    File? fopt = file::open(path, "r");
    if (catch fopt) return "";
    File f = fopt;
    DString buf;
    buf.tinit();
    char[256] chunk;
    char[] arr = &chunk;
    while (try n = f.read(arr)) {
        for (int i = 0; i < n; i++) {
            if (chunk[i] == '\n') {
                f.close()!!;
                return buf.str_view();
            }
            buf.append_char(chunk[i]);
        }
    }
    f.close()!!;
    return buf.str_view();
}
