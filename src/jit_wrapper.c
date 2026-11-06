#include "sljitLir.h"

// Architecture constants exposed for C3

sljit_s32 jit_num_registers(void) {
    return SLJIT_NUMBER_OF_REGISTERS;
}

sljit_s32 jit_num_saved_registers(void) {
    return SLJIT_NUMBER_OF_SAVED_REGISTERS;
}

// Inline functions C3 cannot call — expose as extern wrappers

sljit_s32 jit_get_compiler_error(struct sljit_compiler *c) {
    return sljit_get_compiler_error(c);
}

sljit_uw jit_get_generated_code_size(struct sljit_compiler *c) {
    return sljit_get_generated_code_size(c);
}

sljit_sw jit_get_executable_offset(struct sljit_compiler *c) {
    return sljit_get_executable_offset(c);
}

// Full wrappers with jit_ prefix for all SLJIT functions

struct sljit_compiler* jit_create_compiler(void *allocator_data) {
    return sljit_create_compiler(allocator_data);
}

void jit_free_compiler(struct sljit_compiler *c) {
    sljit_free_compiler(c);
}

void jit_set_compiler_memory_error(struct sljit_compiler *c) {
    sljit_set_compiler_memory_error(c);
}

void* jit_alloc_memory(struct sljit_compiler *c, sljit_s32 size) {
    return sljit_alloc_memory(c, size);
}

void* jit_generate_code(struct sljit_compiler *c, sljit_s32 options, void *exec_data) {
    return sljit_generate_code(c, options, exec_data);
}

void jit_free_code(void *code, void *exec_data) {
    sljit_free_code(code, exec_data);
}

// Entry / context / return

sljit_s32 jit_emit_enter(struct sljit_compiler *c,
    sljit_s32 options, sljit_s32 arg_types,
    sljit_s32 scratches, sljit_s32 saveds, sljit_s32 local_size)
{
    return sljit_emit_enter(c, options, arg_types, scratches, saveds, local_size);
}

sljit_s32 jit_set_context(struct sljit_compiler *c,
    sljit_s32 options, sljit_s32 arg_types,
    sljit_s32 scratches, sljit_s32 saveds, sljit_s32 local_size)
{
    return sljit_set_context(c, options, arg_types, scratches, saveds, local_size);
}

sljit_s32 jit_emit_return(struct sljit_compiler *c, sljit_s32 op,
    sljit_s32 src, sljit_sw srcw)
{
    return sljit_emit_return(c, op, src, srcw);
}

sljit_s32 jit_emit_return_void(struct sljit_compiler *c) {
    return sljit_emit_return_void(c);
}

sljit_s32 jit_emit_return_to(struct sljit_compiler *c,
    sljit_s32 src, sljit_sw srcw)
{
    return sljit_emit_return_to(c, src, srcw);
}

// Instructions

sljit_s32 jit_emit_op0(struct sljit_compiler *c, sljit_s32 op) {
    return sljit_emit_op0(c, op);
}

sljit_s32 jit_emit_op1(struct sljit_compiler *c, sljit_s32 op,
    sljit_s32 dst, sljit_sw dstw,
    sljit_s32 src, sljit_sw srcw)
{
    return sljit_emit_op1(c, op, dst, dstw, src, srcw);
}

sljit_s32 jit_emit_op2(struct sljit_compiler *c, sljit_s32 op,
    sljit_s32 dst, sljit_sw dstw,
    sljit_s32 src1, sljit_sw src1w,
    sljit_s32 src2, sljit_sw src2w)
{
    return sljit_emit_op2(c, op, dst, dstw, src1, src1w, src2, src2w);
}

sljit_s32 jit_emit_op2u(struct sljit_compiler *c, sljit_s32 op,
    sljit_s32 src1, sljit_sw src1w,
    sljit_s32 src2, sljit_sw src2w)
{
    return sljit_emit_op2u(c, op, src1, src1w, src2, src2w);
}

// Memory

sljit_s32 jit_emit_mem(struct sljit_compiler *c, sljit_s32 type,
    sljit_s32 reg,
    sljit_s32 mem, sljit_sw memw)
{
    return sljit_emit_mem(c, type, reg, mem, memw);
}

sljit_s32 jit_get_local_base(struct sljit_compiler *c,
    sljit_s32 dst, sljit_sw dstw, sljit_sw offset)
{
    return sljit_get_local_base(c, dst, dstw, offset);
}

// Control flow

struct sljit_label* jit_emit_label(struct sljit_compiler *c) {
    return sljit_emit_label(c);
}

struct sljit_jump* jit_emit_jump(struct sljit_compiler *c, sljit_s32 type) {
    return sljit_emit_jump(c, type);
}

struct sljit_jump* jit_emit_cmp(struct sljit_compiler *c, sljit_s32 type,
    sljit_s32 src1, sljit_sw src1w,
    sljit_s32 src2, sljit_sw src2w)
{
    return sljit_emit_cmp(c, type, src1, src1w, src2, src2w);
}

void jit_set_label(struct sljit_jump *jump, struct sljit_label *label) {
    sljit_set_label(jump, label);
}

void jit_set_target(struct sljit_jump *jump, sljit_uw target) {
    sljit_set_target(jump, target);
}

// Calls

sljit_s32 jit_emit_icall(struct sljit_compiler *c, sljit_s32 type,
    sljit_s32 arg_types, sljit_s32 src, sljit_sw srcw)
{
    return sljit_emit_icall(c, type, arg_types, src, srcw);
}

struct sljit_jump* jit_emit_call(struct sljit_compiler *c,
    sljit_s32 type, sljit_s32 arg_types)
{
    return sljit_emit_call(c, type, arg_types);
}

// Constants

struct sljit_const* jit_emit_const(struct sljit_compiler *c, sljit_s32 op,
    sljit_s32 dst, sljit_sw dstw, sljit_sw value)
{
    return sljit_emit_const(c, op, dst, dstw, value);
}

void jit_set_const(sljit_uw addr, sljit_s32 op,
    sljit_sw new_constant, sljit_sw exec_offset)
{
    sljit_set_const(addr, op, new_constant, exec_offset);
}

void jit_set_jump_addr(sljit_uw addr, sljit_uw new_target, sljit_sw exec_offset) {
    sljit_set_jump_addr(addr, new_target, exec_offset);
}

// CPU / platform

sljit_s32 jit_has_cpu_feature(sljit_s32 feature) {
    return sljit_has_cpu_feature(feature);
}

sljit_s32 jit_get_register_index(sljit_s32 type, sljit_s32 reg) {
    return sljit_get_register_index(type, reg);
}

// ============================================================================
// FLOATING POINT OPERATION WRAPPERS
// ============================================================================

sljit_s32 jit_num_float_registers(void) {
    return SLJIT_NUMBER_OF_FLOAT_REGISTERS;
}

sljit_s32 jit_num_saved_float_registers(void) {
    return SLJIT_NUMBER_OF_SAVED_FLOAT_REGISTERS;
}

sljit_s32 jit_emit_fop1(struct sljit_compiler *c, sljit_s32 op,
    sljit_s32 dst, sljit_sw dstw,
    sljit_s32 src, sljit_sw srcw)
{
    return sljit_emit_fop1(c, op, dst, dstw, src, srcw);
}

sljit_s32 jit_emit_fop2(struct sljit_compiler *c, sljit_s32 op,
    sljit_s32 dst, sljit_sw dstw,
    sljit_s32 src1, sljit_sw src1w,
    sljit_s32 src2, sljit_sw src2w)
{
    return sljit_emit_fop2(c, op, dst, dstw, src1, src1w, src2, src2w);
}

struct sljit_jump* jit_emit_fcmp(struct sljit_compiler *c, sljit_s32 type,
    sljit_s32 src1, sljit_sw src1w,
    sljit_s32 src2, sljit_sw src2w)
{
    return sljit_emit_fcmp(c, type, src1, src1w, src2, src2w);
}

// ============================================================================
// DS VALUE BRIDGE FUNCTIONS — for JIT-generated code to call
// ============================================================================

#include <string.h>

static const sljit_uw DS_NAN_BITS = 0x7FF8000000000000UL;
static const sljit_uw DS_TAG_MASK = 0xFFFF000000000000UL;
static const sljit_uw DS_TAG_NIL  = 0x7FFC000000000000UL;
static const sljit_uw DS_TAG_BOOL = 0x7FFD000000000000UL;

sljit_uw ds_box_double(double d) {
    sljit_uw result;
    memcpy(&result, &d, sizeof(double));
    return result;
}

double ds_unbox_double(sljit_uw v) {
    double result;
    memcpy(&result, &v, sizeof(double));
    return result;
}

// --- Recursive call support ---

static sljit_uw g_jit_fn = 0;

void ds_jit_set_fn(sljit_uw fn) { g_jit_fn = fn; }

sljit_uw ds_jit_recurse(sljit_uw arg) {
    typedef sljit_uw (*Fn)(sljit_uw);
    return ((Fn)g_jit_fn)(arg);
}

// --- Helper address lookup ---

sljit_sw ds_get_helper_addr(sljit_s32 op) {
    switch (op) {
        case 0: return (sljit_sw)&ds_jit_recurse;
        default: return 0;
    }
}
