module engine;
import std::io;

alias AddFn = fn iptr(iptr a, iptr b);

fn void main() {
    JitCompiler c = jit_create_compiler(null);
    if (!c) {
        io::printfn("FAIL: create_compiler");
        return;
    }

    int s0 = jit_s(0);
    int s1 = jit_s(1);
    int arg_types = jit_args2(JIT_ARG_W, JIT_ARG_W, JIT_ARG_W);

    jit_emit_enter(c, 0, arg_types, 1, 2, 0);
    jit_emit_op2(c, JIT_ADD, JIT_R0, 0, s0, 0, s1, 0);
    jit_emit_return(c, JIT_MOV, JIT_R0, 0);

    void* code = jit_generate_code(c, 0, null);
    jit_free_compiler(c);

    if (!code) {
        io::printfn("FAIL: code generation");
        return;
    }

    AddFn add = (AddFn)code;
    io::printfn("4 + 7 = %d", add(4, 7));
    io::printfn("12 + 34 = %d", add(12, 34));
    io::printfn("-5 + 8 = %d", add(-5, 8));

    jit_free_code(code, null);
}
