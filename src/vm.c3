module engine;
import std::io;

// ============================================================================
// VIRTUAL MACHINE — stack-based bytecode interpreter
// ============================================================================

// VmClosure wraps a Chunk* with upvalues (different from tree-walker Closure)
struct VmClosure {
	uint    refcount;
	Chunk*  proto;
	Upvalue** upvals;
	int     upval_count;
	int     param_count;
}

fn VmClosure* new_vm_closure(Chunk* proto, int param_count) {
	VmClosure* c = mem::new(VmClosure);
	c.refcount = 1;
	c.proto = proto;
	c.param_count = param_count;
	c.upval_count = 0;
	c.upvals = null;
	return c;
}

// VmClosure uses the same NaN-boxed tag as tree-walker Closure
fn Value val_vm_closure(VmClosure* p) => val_closure((Closure*)p);
fn VmClosure* as_vm_closure(Value v) => (VmClosure*)as_closure(v);
fn bool is_vm_closure(Value v) => is_closure(v);

// Upvalue: either points at a stack slot (open) or owns a heap Value (closed)
struct Upvalue {
	Value* location;  // pointer into the value stack (open) or to heap slot (closed)
	Value  closed;    // value when closed
	bool   is_open;
}

struct CallFrame {
	Chunk*  chunk;
	int     ip;
	int     base;      // stack index of frame's slot 0
	VmClosure* closure;
}

struct Vm {
	Value[4096]      stack;
	int              sp;
	CallFrame[512]   frames;
	int              fc;
	int[64]          handler_sp;
	int[64]          handler_frame;
	int              handler_top;
	Upvalue[256]     open_upvalues;
	int              open_count;
}

fn void vm_init(Vm* vm) {
	vm.sp = 0;
	vm.fc = 0;
	vm.handler_top = 0;
	vm.open_count = 0;
}

// --- upvalue management ---

fn Upvalue* find_or_create_upvalue(Vm* vm, Value* slot) {
	for (int i = vm.open_count - 1; i >= 0; i--) {
		if (vm.open_upvalues[i].location == slot && vm.open_upvalues[i].is_open) {
			return &vm.open_upvalues[i];
		}
	}
	// reuse a closed slot
	int reuse = -1;
	for (int i = 0; i < vm.open_count; i++) {
		if (!vm.open_upvalues[i].is_open) {
			reuse = i;
			break;
		}
	}
	if (reuse >= 0) {
		vm.open_upvalues[reuse].location = slot;
		vm.open_upvalues[reuse].is_open = true;
		vm.open_upvalues[reuse].closed = val_nil();
		return &vm.open_upvalues[reuse];
	}
	if (vm.open_count < 256) {
		vm.open_upvalues[vm.open_count].location = slot;
		vm.open_upvalues[vm.open_count].is_open = true;
		vm.open_upvalues[vm.open_count].closed = val_nil();
		vm.open_count++;
		return &vm.open_upvalues[vm.open_count - 1];
	}
	return null;
}

fn void close_upvalues_above(Vm* vm, Value* last) {
	if (vm.open_count == 0) return;
	for (int i = vm.open_count - 1; i >= 0; i--) {
		if (vm.open_upvalues[i].location < last) break;
		if (vm.open_upvalues[i].is_open) {
			Value snapshot = *vm.open_upvalues[i].location;
			vm_rc_inc_val(snapshot);
			vm.open_upvalues[i].closed = snapshot;
			vm.open_upvalues[i].is_open = false;
		}
	}
}

// VM-aware reference counting decrement — VmClosure has different layout
// than tree-walker Closure (upvals vs env), so rc_dec_val can't handle it.
fn void vm_rc_dec_val(Value v) @inline {
	// Numbers, bools, nil are the common case — skip immediately
	if (is_num(v) || is_nil(v) || is_bool(v)) return;
	if (is_arr(v)) {
		Array* a = as_arr(v);
		a.refcount--;
		if (a.refcount == 0) {
			mem::free(a.items);
			mem::free(a);
		}
	} else if (is_rec(v)) {
		Record* r = as_rec(v);
		r.refcount--;
		if (r.refcount == 0) {
			mem::free(r.keys);
			mem::free(r.values);
			mem::free(r);
		}
	} else if (is_closure(v)) {
		VmClosure* c = as_vm_closure(v);
		c.refcount--;
		if (c.refcount == 0) {
			// Upvalues are pool-managed (fixed Upvalue[256] in Vm struct),
			// not heap-allocated — do not free or deref them here.
			if (c.upvals != null) {
				mem::free(c.upvals);
			}
			mem::free(c);
		}
	}
}

fn void vm_rc_inc_val(Value v) @inline {
	// Numbers, bools, nil are the common case — skip immediately
	if (is_num(v) || is_nil(v) || is_bool(v)) return;
	if (is_arr(v))     { as_arr(v).refcount++; }
	else if (is_rec(v))     { as_rec(v).refcount++; }
	else if (is_closure(v)) { as_vm_closure(v).refcount++; }
}

// --- main dispatch loop ---

fn EvalResult vm_run(Vm* vm) {
	if (vm.fc == 0) {
		return { .thrown = true, .value = mk_str("vm: no frames") };
	}
	CallFrame* frame = &vm.frames[vm.fc - 1];

	while (true) {
		char byte_op = frame.chunk.code[frame.ip++];
		Op op = (Op)byte_op;

		switch (op) {
			case PUSH_CONST:
				int idx = (int)frame.chunk.code[frame.ip++];
				vm.stack[vm.sp++] = frame.chunk.constants[idx];

			case PUSH_NIL:
				vm.stack[vm.sp++] = val_nil();

			case POP:
				vm.sp--;
				vm_rc_dec_val(vm.stack[vm.sp]);

			case LOAD_LOCAL:
				int slot = (int)frame.chunk.code[frame.ip++];
				vm.stack[vm.sp] = vm.stack[frame.base + slot];
				vm_rc_inc_val(vm.stack[vm.sp]);
				vm.sp++;

			case STORE_LOCAL:
				int slot2 = (int)frame.chunk.code[frame.ip++];
				vm_rc_dec_val(vm.stack[frame.base + slot2]);
				vm.stack[frame.base + slot2] = vm.stack[vm.sp - 1];
				vm_rc_inc_val(vm.stack[frame.base + slot2]);
				// ensure sp stays above the local slot
				int min_sp = frame.base + slot2 + 1;
				if (vm.sp < min_sp) vm.sp = min_sp;

			case LOAD_UPVAL:
				int uv_idx = (int)frame.chunk.code[frame.ip++];
				Upvalue* uv = frame.closure.upvals[uv_idx];
				if (uv.is_open) {
					vm.stack[vm.sp++] = *uv.location;
				} else {
					vm.stack[vm.sp++] = uv.closed;
				}

			case STORE_UPVAL:
				int uv_idx2 = (int)frame.chunk.code[frame.ip++];
				Upvalue* uv2 = frame.closure.upvals[uv_idx2];
				if (uv2.is_open) {
					*uv2.location = vm.stack[vm.sp - 1];
				} else {
					uv2.closed = vm.stack[vm.sp - 1];
				}

			case CLOSE_UPVAL:
				close_upvalues_above(vm, &vm.stack[frame.base]);

			case MAKE_CLOSURE:
				int proto_idx = (int)frame.chunk.code[frame.ip++];
				int upval_count = (int)frame.chunk.code[frame.ip++];
				Chunk* proto = g_protos.protos[proto_idx].chunk;
				int param_count = g_protos.protos[proto_idx].param_count;
				VmClosure* closure = new_vm_closure(proto, param_count);
				if (upval_count > 0) {
					closure.upvals = mem::new_array(Upvalue*, upval_count);
					closure.upval_count = upval_count;
					for (int i = 0; i < upval_count; i++) {
						bool is_local = (int)frame.chunk.code[frame.ip++] != 0;
						int uv_op_idx = (int)frame.chunk.code[frame.ip++];
						if (is_local) {
							Value* slot = &vm.stack[frame.base + uv_op_idx];
							Upvalue* uv = find_or_create_upvalue(vm, slot);
							closure.upvals[i] = uv;
						} else {
							closure.upvals[i] = frame.closure.upvals[uv_op_idx];
						}
					}
				}
				vm.stack[vm.sp++] = val_vm_closure(closure);

			case CALL:
				int argc2 = (int)frame.chunk.code[frame.ip++];
				Value fn_val = vm.stack[vm.sp - argc2 - 1];
				if (is_vm_closure(fn_val)) {
					VmClosure* cl = as_vm_closure(fn_val);
					if (vm.fc >= 512) {
						return { .thrown = true, .value = mk_str("vm: stack overflow") };
					}
					// close upvalues that reference slots being overwritten
					close_upvalues_above(vm, &vm.stack[vm.sp - argc2]);
					CallFrame new_frame;
					new_frame.chunk = cl.proto;
					new_frame.ip = 0;
					new_frame.base = vm.sp - argc2;
					new_frame.closure = cl;
					vm.frames[vm.fc] = new_frame;
					vm.fc++;
					frame = &vm.frames[vm.fc - 1];
				} else if (is_prim(fn_val)) {
					Prim* p = as_prim(fn_val);
					Value result = call_builtin(vm, p.name, argc2);
					vm.sp -= argc2 + 1;
					vm.stack[vm.sp++] = result;
				} else {
					return { .thrown = true, .value = mk_str("vm: not callable") };
				}

			case TAILCALL:
				int argc3 = (int)frame.chunk.code[frame.ip++];
				Value fn_val2 = vm.stack[vm.sp - argc3 - 1];
				if (is_vm_closure(fn_val2)) {
					VmClosure* cl2 = as_vm_closure(fn_val2);
					close_upvalues_above(vm, &vm.stack[frame.base]);
					for (int i = 0; i < argc3; i++) {
						vm.stack[frame.base + i] = vm.stack[vm.sp - argc3 + i];
					}
					vm.sp = frame.base + argc3;
					frame.chunk = cl2.proto;
					frame.ip = 0;
					frame.closure = cl2;
				} else if (is_prim(fn_val2)) {
					Prim* p2 = as_prim(fn_val2);
					Value result2 = call_builtin(vm, p2.name, argc3);
					vm.stack[frame.base - 1] = result2;
					vm.sp = frame.base;
					vm.fc--;
					if (vm.fc == 0) return { .value = result2 };
					close_upvalues_above(vm, &vm.stack[frame.base]);
					frame = &vm.frames[vm.fc - 1];
				} else {
					return { .thrown = true, .value = mk_str("vm: not callable") };
				}

			case RETURN:
				Value result3 = vm.stack[--vm.sp];
				int callee_base = frame.base;
				vm.fc--;
				// Close upvalues BEFORE decrementing locals — this snapshots
				// values from stack slots into heap, so decrement won't free
				// a value still referenced by a closed upvalue.
				close_upvalues_above(vm, &vm.stack[callee_base]);
				// Decrement all local slots (balanced by rc_inc in STORE_LOCAL)
				for (int ri = 0; ri < vm.sp - callee_base; ri++) {
					vm_rc_dec_val(vm.stack[callee_base + ri]);
				}
				if (vm.fc == 0) return { .value = result3 };
				frame = &vm.frames[vm.fc - 1];
				vm.stack[callee_base - 1] = result3;
				vm.sp = callee_base;

			case JUMP:
				int offset = (int)frame.chunk.code[frame.ip++];
				int lo = (int)frame.chunk.code[frame.ip++];
				frame.ip += (offset << 8) | lo;

			case JUMP_IF_FALSE:
				int off_hi = (int)frame.chunk.code[frame.ip++];
				int off_lo = (int)frame.chunk.code[frame.ip++];
				if (!truthy(vm.stack[vm.sp - 1])) {
					frame.ip += (off_hi << 8) | off_lo;
				}
			case JUMP_IF_TRUE:
				int jit_hi = (int)frame.chunk.code[frame.ip++];
				int jit_lo = (int)frame.chunk.code[frame.ip++];
				if (truthy(vm.stack[vm.sp - 1])) {
					frame.ip += (jit_hi << 8) | jit_lo;
				}

			case ADD:
				Value b_add = vm.stack[--vm.sp];
				Value a_add = vm.stack[--vm.sp];
				if (is_num(a_add) && is_num(b_add)) {
					vm.stack[vm.sp++] = val_num(as_num(a_add) + as_num(b_add));
				} else if (is_str(a_add) && is_str(b_add)) {
					String sc = (*as_str(a_add)).tconcat(*as_str(b_add));
					vm.stack[vm.sp++] = mk_str(sc);
				} else {
					return { .thrown = true, .value = mk_str("type error: + requires numbers or strings") };
				}
			case SUB:
				Value b_sub = vm.stack[--vm.sp];
				Value a_sub = vm.stack[--vm.sp];
				if (!is_num(a_sub) || !is_num(b_sub)) {
					return { .thrown = true, .value = mk_str("type error: - requires numbers") };
				}
				vm.stack[vm.sp++] = val_num(as_num(a_sub) - as_num(b_sub));
			case MUL:
				Value b_mul = vm.stack[--vm.sp];
				Value a_mul = vm.stack[--vm.sp];
				if (!is_num(a_mul) || !is_num(b_mul)) {
					return { .thrown = true, .value = mk_str("type error: * requires numbers") };
				}
				vm.stack[vm.sp++] = val_num(as_num(a_mul) * as_num(b_mul));
			case DIV:
				Value b_div = vm.stack[--vm.sp];
				Value a_div = vm.stack[--vm.sp];
				if (!is_num(a_div) || !is_num(b_div)) {
					return { .thrown = true, .value = mk_str("type error: / requires numbers") };
				}
				if (as_num(b_div) == 0.0) {
					return { .thrown = true, .value = mk_str("division by zero") };
				}
				vm.stack[vm.sp++] = val_num(as_num(a_div) / as_num(b_div));
			case EQ:
				Value b_eq = vm.stack[--vm.sp];
				Value a_eq = vm.stack[--vm.sp];
				vm.stack[vm.sp++] = val_bool(strict_eq(a_eq, b_eq));
			case LT:
				Value b_lt = vm.stack[--vm.sp];
				Value a_lt = vm.stack[--vm.sp];
				if (!is_num(a_lt) || !is_num(b_lt)) {
					return { .thrown = true, .value = mk_str("type error: < requires numbers") };
				}
				vm.stack[vm.sp++] = val_bool(as_num(a_lt) < as_num(b_lt));
			case GT:
				Value b_gt = vm.stack[--vm.sp];
				Value a_gt = vm.stack[--vm.sp];
				if (!is_num(a_gt) || !is_num(b_gt)) {
					return { .thrown = true, .value = mk_str("type error: > requires numbers") };
				}
				vm.stack[vm.sp++] = val_bool(as_num(a_gt) > as_num(b_gt));
			case LE:
				Value b_le = vm.stack[--vm.sp];
				Value a_le = vm.stack[--vm.sp];
				if (!is_num(a_le) || !is_num(b_le)) {
					return { .thrown = true, .value = mk_str("type error: <= requires numbers") };
				}
				vm.stack[vm.sp++] = val_bool(as_num(a_le) <= as_num(b_le));
			case GE:
				Value b_ge = vm.stack[--vm.sp];
				Value a_ge = vm.stack[--vm.sp];
				if (!is_num(a_ge) || !is_num(b_ge)) {
					return { .thrown = true, .value = mk_str("type error: >= requires numbers") };
				}
				vm.stack[vm.sp++] = val_bool(as_num(a_ge) >= as_num(b_ge));
			case IS_NIL:
				vm.stack[vm.sp - 1] = val_bool(is_nil(vm.stack[vm.sp - 1]));
			case IS_NUM:
				vm.stack[vm.sp - 1] = val_bool(is_num(vm.stack[vm.sp - 1]));
			case IS_STR:
				vm.stack[vm.sp - 1] = val_bool(is_str(vm.stack[vm.sp - 1]));
			case IS_BOOL:
				vm.stack[vm.sp - 1] = val_bool(is_bool(vm.stack[vm.sp - 1]));
			case IS_ARR:
				vm.stack[vm.sp - 1] = val_bool(is_arr(vm.stack[vm.sp - 1]));
			case IS_REC:
				vm.stack[vm.sp - 1] = val_bool(is_rec(vm.stack[vm.sp - 1]));
			case GET_LEN:
				Value lv = vm.stack[vm.sp - 1];
				if (is_arr(lv)) {
					vm.stack[vm.sp - 1] = val_num((double)as_arr(lv).items.len);
				} else if (is_str(lv)) {
					vm.stack[vm.sp - 1] = val_num((double)(*as_str(lv)).len);
				} else {
					return { .thrown = true, .value = mk_str("type error: len requires array or string") };
				}
			case PRINT:
				Value pv = vm.stack[--vm.sp];
				Value ps = show(pv);
				io::printn(*as_str(ps));
				vm.stack[vm.sp++] = val_nil();
			case NOT:
				vm.stack[vm.sp - 1] = val_bool(!truthy(vm.stack[vm.sp - 1]));
			// --- fused opcodes ---
			case LOAD_LOCAL_LT_CONST:
				int flc_slot = (int)frame.chunk.code[frame.ip++];
				int flc_cidx = (int)frame.chunk.code[frame.ip++];
				Value flc_a = vm.stack[frame.base + flc_slot];
				Value flc_b = frame.chunk.constants[flc_cidx];
				if (!is_num(flc_a) || !is_num(flc_b)) {
					return { .thrown = true, .value = mk_str("type error: < requires numbers") };
				}
				vm.stack[vm.sp++] = val_bool(as_num(flc_a) < as_num(flc_b));
			case LOAD_LOCAL_SUB_CONST:
				int lsc_slot = (int)frame.chunk.code[frame.ip++];
				int lsc_cidx = (int)frame.chunk.code[frame.ip++];
				Value lsc_a = vm.stack[frame.base + lsc_slot];
				Value lsc_b = frame.chunk.constants[lsc_cidx];
				if (!is_num(lsc_a) || !is_num(lsc_b)) {
					return { .thrown = true, .value = mk_str("type error: - requires numbers") };
				}
				vm.stack[vm.sp++] = val_num(as_num(lsc_a) - as_num(lsc_b));
			case LOAD_FCALL:
				int fc_slot = (int)frame.chunk.code[frame.ip++];
				int fc_argc = (int)frame.chunk.code[frame.ip++];
				Value fc_fn = vm.stack[frame.base + fc_slot];
				// Don't push fn — args are already on the stack, fn is in the slot.
				// Dispatch directly, adjusting base for args-only layout.
				if (is_vm_closure(fc_fn)) {
					VmClosure* fc_cl = as_vm_closure(fc_fn);
					if (vm.fc >= 512) {
						return { .thrown = true, .value = mk_str("vm: stack overflow") };
					}
					close_upvalues_above(vm, &vm.stack[vm.sp - fc_argc]);
					CallFrame fc_new;
					fc_new.chunk = fc_cl.proto;
					fc_new.ip = 0;
					fc_new.base = vm.sp - fc_argc;
					fc_new.closure = fc_cl;
					vm.frames[vm.fc] = fc_new;
					vm.fc++;
					frame = &vm.frames[vm.fc - 1];
				} else if (is_prim(fc_fn)) {
					Prim* fc_p = as_prim(fc_fn);
					Value fc_result = call_builtin(vm, fc_p.name, fc_argc);
					vm.sp -= fc_argc;
					vm.stack[vm.sp++] = fc_result;
				} else {
					return { .thrown = true, .value = mk_str("vm: not callable") };
				}
			case TAILCALL_LOCAL:
				int tc_slot = (int)frame.chunk.code[frame.ip++];
				int tc_argc = (int)frame.chunk.code[frame.ip++];
				Value tc_fn = vm.stack[frame.base + tc_slot];
				// Don't push fn — args are on the stack, fn is in the slot.
				if (is_vm_closure(tc_fn)) {
					VmClosure* tc_cl = as_vm_closure(tc_fn);
					close_upvalues_above(vm, &vm.stack[frame.base]);
					for (int i = 0; i < tc_argc; i++) {
						vm.stack[frame.base + i] = vm.stack[vm.sp - tc_argc + i];
					}
					vm.sp = frame.base + tc_argc;
					frame.chunk = tc_cl.proto;
					frame.ip = 0;
					frame.closure = tc_cl;
				} else if (is_prim(tc_fn)) {
					Prim* tc_p = as_prim(tc_fn);
					Value tc_result = call_builtin(vm, tc_p.name, tc_argc);
					vm.stack[frame.base - 1] = tc_result;
					vm.sp = frame.base;
					vm.fc--;
					if (vm.fc == 0) return { .value = tc_result };
					close_upvalues_above(vm, &vm.stack[frame.base]);
					frame = &vm.frames[vm.fc - 1];
				} else {
					return { .thrown = true, .value = mk_str("vm: not callable") };
				}
			case NEW_RECORD:
				int nfields = (int)frame.chunk.code[frame.ip++];
				Record* rec = new_record();
				rec.keys = mem::talloc_array(uint, nfields);
				rec.values = mem::talloc_array(Value, nfields);
				for (int i = nfields - 1; i >= 0; i--) {
					Value key_val = vm.stack[--vm.sp];
					rec.values[i] = vm.stack[--vm.sp];
					rec.keys[i] = (uint)as_num(key_val);
				}
				vm.stack[vm.sp++] = val_rec(rec);
			case GET_FIELD:
				int gf_atom = (int)frame.chunk.code[frame.ip++];
				Value gf_obj = vm.stack[--vm.sp];
				if (is_rec(gf_obj)) {
					Record* gf_r = as_rec(gf_obj);
					bool gf_found = false;
					for (int gf_i = 0; gf_i < gf_r.keys.len; gf_i++) {
						if (gf_r.keys[gf_i] == (uint)gf_atom) {
							vm.stack[vm.sp++] = gf_r.values[gf_i];
							gf_found = true;
							break;
						}
					}
					if (!gf_found) {
						return { .thrown = true, .value = mk_str(string::tformat("no field '%s'", atom_name((uint)gf_atom))) };
					}
				} else {
					return { .thrown = true, .value = mk_str("type error: GET_FIELD on non-record") };
				}
			case SET_FIELD:
				int sf_atom = (int)frame.chunk.code[frame.ip++];
				Value sf_val = vm.stack[--vm.sp];
				Value sf_obj = vm.stack[--vm.sp];
				if (is_rec(sf_obj)) {
					Record* sf_r = as_rec(sf_obj);
					bool sf_found = false;
					for (int sf_i = 0; sf_i < sf_r.keys.len; sf_i++) {
						if (sf_r.keys[sf_i] == (uint)sf_atom) {
							sf_r.values[sf_i] = sf_val;
							sf_found = true;
							break;
						}
					}
					if (!sf_found) {
						return { .thrown = true, .value = mk_str(string::tformat("no field '%s'", atom_name((uint)sf_atom))) };
					}
					vm.stack[vm.sp++] = sf_val;
				} else {
					return { .thrown = true, .value = mk_str("type error: SET_FIELD on non-record") };
				}
			case GET_INDEX:
				Value idx = vm.stack[--vm.sp];
				Value obj = vm.stack[--vm.sp];
				if (is_arr(obj)) {
					Array* a = as_arr(obj);
					if (!is_num(idx)) {
						return { .thrown = true, .value = mk_str("type error: array index must be number") };
					}
					long i2 = (long)as_num(idx);
					if (i2 < 0 || i2 >= a.items.len) {
						return { .thrown = true, .value = mk_str("index out of bounds") };
					}
					vm.stack[vm.sp++] = a.items[i2];
				} else if (is_rec(obj)) {
					Record* r2 = as_rec(obj);
					uint want;
					if (is_str(idx)) {
						want = intern(*as_str(idx));
					} else if (is_num(idx)) {
						want = (uint)as_num(idx);
					} else {
						return { .thrown = true, .value = mk_str("type error: record key must be string") };
					}
					bool found = false;
					for (int i3 = 0; i3 < r2.keys.len; i3++) {
						if (r2.keys[i3] == want) {
							vm.stack[vm.sp++] = r2.values[i3];
							found = true;
							break;
						}
					}
					if (!found) {
						return { .thrown = true, .value = mk_str(string::tformat("no field '%s'", atom_name(want))) };
					}
				} else {
					return { .thrown = true, .value = mk_str("cannot index value") };
				}
			case SET_INDEX:
				Value val2 = vm.stack[--vm.sp];
				Value idx2 = vm.stack[--vm.sp];
				Value obj2 = vm.stack[--vm.sp];
				if (is_arr(obj2)) {
					Array* a2 = as_arr(obj2);
					if (!is_num(idx2)) {
						return { .thrown = true, .value = mk_str("type error: array index must be number") };
					}
					long i4 = (long)as_num(idx2);
					if (i4 < 0 || i4 >= a2.items.len) {
						return { .thrown = true, .value = mk_str("index out of bounds") };
					}
					a2.items[i4] = val2;
					vm.stack[vm.sp++] = val2;
				} else if (is_rec(obj2)) {
					Record* r3 = as_rec(obj2);
					if (!is_num(idx2)) {
						return { .thrown = true, .value = mk_str("type error: record key must be string") };
					}
					uint want2 = (uint)as_num(idx2);
					for (int i5 = 0; i5 < r3.keys.len; i5++) {
						if (r3.keys[i5] == want2) {
							r3.values[i5] = val2;
							vm.stack[vm.sp++] = val2;
							break;
						}
					}
					uint[] new_keys = mem::new_array(uint, r3.keys.len + 1);
					Value[] new_vals = mem::new_array(Value, r3.values.len + 1);
					for (int j = 0; j < r3.keys.len; j++) {
						new_keys[j] = r3.keys[j];
						new_vals[j] = r3.values[j];
					}
					new_keys[r3.keys.len] = want2;
					new_vals[r3.values.len] = val2;
					r3.keys = new_keys;
					r3.values = new_vals;
					vm.stack[vm.sp++] = val2;
				} else {
					return { .thrown = true, .value = mk_str("cannot set on value") };
				}
			case NEW_ARRAY:
				int narr = (int)frame.chunk.code[frame.ip++];
				Array* arr = new_array();
				arr.items = mem::talloc_array(Value, narr);
				for (int i6 = narr - 1; i6 >= 0; i6--) {
					arr.items[i6] = vm.stack[--vm.sp];
				}
				vm.stack[vm.sp++] = val_arr(arr);
			case PUSH_HANDLER:
				int handler_offset = (int)frame.chunk.code[frame.ip++];
				int handler_lo = (int)frame.chunk.code[frame.ip++];
				if (vm.handler_top < 64) {
					vm.handler_sp[vm.handler_top] = vm.sp;
					vm.handler_frame[vm.handler_top] = vm.fc;
					vm.handler_top++;
				}
				frame.ip += (handler_offset << 8) | handler_lo;
			case POP_HANDLER:
				if (vm.handler_top > 0) {
					vm.handler_top--;
				}
			case THROW:
				Value throw_val = vm.stack[--vm.sp];
				if (vm.handler_top > 0) {
					vm.handler_top--;
					vm.sp = vm.handler_sp[vm.handler_top];
					vm.fc = vm.handler_frame[vm.handler_top];
					frame = &vm.frames[vm.fc - 1];
					vm.stack[vm.sp++] = throw_val;
				} else {
					return { .thrown = true, .value = throw_val };
				}
		}
	}
}

// --- builtin dispatch ---

fn Value call_builtin(Vm* vm, String name, int argc) {
	Value[8] args;
	for (int i = 0; i < argc; i++) {
		args[i] = vm.stack[vm.sp - argc + i];
	}
	EvalResult r = prim_dispatch(name, args[0:argc]);
	return r.value;
}

// --- VM entry point ---

fn EvalResult vm_execute(Chunk* chunk) {
	Vm vm;
	vm_init(&vm);
	vm.stack[0] = val_nil();
	vm.frames[0].chunk = chunk;
	vm.frames[0].ip = 0;
	vm.frames[0].base = 1;
	vm.frames[0].closure = null;
	vm.fc = 1;
	EvalResult result = vm_run(&vm);
	return result;
}
