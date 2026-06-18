module engine;
import std::io;

// ============================================================================
// COMPILER — single recursive pass over kernel AST → bytecode
// ============================================================================

struct Local {
    uint name_id;
    int slot;
    int depth;
    bool is_captured;
}

struct CompilerUpvalue {
    int index;
    bool is_local;
}

struct Compiler {
    Chunk* chunk;
    Local[256] locals;
    int local_count;
    int scope_depth;
    Compiler* enclosing;
    CompilerUpvalue[256] upvalues;
    int upvalue_count;
    int param_count;
}

fn void compiler_init(Compiler* c, Compiler* enclosing, int param_count) {
    c.chunk = null;
    c.local_count = 0;
    c.scope_depth = 0;
    c.enclosing = enclosing;
    c.upvalue_count = 0;
    c.param_count = param_count;
}

fn void begin_scope(Compiler* c) {
    c.scope_depth++;
}

fn void end_scope(Compiler* c) {
    while (c.local_count > 0 && c.locals[c.local_count - 1].depth > c.scope_depth) {
        if (c.locals[c.local_count - 1].is_captured) {
            emit_op(c.chunk, (char)Op.CLOSE_UPVAL, 0);
        } else {
            emit_op(c.chunk, (char)Op.POP, 0);
        }
        c.local_count--;
    }
    c.scope_depth--;
}

fn int resolve_local(Compiler* c, uint name_id) {
    for (int i = c.local_count - 1; i >= 0; i--) {
        if (c.locals[i].name_id == name_id) {
            return c.locals[i].slot;
        }
    }
    return -1;
}

fn int add_local(Compiler* c, uint name_id) {
    if (c.local_count >= 256) return -1;
    int slot = c.local_count;
    c.locals[c.local_count].name_id = name_id;
    c.locals[c.local_count].slot = slot;
    c.locals[c.local_count].depth = c.scope_depth;
    c.locals[c.local_count].is_captured = false;
    c.local_count++;
    return slot;
}

fn int add_upvalue(Compiler* c, int index, bool is_local) {
    for (int i = 0; i < c.upvalue_count; i++) {
        if (c.upvalues[i].index == index && c.upvalues[i].is_local == is_local) {
            return i;
        }
    }
    if (c.upvalue_count >= 256) return -1;
    int uv = c.upvalue_count;
    c.upvalues[uv].index = index;
    c.upvalues[uv].is_local = is_local;
    c.upvalue_count++;
    return uv;
}

fn int resolve_upvalue(Compiler* c, uint name_id) {
    if (c.enclosing == null) return -1;
    int local = resolve_local(c.enclosing, name_id);
    if (local >= 0) {
        c.enclosing.locals[local].is_captured = true;
        return add_upvalue(c, local, true);
    }
    int uv = resolve_upvalue(c.enclosing, name_id);
    if (uv >= 0) {
        return add_upvalue(c, uv, false);
    }
    return -1;
}

fn bool try_emit_builtin(Compiler* c, String name) {
    switch (name) {
        case "+":
        case "-":
        case "*":
        case "/":
        case "===":
        case "<":
        case ">":
        case "<=":
        case ">=":
        case "and":
        case "or":
        case "is_number":
        case "is_string":
        case "is_bool":
        case "is_array":
        case "is_record":
        case "is_nil":
        case "has_field":
        case "len":
        case "push":
        case "print":
        case "array_all":
        case "slice":
            int idx = add_constant(c.chunk, mk_prim(name));
            emit_op(c.chunk, (char)Op.PUSH_CONST, 0);
            emit_op(c.chunk, (char)idx, 0);
            return true;
    }
    // Check host-registered functions
    if (has_host_fn(name)) {
        int idx = add_constant(c.chunk, mk_prim(name));
        emit_op(c.chunk, (char)Op.PUSH_CONST, 0);
        emit_op(c.chunk, (char)idx, 0);
        return true;
    }
    return false;
}

fn void emit_load(Compiler* c, uint name_id) {
    int slot = resolve_local(c, name_id);
    if (slot >= 0) {
        emit_op(c.chunk, (char)Op.LOAD_LOCAL, 0);
        emit_op(c.chunk, (char)slot, 0);
        return;
    }
    int uv = resolve_upvalue(c, name_id);
    if (uv >= 0) {
        emit_op(c.chunk, (char)Op.LOAD_UPVAL, 0);
        emit_op(c.chunk, (char)uv, 0);
        return;
    }
    String name = atom_name(name_id);
    if (try_emit_builtin(c, name)) return;
    io::printfn("compile error: unresolved variable '%s'", name);
}

fn void emit_store(Compiler* c, uint name_id) {
    int slot = resolve_local(c, name_id);
    if (slot >= 0) {
        emit_op(c.chunk, (char)Op.STORE_LOCAL, 0);
        emit_op(c.chunk, (char)slot, 0);
        return;
    }
    int uv = resolve_upvalue(c, name_id);
    if (uv >= 0) {
        emit_op(c.chunk, (char)Op.STORE_UPVAL, 0);
        emit_op(c.chunk, (char)uv, 0);
        return;
    }
    io::printfn("compile error: unresolved variable for store");
}

fn void compile_fn_body(Compiler* parent, AstNode* node, int line) {
    Compiler fn_comp;
    compiler_init(&fn_comp, parent, node.name_ids.len);

    Chunk fn_chunk;
    chunk_init(&fn_chunk);
    fn_comp.chunk = &fn_chunk;

    begin_scope(&fn_comp);
    for (int i = 0; i < node.name_ids.len; i++) {
        add_local(&fn_comp, node.name_ids[i]);
    }

    compile_expr(&fn_comp, node.children[0], true);
    emit_op(fn_comp.chunk, (char)Op.RETURN, line);
    end_scope(&fn_comp);

    // Copy the function chunk's code into a heap-allocated Chunk
    Chunk* heap_chunk = mem::new(Chunk);
    chunk_init(heap_chunk);
    heap_chunk.code_cap = fn_chunk.code_len;
    heap_chunk.code = mem::new_array(char, fn_chunk.code_len);
    for (int i = 0; i < fn_chunk.code_len; i++) heap_chunk.code[i] = fn_chunk.code[i];
    heap_chunk.code_len = fn_chunk.code_len;

    heap_chunk.const_cap = fn_chunk.const_len;
    heap_chunk.constants = mem::new_array(Value, fn_chunk.const_len > 0 ? fn_chunk.const_len : 1);
    for (int i = 0; i < fn_chunk.const_len; i++) heap_chunk.constants[i] = fn_chunk.constants[i];
    heap_chunk.const_len = fn_chunk.const_len;

    heap_chunk.lines_cap = fn_chunk.lines_len;
    heap_chunk.lines = mem::new_array(int, fn_chunk.lines_len > 0 ? fn_chunk.lines_len : 1);
    for (int i = 0; i < fn_chunk.lines_len; i++) heap_chunk.lines[i] = fn_chunk.lines[i];
    heap_chunk.lines_len = fn_chunk.lines_len;

    // free the temp chunk
    chunk_free(&fn_chunk);

    // store the chunk pointer in the global proto table
    int proto_idx = proto_table_add(&g_protos, heap_chunk, node.name_ids.len);
    emit_op(parent.chunk, (char)Op.MAKE_CLOSURE, line);
    emit_op(parent.chunk, (char)proto_idx, line);
    emit_op(parent.chunk, (char)fn_comp.upvalue_count, line);
    for (int i = 0; i < fn_comp.upvalue_count; i++) {
        emit_op(parent.chunk, fn_comp.upvalues[i].is_local ? (char)1 : (char)0, line);
        emit_op(parent.chunk, (char)fn_comp.upvalues[i].index, line);
    }
}

// Try to emit an inline opcode for a known Prim call.
// Returns true if the call was inlined (caller should NOT emit CALL).
fn bool try_emit_inline_prim(Compiler* c, String name, AstNode* node, bool tail_pos) {
    int argc = node.children.len - 1;

    // Binary arithmetic — 2 args, emit dedicated opcode
    if (argc == 2) {
        Op arith_op;
        bool found = false;
        switch (name) {
            case "+": arith_op = Op.ADD; found = true;
            case "-": arith_op = Op.SUB; found = true;
            case "*": arith_op = Op.MUL; found = true;
            case "/": arith_op = Op.DIV; found = true;
            case "===": arith_op = Op.EQ; found = true;
            case "<": arith_op = Op.LT; found = true;
            case ">": arith_op = Op.GT; found = true;
            case "<=": arith_op = Op.LE; found = true;
            case ">=": arith_op = Op.GE; found = true;
        }
        if (found) {
            // Fused opcodes for hot patterns: LOAD_LOCAL <op> CONST
            if (argc == 2 && node.children[1].type == VAR && node.children[2].type == LIT) {
                int local_slot = resolve_local(c, node.children[1].name_id);
                if (local_slot >= 0 && is_num(node.children[2].literal)) {
                    int const_idx = add_constant(c.chunk, node.children[2].literal);
                    if (name == "<") {
                        emit_op(c.chunk, (char)Op.LOAD_LOCAL_LT_CONST, 0);
                        emit_op(c.chunk, (char)local_slot, 0);
                        emit_op(c.chunk, (char)const_idx, 0);
                        return true;
                    }
                    if (name == "-") {
                        emit_op(c.chunk, (char)Op.LOAD_LOCAL_SUB_CONST, 0);
                        emit_op(c.chunk, (char)local_slot, 0);
                        emit_op(c.chunk, (char)const_idx, 0);
                        return true;
                    }
                }
            }
            // General path: compile args, emit opcode
            compile_expr(c, node.children[1], false);
            compile_expr(c, node.children[2], false);
            emit_op(c.chunk, (char)arith_op, 0);
            return true;
        }
        // Short-circuit and/or
        if (name == "and") {
            // a and b → if a is falsy, result is a; else result is b
            compile_expr(c, node.children[1], false);
            int skip = emit_jump(c.chunk, (char)Op.JUMP_IF_FALSE, 0);
            emit_op(c.chunk, (char)Op.POP, 0);
            compile_expr(c, node.children[2], false);
            patch_jump(c.chunk, skip);
            return true;
        }
        if (name == "or") {
            // a or b → if a is truthy, result is a; else result is b
            compile_expr(c, node.children[1], false);
            int skip = emit_jump(c.chunk, (char)Op.JUMP_IF_TRUE, 0);
            emit_op(c.chunk, (char)Op.POP, 0);
            compile_expr(c, node.children[2], false);
            patch_jump(c.chunk, skip);
            return true;
        }
    }

    // Unary — 1 arg
    if (argc == 1) {
        if (name == "not") {
            compile_expr(c, node.children[1], false);
            emit_op(c.chunk, (char)Op.NOT, 0);
            return true;
        }
        if (name == "print") {
            compile_expr(c, node.children[1], false);
            emit_op(c.chunk, (char)Op.PRINT, 0);
            return true;
        }
        if (name == "len") {
            compile_expr(c, node.children[1], false);
            emit_op(c.chunk, (char)Op.GET_LEN, 0);
            return true;
        }
        if (name == "is_nil") {
            compile_expr(c, node.children[1], false);
            emit_op(c.chunk, (char)Op.IS_NIL, 0);
            return true;
        }
        if (name == "is_number") {
            compile_expr(c, node.children[1], false);
            emit_op(c.chunk, (char)Op.IS_NUM, 0);
            return true;
        }
        if (name == "is_string") {
            compile_expr(c, node.children[1], false);
            emit_op(c.chunk, (char)Op.IS_STR, 0);
            return true;
        }
        if (name == "is_bool") {
            compile_expr(c, node.children[1], false);
            emit_op(c.chunk, (char)Op.IS_BOOL, 0);
            return true;
        }
        if (name == "is_array") {
            compile_expr(c, node.children[1], false);
            emit_op(c.chunk, (char)Op.IS_ARR, 0);
            return true;
        }
        if (name == "is_record") {
            compile_expr(c, node.children[1], false);
            emit_op(c.chunk, (char)Op.IS_REC, 0);
            return true;
        }
    }

    return false;
}

fn void compile_expr(Compiler* c, AstNode* node, bool tail_pos) {
    int line = 0;

    switch (node.type) {
        case LIT:
            int idx = add_constant(c.chunk, node.literal);
            emit_op(c.chunk, (char)Op.PUSH_CONST, line);
            emit_op(c.chunk, (char)idx, line);

        case VAR:
            emit_load(c, node.name_id);

        case LAMBDA:
            compile_fn_body(c, node, line);

        case CALL:
            // Check if callee is a Prim that can be inlined to a dedicated opcode
            AstNode* callee = node.children[0];
            if (callee.type == PRIM) {
                if (try_emit_inline_prim(c, callee.name, node, tail_pos)) {
                    return;
                }
            }
            // Fused LOAD_FCALL: load local + call in one dispatch
            int call_argc = node.children.len - 1;
            if (callee.type == VAR) {
                int call_slot = resolve_local(c, callee.name_id);
                if (call_slot >= 0) {
                    // compile args
                    for (int i = 1; i < node.children.len; i++) {
                        compile_expr(c, node.children[i], false);
                    }
                    if (tail_pos) {
                        emit_op(c.chunk, (char)Op.TAILCALL_LOCAL, line);
                        emit_op(c.chunk, (char)call_slot, line);
                        emit_op(c.chunk, (char)call_argc, line);
                    } else {
                        emit_op(c.chunk, (char)Op.LOAD_FCALL, line);
                        emit_op(c.chunk, (char)call_slot, line);
                        emit_op(c.chunk, (char)call_argc, line);
                    }
                    return;
                }
            }
            // General path: compile callee + args, emit CALL/TAILCALL
            compile_expr(c, callee, false);
            for (int i = 1; i < node.children.len; i++) {
                compile_expr(c, node.children[i], false);
            }
            char call_op = tail_pos ? (char)Op.TAILCALL : (char)Op.CALL;
            emit_op(c.chunk, call_op, line);
            emit_op(c.chunk, (char)call_argc, line);

        case IF:
            compile_expr(c, node.children[0], false);
            int then_jump = emit_jump(c.chunk, (char)Op.JUMP_IF_FALSE, line);
            emit_op(c.chunk, (char)Op.POP, line);
            compile_expr(c, node.children[1], tail_pos);
            int else_jump = emit_jump(c.chunk, (char)Op.JUMP, line);
            patch_jump(c.chunk, then_jump);
            emit_op(c.chunk, (char)Op.POP, line);
            compile_expr(c, node.children[2], tail_pos);
            patch_jump(c.chunk, else_jump);

        case LETREC:
            begin_scope(c);
            add_local(c, node.name_id);
            emit_op(c.chunk, (char)Op.PUSH_NIL, line);
            emit_op(c.chunk, (char)Op.STORE_LOCAL, line);
            emit_op(c.chunk, (char)(c.local_count - 1), line);

            compile_expr(c, node.children[0], false);
            emit_op(c.chunk, (char)Op.STORE_LOCAL, line);
            emit_op(c.chunk, (char)(c.local_count - 1), line);

            compile_expr(c, node.children[1], tail_pos);
            end_scope(c);

        case GET:
            // Literal string key → use GET_FIELD with inline atom
            if (node.children[1].type == LIT && is_str(node.children[1].literal)) {
                compile_expr(c, node.children[0], false);
                uint atom = intern(*as_str(node.children[1].literal));
                emit_op(c.chunk, (char)Op.GET_FIELD, line);
                emit_op(c.chunk, (char)atom, line);
            } else {
                compile_expr(c, node.children[0], false);
                compile_expr(c, node.children[1], false);
                emit_op(c.chunk, (char)Op.GET_INDEX, line);
            }

        case SET:
            // Literal string key → use SET_FIELD with inline atom
            if (node.children[1].type == LIT && is_str(node.children[1].literal)) {
                compile_expr(c, node.children[0], false);
                compile_expr(c, node.children[2], false);
                uint satom = intern(*as_str(node.children[1].literal));
                emit_op(c.chunk, (char)Op.SET_FIELD, line);
                emit_op(c.chunk, (char)satom, line);
            } else {
                compile_expr(c, node.children[0], false);
                compile_expr(c, node.children[1], false);
                compile_expr(c, node.children[2], false);
                emit_op(c.chunk, (char)Op.SET_INDEX, line);
            }

        case RECORD:
            int nfields = node.children.len;
            for (int i = 0; i < nfields; i++) {
                compile_expr(c, node.children[i], false);
                int key_idx = add_constant(c.chunk, val_num((double)node.name_ids[i]));
                emit_op(c.chunk, (char)Op.PUSH_CONST, line);
                emit_op(c.chunk, (char)key_idx, line);
            }
            emit_op(c.chunk, (char)Op.NEW_RECORD, line);
            emit_op(c.chunk, (char)nfields, line);

        case ARRAY_LIT:
            int narr = node.children.len;
            for (int i = 0; i < narr; i++) {
                compile_expr(c, node.children[i], false);
            }
            emit_op(c.chunk, (char)Op.NEW_ARRAY, line);
            emit_op(c.chunk, (char)narr, line);

        case THROW:
            compile_expr(c, node.children[0], false);
            emit_op(c.chunk, (char)Op.THROW, line);

        case TRY:
            int handler_jump = emit_jump(c.chunk, (char)Op.PUSH_HANDLER, line);
            compile_expr(c, node.children[0], false);
            emit_op(c.chunk, (char)Op.POP_HANDLER, line);
            int skip_handler = emit_jump(c.chunk, (char)Op.JUMP, line);
            patch_jump(c.chunk, handler_jump);
            begin_scope(c);
            add_local(c, node.name_id);
            compile_expr(c, node.children[1], tail_pos);
            end_scope(c);
            patch_jump(c.chunk, skip_handler);

        case NULLCOAL:
            // try lhs; if thrown or nil, eval rhs
            int nc_handler = emit_jump(c.chunk, (char)Op.PUSH_HANDLER, line);
            compile_expr(c, node.children[0], false);
            emit_op(c.chunk, (char)Op.POP_HANDLER, line);
            emit_op(c.chunk, (char)Op.IS_NIL, line);
            int nc_if_nil = emit_jump(c.chunk, (char)Op.JUMP_IF_TRUE, line);
            int nc_skip_rhs = emit_jump(c.chunk, (char)Op.JUMP, line);
            // thrown path: discard error, fall through to rhs
            patch_jump(c.chunk, nc_handler);
            emit_op(c.chunk, (char)Op.POP, line);
            // nil path
            patch_jump(c.chunk, nc_if_nil);
            emit_op(c.chunk, (char)Op.POP, line); // pop nil or IS_NIL true
            compile_expr(c, node.children[1], tail_pos);
            patch_jump(c.chunk, nc_skip_rhs);

        case PRIM:
            int prim_idx = add_constant(c.chunk, mk_prim(node.name));
            emit_op(c.chunk, (char)Op.PUSH_CONST, line);
            emit_op(c.chunk, (char)prim_idx, line);

        case SEQ:
        case BINOP:
        case METHODCALL:
        case LET_T:
        case LAMBDA_T:
        case TYPEDEF:
        case CONSTRUCT:
        case MATCH:
        case PMATCH:
            io::printfn("compile error: surface node reached the compiler; desugar first");
    }
}

fn Chunk* compile(AstNode* node) {
    Chunk* chunk = mem::new(Chunk);
    chunk_init(chunk);

    Compiler compiler;
    compiler_init(&compiler, null, 0);
    compiler.chunk = chunk;

    compile_expr(&compiler, node, true);
    emit_op(chunk, (char)Op.RETURN, 0);

    return chunk;
}