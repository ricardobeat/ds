module engine;

// ============================================================================
// BYTECODE CHUNK
// ============================================================================

enum Op : char {
    // stack
    PUSH_CONST, // [Op, char const_idx]
    PUSH_NIL,
    POP,
    // locals


    LOAD_LOCAL, // [Op, char slot]
    STORE_LOCAL,
    // upvalues


    LOAD_UPVAL, // [Op, char upval_idx]
    STORE_UPVAL,
    // functions


    MAKE_CLOSURE, // [Op, char proto_idx, char upval_count, <upval_is_local, upval_idx>...]
    CALL,         // [Op, char argc]
    TAILCALL,     // [Op, char argc] — reuses current frame
    RETURN,
    // control


    JUMP,          // [Op, i16 offset] little-endian
    JUMP_IF_FALSE, // [Op, i16 offset] — does not pop
    JUMP_IF_TRUE,  // [Op, i16 offset] — does not pop
    // aggregates


    NEW_RECORD, // [Op, char nfields] — pops 2*nfields (key atoms interleaved with values)
    GET_FIELD,  // [Op, char atom_idx] — pops record, pushes value
    SET_FIELD,  // [Op, char atom_idx] — pops value + record, pushes value
    NEW_ARRAY,  // [Op, char n] — pops n values
    GET_INDEX,  // pops index + array
    SET_INDEX,  // pops value + index + array
    // exceptions


    PUSH_HANDLER, // [Op, i16 offset] — points past the handler
    POP_HANDLER,
    THROW,
    // arithmetic / comparison (inline, no function call)


    ADD,
    SUB,
    MUL,
    DIV,
    EQ,
    LT,
    GT,
    LE,
    GE,
    // type checks (inline)


    IS_NIL,
    IS_NUM,
    IS_STR,
    IS_BOOL,
    IS_ARR,
    IS_REC,
    // builtins with known arities


    GET_LEN, // pops 1, pushes length
    PRINT,   // pops 1, prints, pushes nil
    // boolean


    NOT, // pops 1, pushes logical not
    // fused opcodes (peephole optimization for hot paths)


    LOAD_LOCAL_LT_CONST,  // [Op, slot, const_idx] — push(stack[base+slot] < constants[idx])
    LOAD_LOCAL_SUB_CONST, // [Op, slot, const_idx] — push(stack[base+slot] - constants[idx])
    LOAD_FCALL,           // [Op, slot, argc] — load local, immediately CALL
    TAILCALL_LOCAL,       // [Op, slot, argc] — load local, immediately TAILCALL
    // special


    CLOSE_UPVAL, // close an open upvalue (move from stack to heap)
}

// ============================================================================
// FUNCTION PROTOS — chunks stored separately from NaN-boxed constants
// ============================================================================

const int MAX_PROTOS = 4096;
struct ProtoEntry {
    Chunk* chunk;
    int param_count;
}
struct ProtoTable {
    ProtoEntry[MAX_PROTOS] protos;
    int len;
}

fn void proto_table_init(ProtoTable* pt) {
    pt.len = 0;
}

fn int proto_table_add(ProtoTable* pt, Chunk* c, int param_count) {
    if (pt.len >= MAX_PROTOS) return -1;
    pt.protos[pt.len].chunk = c;
    pt.protos[pt.len].param_count = param_count;
    return pt.len++;
}

// Global proto table — shared across all chunks
ProtoTable g_protos;

struct Chunk {
    char* code;
    int code_len;
    int code_cap;
    Value* constants;
    int const_len;
    int const_cap;
    int* lines;
    int lines_len;
    int lines_cap;
}

fn void chunk_init(Chunk* c) {
    c.code = null;
    c.code_len = 0;
    c.code_cap = 0;
    c.constants = null;
    c.const_len = 0;
    c.const_cap = 0;
    c.lines = null;
    c.lines_len = 0;
    c.lines_cap = 0;
}

fn void chunk_free(Chunk* c) {
    if (c.code != null) mem::free(c.code);
    if (c.constants != null) mem::free(c.constants);
    if (c.lines != null) mem::free(c.lines);
    c.code = null;
    c.constants = null;
    c.lines = null;
    c.code_len = 0;
    c.const_len = 0;
    c.lines_len = 0;
}

fn void emit_op(Chunk* c, char b, int line) {
    if (c.code_len >= c.code_cap) {
        c.code_cap = c.code_cap == 0 ? 64 : c.code_cap * 2;
        char* new_code = mem::new_array(char, c.code_cap);
        if (c.code != null) {
            for (int i = 0; i < c.code_len; i++) new_code[i] = c.code[i];
            mem::free(c.code);
        }
        c.code = new_code;
    }
    if (c.lines_len >= c.lines_cap) {
        c.lines_cap = c.lines_cap == 0 ? 64 : c.lines_cap * 2;
        int* new_lines = mem::new_array(int, c.lines_cap);
        if (c.lines != null) {
            for (int i = 0; i < c.lines_len; i++) new_lines[i] = c.lines[i];
            mem::free(c.lines);
        }
        c.lines = new_lines;
    }
    c.code[c.code_len++] = b;
    c.lines[c.lines_len++] = line;
}

fn int add_constant(Chunk* c, Value v) {
    if (c.const_len >= c.const_cap) {
        c.const_cap = c.const_cap == 0 ? 32 : c.const_cap * 2;
        Value* new_consts = mem::new_array(Value, c.const_cap);
        if (c.constants != null) {
            for (int i = 0; i < c.const_len; i++) new_consts[i] = c.constants[i];
            mem::free(c.constants);
        }
        c.constants = new_consts;
    }
    c.constants[c.const_len] = v;
    return c.const_len++;
}

fn int emit_jump(Chunk* c, char op, int line) {
    emit_op(c, op, line);
    emit_op(c, 0, line); // high byte of offset
    emit_op(c, 0, line); // low byte of offset
    return c.code_len - 2; // return position of the 2-byte offset
}

fn void patch_jump(Chunk* c, int offset) {
    int jump = c.code_len - offset - 2;
    c.code[offset] = (char)((jump >> 8) & 0xFF);
    c.code[offset + 1] = (char)(jump & 0xFF);
}

fn int read_u16(Chunk* c, int offset) {
    int hi = (int)c.code[offset];
    int lo = (int)c.code[offset + 1];
    return (hi << 8) | lo;
}

fn int read_i16(Chunk* c, int offset) {
    int val = read_u16(c, offset);
    if (val >= 0x8000) val -= 0x10000;
    return val;
}