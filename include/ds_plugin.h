// ds_plugin.h — C plugin API for the DS engine.
//
// A plugin is a shared library (.dylib/.so) that exports:
//   void ds_init(DsApi* api);
//
// The engine calls ds_init with an API struct. The plugin calls
// api->register_fn("name", &fn) to register host functions.
//
// Host functions receive (DsValue* args, int nargs) and return DsResult.
// Use api->mk_num, api->mk_nil, etc. to create values.

#ifndef DS_PLUGIN_H
#define DS_PLUGIN_H

#include <stdint.h>
#include <stdbool.h>

// NaN-boxed value — same layout as the engine's Value type.
typedef uint64_t DsValue;

// Result returned by host functions.
typedef struct {
    DsValue value;
    int thrown;   // 0 = ok, 1 = thrown (error)
} DsResult;

// Host function signature.
typedef DsResult (*DsHostFn)(DsValue* args, int nargs);

// API struct passed to ds_init.
typedef struct {
    // Value creation
    DsValue (*mk_num)(double);
    DsValue (*mk_nil)(void);
    DsValue (*mk_bool)(int);
    DsValue (*mk_str)(const char*);  // null-terminated C string

    // Value extraction
    double  (*as_num)(DsValue);
    int     (*as_bool)(DsValue);

    // Value type checks (return 0 or 1)
    int     (*is_num)(DsValue);
    int     (*is_nil)(DsValue);
    int     (*is_str)(DsValue);

    // String access
    const char* (*as_cstr)(DsValue);   // extract string content (for string values)
    const char* (*show)(DsValue);      // any value -> temp-allocated C string

    // Register a host function. Returns true on success.
    int     (*register_fn)(const char* name, DsHostFn fn);
} DsApi;

// Helper: create a success result.
static inline DsResult ds_ok(DsValue v) {
    DsResult r = { v, 0 };
    return r;
}

// Helper: create an error result.
static inline DsResult ds_throw(DsValue v) {
    DsResult r = { v, 1 };
    return r;
}

#endif // DS_PLUGIN_H
