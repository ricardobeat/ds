module engine;

// ============================================================================
// SLJIT FFI — stack-less JIT compiler bindings
//
// Requires: jit_wrapper.c compiled with -Isljit_src and -lpthread -lm
//           linked alongside sljit_src/sljitLir.c
// ============================================================================

// --- Opaque types ---

alias JitCompiler = void*;
alias JitLabel    = void*;
alias JitJump     = void*;
alias JitConst    = void*;

// --- Error codes ---

const int JIT_SUCCESS          = 0;
const int JIT_ERR_COMPILED     = 1;
const int JIT_ERR_ALLOC_FAILED = 2;
const int JIT_ERR_EX_ALLOC     = 3;
const int JIT_ERR_UNSUPPORTED  = 4;
const int JIT_ERR_BAD_ARGUMENT = 5;

// --- Registers (architecture-independent constants) ---

const int JIT_R0 = 1;
const int JIT_R1 = 2;
const int JIT_R2 = 3;
const int JIT_R3 = 4;
const int JIT_R4 = 5;
const int JIT_R5 = 6;
const int JIT_R6 = 7;
const int JIT_R7 = 8;
const int JIT_R8 = 9;
const int JIT_R9 = 10;

const int JIT_RETURN_REG = JIT_R0;

// Architecture queries — use these at runtime since register count varies.
extern fn int jit_num_registers();
extern fn int jit_num_saved_registers();

// Saved registers — computed at runtime: JIT_S0 = jit_num_registers(), JIT_S1 = jit_num_registers() - 1, etc.
fn int jit_s(int i) => jit_num_registers() - i;

// --- Operand encoding ---

const int JIT_MEM = 0x80;
const int JIT_IMM = 0x7f;

fn int jit_mem1(int r)         => JIT_MEM | r;
fn int jit_mem2(int r1, int r2) => JIT_MEM | r1 | (r2 << 8);

fn bool jit_is_reg(int arg) => arg > 0 && arg < JIT_IMM;
fn bool jit_is_mem(int arg) => (arg & JIT_MEM) != 0;
fn bool jit_is_imm(int arg) => arg == JIT_IMM;

// --- 32-bit operation flag ---

const int JIT_32 = 0x100;

// --- Status flags ---

const int JIT_SET_Z = 0x0200;

// Comparison types (must match SLJIT_* values in sljitLir.h)
const int JIT_EQUAL             = 0;
const int JIT_NOT_EQUAL         = 1;
const int JIT_LESS              = 2;
const int JIT_GREATER_EQUAL     = 3;
const int JIT_GREATER           = 4;
const int JIT_LESS_EQUAL        = 5;
const int JIT_SIG_LESS          = 6;
const int JIT_SIG_GREATER_EQUAL = 7;
const int JIT_SIG_GREATER       = 8;
const int JIT_SIG_LESS_EQUAL    = 9;
const int JIT_OVERFLOW          = 10;
const int JIT_NOT_OVERFLOW      = 11;
const int JIT_CARRY             = 12;
const int JIT_NOT_CARRY         = 13;

fn int jit_set_flag(int condition) => condition << 10;

// --- Jump types ---

const int JIT_JUMP             = 36;
const int JIT_JUMP_IF_NON_ZERO = 0;
const int JIT_JUMP_IF_ZERO     = JIT_SET_Z;

// --- Call types ---

const int JIT_CALL_REG_ARG = 39;
const int JIT_CALL         = 38;
const int JIT_REWRITABLE_JUMP = 0x10000;
const int JIT_CALL_RETURN  = 0x20000;

// --- Argument types for jit_args macros ---

const int JIT_ARG_VOID = 0;
const int JIT_ARG_W    = 1;
const int JIT_ARG_W_R  = 9;
const int JIT_ARG_32   = 2;
const int JIT_ARG_32_R = 10;
const int JIT_ARG_P    = 3;
const int JIT_ARG_P_R  = 11;
const int JIT_ARG_F64  = 4;
const int JIT_ARG_F32  = 5;

const int JIT_ARG_SHIFT = 4;

fn int jit_args0(int ret) => ret;
fn int jit_args0v()       => JIT_ARG_VOID;

fn int jit_args1(int ret, int a1) =>
    jit_args0(ret) | (a1 << JIT_ARG_SHIFT);
fn int jit_args1v(int a1) =>
    jit_args0v() | (a1 << JIT_ARG_SHIFT);

fn int jit_args2(int ret, int a1, int a2) =>
    jit_args1(ret, a1) | (a2 << (2 * JIT_ARG_SHIFT));
fn int jit_args2v(int a1, int a2) =>
    jit_args1v(a1) | (a2 << (2 * JIT_ARG_SHIFT));

fn int jit_args3(int ret, int a1, int a2, int a3) =>
    jit_args2(ret, a1, a2) | (a3 << (3 * JIT_ARG_SHIFT));
fn int jit_args3v(int a1, int a2, int a3) =>
    jit_args2v(a1, a2) | (a3 << (3 * JIT_ARG_SHIFT));

fn int jit_args4(int ret, int a1, int a2, int a3, int a4) =>
    jit_args3(ret, a1, a2, a3) | (a4 << (4 * JIT_ARG_SHIFT));
fn int jit_args4v(int a1, int a2, int a3, int a4) =>
    jit_args3v(a1, a2, a3) | (a4 << (4 * JIT_ARG_SHIFT));

// --- Enter options ---

const int JIT_ENTER_REG_ARG = 0x00000004;

fn int jit_enter_keep(int n) => n;
fn int jit_enter_float(int regs) => regs << 8;
fn int jit_enter_vector(int regs) => regs << 16;

// --- Op0 opcodes ---

const int JIT_BREAKPOINT  = 0;
const int JIT_NOP         = 1;
const int JIT_LMUL_UW     = 2;
const int JIT_LMUL_SW     = 3;
const int JIT_DIVMOD_UW   = 4;
const int JIT_DIVMOD_U32  = 4 | JIT_32;
const int JIT_DIVMOD_SW   = 5;
const int JIT_DIVMOD_S32  = 5 | JIT_32;
const int JIT_DIV_UW      = 6;
const int JIT_DIV_U32     = 6 | JIT_32;
const int JIT_DIV_SW      = 7;
const int JIT_DIV_S32     = 7 | JIT_32;

// --- Op1 opcodes ---

const int JIT_MOV       = 32 + 0;
const int JIT_MOV_U8    = 32 + 1;
const int JIT_MOV32_U8  = 32 + 1 | JIT_32;
const int JIT_MOV_S8    = 32 + 2;
const int JIT_MOV32_S8  = 32 + 2 | JIT_32;
const int JIT_MOV_U16   = 32 + 3;
const int JIT_MOV32_U16 = 32 + 3 | JIT_32;
const int JIT_MOV_S16   = 32 + 4;
const int JIT_MOV32_S16 = 32 + 4 | JIT_32;
const int JIT_MOV_U32   = 32 + 5;
const int JIT_MOV_S32   = 32 + 6;
const int JIT_MOV32     = 32 + 7;
const int JIT_MOV_P     = 32 + 8;
const int JIT_CLZ       = 32 + 9;
const int JIT_CLZ32     = 32 + 9 | JIT_32;

// --- Op2 opcodes ---

const int JIT_ADD     = 64 + 0;
const int JIT_ADD32   = 64 + 0 | JIT_32;
const int JIT_ADDC    = 64 + 1;
const int JIT_ADDC32  = 64 + 1 | JIT_32;
const int JIT_SUB     = 64 + 2;
const int JIT_SUB32   = 64 + 2 | JIT_32;
const int JIT_SUBC    = 64 + 3;
const int JIT_SUBC32  = 64 + 3 | JIT_32;
const int JIT_MUL     = 64 + 4;
const int JIT_MUL32   = 64 + 4 | JIT_32;
const int JIT_AND     = 64 + 5;
const int JIT_AND32   = 64 + 5 | JIT_32;
const int JIT_OR      = 64 + 6;
const int JIT_OR32    = 64 + 6 | JIT_32;
const int JIT_XOR     = 64 + 7;
const int JIT_XOR32   = 64 + 7 | JIT_32;
const int JIT_SHL     = 64 + 8;
const int JIT_SHL32   = 64 + 8 | JIT_32;
const int JIT_MSHL    = 64 + 9;
const int JIT_MSHL32  = 64 + 9 | JIT_32;
const int JIT_LSHR    = 64 + 10;
const int JIT_LSHR32  = 64 + 10 | JIT_32;
const int JIT_MLSHR   = 64 + 11;
const int JIT_MLSHR32 = 64 + 11 | JIT_32;
const int JIT_ASHR    = 64 + 12;
const int JIT_ASHR32  = 64 + 12 | JIT_32;
const int JIT_MASHR   = 64 + 13;
const int JIT_MASHR32 = 64 + 13 | JIT_32;
const int JIT_ROTL    = 64 + 14;
const int JIT_ROTL32  = 64 + 14 | JIT_32;
const int JIT_ROTR    = 64 + 15;
const int JIT_ROTR32  = 64 + 15 | JIT_32;

// --- Generate option flags ---

const int JIT_GEN_BUFFER     = 0x1;
const int JIT_GEN_NO_CONTEXT = 0x2;

// --- CPU feature flags ---

const int JIT_HAS_FPU               = 0;
const int JIT_HAS_VIRTUAL_REGISTERS = 1;
const int JIT_HAS_ZERO_REGISTER     = 2;
const int JIT_HAS_CLZ               = 3;
const int JIT_HAS_CTZ               = 4;

// ============================================================================
// EXTERN C DECLARATIONS (all resolved through jit_wrapper.c)
// ============================================================================

// sljit_s32 → int; sljit_sw → iptr (pointer-sized signed); sljit_uw → uptr

// --- Compiler lifecycle ---

extern fn JitCompiler jit_create_compiler(void* allocator_data);
extern fn void        jit_free_compiler(JitCompiler c);
extern fn int         jit_get_compiler_error(JitCompiler c);
extern fn void        jit_set_compiler_memory_error(JitCompiler c);
extern fn void*       jit_generate_code(JitCompiler c, int options, void* exec_data);
extern fn void        jit_free_code(void* code, void* exec_data);
extern fn uptr        jit_get_generated_code_size(JitCompiler c);
extern fn iptr        jit_get_executable_offset(JitCompiler c);
extern fn void*       jit_alloc_memory(JitCompiler c, int size);

// --- Entry / context / return ---

extern fn int jit_emit_enter(JitCompiler c,
    int options, int arg_types,
    int scratches, int saveds, int local_size);

extern fn int jit_set_context(JitCompiler c,
    int options, int arg_types,
    int scratches, int saveds, int local_size);

extern fn int jit_emit_return(JitCompiler c, int op,
    int src, iptr srcw);

extern fn int jit_emit_return_void(JitCompiler c);

extern fn int jit_emit_return_to(JitCompiler c,
    int src, iptr srcw);

// --- Instructions ---

extern fn int jit_emit_op0(JitCompiler c, int op);

extern fn int jit_emit_op1(JitCompiler c, int op,
    int dst, iptr dstw,
    int src, iptr srcw);

extern fn int jit_emit_op2(JitCompiler c, int op,
    int dst, iptr dstw,
    int src1, iptr src1w,
    int src2, iptr src2w);

extern fn int jit_emit_op2u(JitCompiler c, int op,
    int src1, iptr src1w,
    int src2, iptr src2w);

// --- Memory ---

extern fn int jit_emit_mem(JitCompiler c, int type,
    int reg,
    int mem, iptr memw);

extern fn int jit_get_local_base(JitCompiler c,
    int dst, iptr dstw, iptr offset);

// --- Control flow ---

extern fn JitLabel jit_emit_label(JitCompiler c);
extern fn JitJump  jit_emit_jump(JitCompiler c, int type);

extern fn JitJump jit_emit_cmp(JitCompiler c, int type,
    int src1, iptr src1w,
    int src2, iptr src2w);

extern fn void jit_set_label(JitJump jump, JitLabel label);
extern fn void jit_set_target(JitJump jump, uptr target);

// --- Calls ---

extern fn int jit_emit_icall(JitCompiler c, int type, int arg_types,
    int src, iptr srcw);

extern fn JitJump jit_emit_call(JitCompiler c, int type, int arg_types);

// --- Constants ---

extern fn JitConst jit_emit_const(JitCompiler c, int op,
    int dst, iptr dstw, iptr value);

extern fn void jit_set_const(uptr addr, int op,
    iptr new_constant, iptr exec_offset);

extern fn void jit_set_jump_addr(uptr addr,
    uptr new_target, iptr exec_offset);

// --- CPU features / platform ---

extern fn int jit_has_cpu_feature(int feature);
extern fn int jit_get_register_index(int type, int reg);

// ============================================================================
// FLOATING POINT REGISTERS AND OPERATIONS
// ============================================================================

const int JIT_FR0 = 1;
const int JIT_FR1 = 2;
const int JIT_FR2 = 3;
const int JIT_RETURN_FREG = JIT_FR0;

// Float saved registers — computed at runtime like jit_s()
fn int jit_fs(int i) => jit_num_float_registers() - i;

// Stack pointer register (for SLJIT_MEM1(SLJIT_SP) stack access)
fn int jit_sp() => jit_num_registers() + 1;

// --- Float Op1 opcodes ---

const int JIT_FOP1_BASE  = 144;
const int JIT_MOV_F64    = JIT_FOP1_BASE + 0;

// --- Float Op2 opcodes ---

const int JIT_FOP2_BASE  = 176;
const int JIT_ADD_F64    = JIT_FOP2_BASE + 0;
const int JIT_SUB_F64    = JIT_FOP2_BASE + 1;
const int JIT_MUL_F64    = JIT_FOP2_BASE + 2;
const int JIT_DIV_F64    = JIT_FOP2_BASE + 3;

// --- Float comparison ---

const int JIT_CMP_F64    = JIT_FOP1_BASE + 8;

const int JIT_F_EQUAL         = 16;
const int JIT_F_NOT_EQUAL     = 17;
const int JIT_F_LESS          = 18;
const int JIT_F_GREATER_EQUAL = 19;
const int JIT_F_GREATER       = 20;
const int JIT_F_LESS_EQUAL    = 21;

// --- Long constant emit ---
// jit_emit_const allocates a 64-bit immediate in the code stream. The
// returned handle + offset is what we patch. For tiny values we still
// use MOV+JIT_IMM, but for 64-bit pointers we must use this path.

fn void jit_load_const(JitCompiler c, int reg, ulong value) {
    JitConst h = jit_emit_const(c, JIT_MOV, reg, 0, (iptr)value);
    // No patch needed since value is known at codegen time.
}

// --- Float operation extern declarations ---

extern fn int jit_num_float_registers();
extern fn int jit_num_saved_float_registers();

extern fn int jit_emit_fop1(JitCompiler c, int op,
    int dst, iptr dstw,
    int src, iptr srcw);

extern fn int jit_emit_fop2(JitCompiler c, int op,
    int dst, iptr dstw,
    int src1, iptr src1w,
    int src2, iptr src2w);

extern fn JitJump jit_emit_fcmp(JitCompiler c, int type,
    int src1, iptr src1w,
    int src2, iptr src2w);

// --- DS value bridge extern declarations ---

extern fn ulong ds_box_double(double d);
extern fn double ds_unbox_double(ulong v);
extern fn ulong ds_jit_recurse(ulong arg);
extern fn void ds_jit_set_fn(ulong faddr);
extern fn iptr ds_get_helper_addr(int op);
