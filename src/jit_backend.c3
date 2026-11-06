// ============================================================================
// DS JIT BACKEND — Compile DS kernel AST to native code via SLJIT
// ============================================================================
// Supports a numeric subset: LIT, VAR, IF, CALL(PRIM, ...), CALL(VAR, ...)
// for single-parameter recursive functions. Values are kept as unboxed
// doubles in float registers; boxed only at function boundaries.

module engine;
import std::io;

alias JitFn = fn Value(Value arg);

const int SLOT_CONV  = 0;
const int SLOT_BASE  = 8;
const int MAX_DEPTH  = 16;
const int LOCAL_SIZE = SLOT_BASE + MAX_DEPTH * 8;

struct JitState {
    JitCompiler c;
    int param_fs;
    uint param_id;
    uint fn_id;
    int depth;
    int mem_sp;
}

fn int jit_tmp_slot(JitState* st) {
    return SLOT_BASE + st.depth * 8;
}

// ============================================================================
// Public API
// ============================================================================

fn JitFn engine_jit_compile(String source) {
    @pool() {
        ParseResult pr = parse_source(source);
        if (pr.error) {
            io::eprintfn("JIT: parse error: %s", pr.message);
            return null;
        }

        AstNode* kernel = desugar(pr.root, null);

        // Find the LETREC inside (DS fn definitions desugar to LETREC)
        AstNode* letrec = jit_find_letrec(kernel);
        if (letrec == null) {
            io::eprintfn("JIT: no LETREC found (need a top-level fn definition)");
            return null;
        }

        AstNode* lambda = letrec.children[0];
        if (lambda == null || lambda.type != LAMBDA) {
            io::eprintfn("JIT: expected LAMBDA in LETREC binding");
            return null;
        }

        if (lambda.names.len != 1) {
            io::eprintfn("JIT: expected 1-param lambda, got %d", lambda.names.len);
            return null;
        }

        AstNode* body = lambda.children[0];
        if (body == null) {
            io::eprintfn("JIT: lambda has no body");
            return null;
        }

        JitState st;
        st.c = jit_create_compiler(null);
        if (!st.c) {
            io::eprintfn("JIT: sljit_create_compiler failed");
            return null;
        }
        st.param_fs  = jit_fs(0);
        st.param_id  = lambda.name_ids[0];
        st.fn_id     = letrec.name_id;
        st.depth     = 0;
        st.mem_sp    = jit_mem1(jit_sp());

        int scratches = 3 | jit_enter_float(3);
        int saveds    = 2 | jit_enter_float(2);
        jit_emit_enter(st.c, 0, jit_args1(JIT_ARG_W, JIT_ARG_W),
                       scratches, saveds, LOCAL_SIZE);

        jit_emit_op1(st.c, JIT_MOV, st.mem_sp, SLOT_CONV, JIT_R0, 0);
        jit_emit_fop1(st.c, JIT_MOV_F64, st.param_fs, 0, st.mem_sp, SLOT_CONV);

        jit_compile_expr(&st, body);

        jit_emit_fop1(st.c, JIT_MOV_F64, st.mem_sp, SLOT_CONV, JIT_FR0, 0);
        jit_emit_op1(st.c, JIT_MOV, JIT_R0, 0, st.mem_sp, SLOT_CONV);

        jit_emit_return(st.c, JIT_MOV, JIT_R0, 0);

        int err = jit_get_compiler_error(st.c);
        if (err != JIT_SUCCESS) {
            io::eprintfn("JIT: compiler error %d", err);
            jit_free_compiler(st.c);
            return null;
        }

        void* code = jit_generate_code(st.c, 0, null);

        if (!code) {
            io::eprintfn("JIT: jit_generate_code returned null");
            jit_free_compiler(st.c);
            return null;
        }

        uptr size = (uptr)jit_get_generated_code_size(st.c);
        io::eprintfn("JIT: compiled %d bytes", (int)size);

        jit_free_compiler(st.c);

        ds_jit_set_fn((ulong)(uptr)code);

        return (JitFn)code;
    };
}

// ============================================================================
// Expression compiler — result always in FR0
// ============================================================================

fn void jit_compile_expr(JitState* st, AstNode* node) {
    switch (node.type) {
        case LIT:
            jit_compile_lit(st, node);
        case VAR:
            jit_compile_var(st, node);
        case IF:
            jit_compile_if(st, node);
        case CALL:
            jit_compile_call(st, node);
        default:
            io::eprintfn("JIT: unsupported node %d, emitting 0", node.type.ordinal);
            jit_emit_op1(st.c, JIT_MOV, st.mem_sp, SLOT_CONV, JIT_IMM, 0);
            jit_emit_fop1(st.c, JIT_MOV_F64, JIT_FR0, 0, st.mem_sp, SLOT_CONV);
    }
}

fn void jit_compile_lit(JitState* st, AstNode* node) {
    ulong bits = (ulong)node.literal;
    jit_emit_op1(st.c, JIT_MOV, st.mem_sp, SLOT_CONV, JIT_IMM, (iptr)bits);
    jit_emit_fop1(st.c, JIT_MOV_F64, JIT_FR0, 0, st.mem_sp, SLOT_CONV);
}

fn void jit_compile_var(JitState* st, AstNode* node) {
    if (node.name_id == st.param_id) {
        jit_emit_fop1(st.c, JIT_MOV_F64, JIT_FR0, 0, st.param_fs, 0);
    } else {
        io::eprintfn("JIT: unknown var '%s', emitting 0", node.name);
        jit_emit_op1(st.c, JIT_MOV, st.mem_sp, SLOT_CONV, JIT_IMM, 0);
        jit_emit_fop1(st.c, JIT_MOV_F64, JIT_FR0, 0, st.mem_sp, SLOT_CONV);
    }
}

fn void jit_compile_if(JitState* st, AstNode* node) {
    AstNode* cond = node.children[0];

    if (cond.type == CALL && cond.children[0] != null && cond.children[0].type == PRIM) {
        String op = cond.children[0].name;
        int cmp_type = jit_cmp_type(op);
        if (cmp_type >= 0 && cond.children.len == 3) {
            jit_compile_expr(st, cond.children[1]);
            int slot = jit_tmp_slot(st);
            jit_emit_fop1(st.c, JIT_MOV_F64, st.mem_sp, slot, JIT_FR0, 0);

            st.depth++;
            jit_compile_expr(st, cond.children[2]);
            st.depth--;

            JitJump to_then = jit_emit_fcmp(st.c,
                cmp_type | JIT_JUMP_IF_NON_ZERO,
                st.mem_sp, slot, JIT_FR0, 0);

            jit_compile_expr(st, node.children[2]);
            JitJump skip_then = jit_emit_jump(st.c, JIT_JUMP);

            JitLabel then_label = jit_emit_label(st.c);
            jit_set_label(to_then, then_label);
            jit_compile_expr(st, node.children[1]);

            JitLabel end_label = jit_emit_label(st.c);
            jit_set_label(skip_then, end_label);
            return;
        }
    }

    jit_compile_expr(st, cond);
    jit_emit_op1(st.c, JIT_MOV, st.mem_sp, SLOT_CONV, JIT_IMM, 0);
    JitJump to_then = jit_emit_fcmp(st.c,
        JIT_F_NOT_EQUAL | JIT_JUMP_IF_NON_ZERO,
        JIT_FR0, 0, st.mem_sp, SLOT_CONV);

    jit_compile_expr(st, node.children[2]);
    JitJump skip_then = jit_emit_jump(st.c, JIT_JUMP);

    JitLabel then_label = jit_emit_label(st.c);
    jit_set_label(to_then, then_label);
    jit_compile_expr(st, node.children[1]);

    JitLabel end_label = jit_emit_label(st.c);
    jit_set_label(skip_then, end_label);
}

fn void jit_compile_call(JitState* st, AstNode* node) {
    AstNode* fn_node = node.children[0];
    if (fn_node == null) {
        io::eprintfn("JIT: CALL with null fn");
        jit_emit_op1(st.c, JIT_MOV, st.mem_sp, SLOT_CONV, JIT_IMM, 0);
        jit_emit_fop1(st.c, JIT_MOV_F64, JIT_FR0, 0, st.mem_sp, SLOT_CONV);
        return;
    }

    if (fn_node.type == PRIM) {
        String op = fn_node.name;
        int fop = jit_fop(op);
        if (fop >= 0 && node.children.len == 3) {
            jit_compile_expr(st, node.children[1]);
            int slot = jit_tmp_slot(st);
            jit_emit_fop1(st.c, JIT_MOV_F64, st.mem_sp, slot, JIT_FR0, 0);

            st.depth++;
            jit_compile_expr(st, node.children[2]);
            st.depth--;

            jit_emit_fop2(st.c, fop, JIT_FR0, 0,
                st.mem_sp, slot, JIT_FR0, 0);
            return;
        }

        io::eprintfn("JIT: unsupported prim '%s'", op);
        jit_emit_op1(st.c, JIT_MOV, st.mem_sp, SLOT_CONV, JIT_IMM, 0);
        jit_emit_fop1(st.c, JIT_MOV_F64, JIT_FR0, 0, st.mem_sp, SLOT_CONV);
        return;
    }

    if (fn_node.type == VAR && fn_node.name_id == st.fn_id) {
        if (node.children.len != 2) {
            io::eprintfn("JIT: recursive call expects 1 arg, got %d", node.children.len - 1);
            return;
        }

        // Compile argument → FR0 (double)
        jit_compile_expr(st, node.children[1]);

        // Convert double (FR0) → Value (ulong in R0) via stack bitcast
        jit_emit_fop1(st.c, JIT_MOV_F64, st.mem_sp, SLOT_CONV, JIT_FR0, 0);
        jit_emit_op1(st.c, JIT_MOV, JIT_R0, 0, st.mem_sp, SLOT_CONV);

        // Call ds_jit_recurse(R0) via C ABI (LOAD addr into R1 then BR R1).
        iptr addr = ds_get_helper_addr(0);
        jit_load_const(st.c, JIT_R1, (ulong)addr);
        jit_emit_icall(st.c, JIT_CALL,
            jit_args1(JIT_ARG_W, JIT_ARG_W), JIT_R1, 0);

        // Convert result Value (ulong in R0) → double (FR0) via stack
        jit_emit_op1(st.c, JIT_MOV, st.mem_sp, SLOT_CONV, JIT_R0, 0);
        jit_emit_fop1(st.c, JIT_MOV_F64, JIT_FR0, 0, st.mem_sp, SLOT_CONV);
        return;
    }
    io::eprintfn("JIT: unsupported call (fn type %d)", fn_node.type.ordinal);
    jit_emit_op1(st.c, JIT_MOV, st.mem_sp, SLOT_CONV, JIT_IMM, 0);
    jit_emit_fop1(st.c, JIT_MOV_F64, JIT_FR0, 0, st.mem_sp, SLOT_CONV);
}

// ============================================================================
// Helpers
// ============================================================================

fn AstNode* jit_find_letrec(AstNode* node) {
    if (node == null) return null;
    if (node.type == LETREC) return node;
    foreach (&c : node.children) {
        AstNode* found = jit_find_letrec(*c);
        if (found != null) return found;
    }
    return null;
}

fn int jit_fop(String op) {
    if (op == "+") return JIT_ADD_F64;
    if (op == "-") return JIT_SUB_F64;
    if (op == "*") return JIT_MUL_F64;
    if (op == "/") return JIT_DIV_F64;
    return -1;
}

fn int jit_cmp_type(String op) {
    if (op == "<=") return JIT_F_LESS_EQUAL;
    if (op == "<")  return JIT_F_LESS;
    if (op == ">=") return JIT_F_GREATER_EQUAL;
    if (op == ">")  return JIT_F_GREATER;
    if (op == "===") return JIT_F_EQUAL;
    return -1;
}

// ============================================================================
// Byte extraction for standalone executable generation
// ============================================================================
// Re-compiles the source, but instead of returning the function pointer we
// return the raw machine code bytes (still executable in the JIT buffer).
// Caveat: the bytes become invalid after jit_free_code is called; the caller
// must write them to a file or copy them into a new buffer immediately.

struct JitBytes {
    char[] bytes;
    void* fnptr;
}

JitBytes g_jit_keep;   // intentionally leaked: caller copies before free

fn bool jit_extract_supported() => true;

fn char[] jit_extract_bytes(String source) {
    @pool() {
        ParseResult pr = parse_source(source);
        if (pr.error) {
            io::eprintfn("extract: parse error: %s", pr.message);
            return (char[]){};
        }
        AstNode* kernel = desugar(pr.root, null);
        AstNode* letrec = jit_find_letrec(kernel);
        if (letrec == null) {
            io::eprintfn("extract: no LETREC found");
            return (char[]){};
        }

        AstNode* lambda = letrec.children[0];
        if (lambda == null || lambda.type != LAMBDA || lambda.names.len != 1) {
            io::eprintfn("extract: lambda missing or wrong shape");
            return (char[]){};
        }
        AstNode* body = lambda.children[0];
        if (body == null) {
            io::eprintfn("extract: null body");
            return (char[]){};
        }

        JitState st;
        st.c = jit_create_compiler(null);
        if (!st.c) {
            io::eprintfn("extract: sljit_create_compiler failed");
            return (char[]){};
        }
        st.param_fs  = jit_fs(0);
        st.param_id  = lambda.name_ids[0];
        st.fn_id     = letrec.name_id;
        st.depth     = 0;
        st.mem_sp    = jit_mem1(jit_sp());

        int scratches = 3 | jit_enter_float(3);
        int saveds    = 2 | jit_enter_float(2);
        jit_emit_enter(st.c, 0, jit_args1(JIT_ARG_W, JIT_ARG_W),
                       scratches, saveds, LOCAL_SIZE);

        jit_emit_op1(st.c, JIT_MOV, st.mem_sp, SLOT_CONV, JIT_R0, 0);
        jit_emit_fop1(st.c, JIT_MOV_F64, st.param_fs, 0, st.mem_sp, SLOT_CONV);

        jit_compile_expr(&st, body);

        jit_emit_fop1(st.c, JIT_MOV_F64, st.mem_sp, SLOT_CONV, JIT_FR0, 0);
        jit_emit_op1(st.c, JIT_MOV, JIT_R0, 0, st.mem_sp, SLOT_CONV);
        jit_emit_return(st.c, JIT_MOV, JIT_R0, 0);

        int err = jit_get_compiler_error(st.c);
        if (err != JIT_SUCCESS) {
            io::eprintfn("extract: sljit error %d", err);
            jit_free_compiler(st.c);
            return (char[]){};
        }

        // Generate the code first — this sets executable_size.
        void* code = jit_generate_code(st.c, 0, null);
        if (!code) {
            io::eprintfn("extract: jit_generate_code returned null");
            jit_free_compiler(st.c);
            return (char[]){};
        }

        ulong size = (ulong)jit_get_generated_code_size(st.c);
        jit_free_compiler(st.c);

        if (size == 0) {
            io::eprintfn("extract: 0 bytes generated");
            jit_free_code(code, null);
            return (char[]){};
        }

        char[] buf = mem::new_array(char, (sz)size);
        for (sz i = 0; i < (sz)size; i++) {
            buf[i] = ((char*)code)[i];
        }

        g_jit_keep.bytes  = buf;
        g_jit_keep.fnptr  = code;

        ds_jit_set_fn((ulong)(uptr)code);

        io::eprintfn("extract: %d bytes copied", (int)size);
        return buf;
    };
}