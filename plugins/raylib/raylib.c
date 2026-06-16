// raylib.c — Raylib plugin for the DS engine.
//
// Build: cc -shared -o build/libraylib.dylib plugins/raylib/raylib.c \
//          -I/opt/homebrew/include -L/opt/homebrew/lib -lraylib \
//          -framework OpenGL -framework Cocoa -framework IOKit \
//          -framework CoreAudio -framework CoreVideo

#include "../../include/ds_plugin.h"
#include <stddef.h>
#include <stdint.h>

typedef struct { float x, y; } RL_Vector2;
typedef struct { float x, y, z; } RL_Vector3;
typedef struct { unsigned char r, g, b, a; } RL_Color;
typedef struct { RL_Vector3 position, target, up; float fovy; int projection; } RL_Camera3D;

extern void InitWindow(int w, int h, const char* title);
extern void CloseWindow(void);
extern int  WindowShouldClose(void);
extern void SetTargetFPS(int fps);
extern int  IsWindowReady(void);
extern void BeginDrawing(void);
extern void EndDrawing(void);
extern void ClearBackground(RL_Color color);
extern void BeginMode3D(RL_Camera3D cam);
extern void EndMode3D(void);
extern void DrawCube(RL_Vector3 pos, float w, float h, float l, RL_Color color);
extern void DrawCubeWires(RL_Vector3 pos, float w, float h, float l, RL_Color color);
extern void DrawSphere(RL_Vector3 pos, float radius, RL_Color color);
extern void DrawPlane(RL_Vector3 pos, RL_Vector2 size, RL_Color color);
extern void DrawGrid(int slices, float spacing);
extern void DrawLine3D(RL_Vector3 start, RL_Vector3 end, RL_Color color);
extern void DrawCylinder(RL_Vector3 pos, float rtop, float rbot, float h, int slices, RL_Color color);
extern void DrawCylinderWires(RL_Vector3 pos, float rtop, float rbot, float h, int slices, RL_Color color);
extern void DrawText(const char* text, int x, int y, int size, RL_Color color);
extern void DrawFPS(int x, int y);
extern double GetTime(void);
extern float  GetFrameTime(void);
extern int    IsKeyDown(int key);

static DsApi* api = NULL;

static double arg(DsValue* args, int nargs, int i, double fb) {
    if (i >= nargs || !api->is_num(args[i])) return fb;
    return api->as_num(args[i]);
}

static RL_Color clr(DsValue* args, int nargs, int i) {
    // DS passes 3 or 4 numbers starting at args[i]: r, g, b [, a]
    RL_Color c;
    c.r = (unsigned char)arg(args, nargs, i, 255);
    c.g = (unsigned char)arg(args, nargs, i + 1, 255);
    c.b = (unsigned char)arg(args, nargs, i + 2, 255);
    c.a = (unsigned char)arg(args, nargs, i + 3, 255);
    return c;
}

static RL_Vector3 v3(DsValue* args, int i) {
    RL_Vector3 v;
    v.x = (float)api->as_num(args[i]);
    v.y = (float)api->as_num(args[i + 1]);
    v.z = (float)api->as_num(args[i + 2]);
    return v;
}

// ── Host functions ──────────────────────────────────────────────

static DsResult fn_init_window(DsValue* a, int n) {
    InitWindow((int)arg(a, n, 0, 800), (int)arg(a, n, 1, 600),
               (n > 2 && api->is_str(a[2])) ? api->as_cstr(a[2]) : "DS + Raylib");
    return ds_ok(api->mk_nil());
}
static DsResult fn_close_window(DsValue* a, int n) { CloseWindow(); return ds_ok(api->mk_nil()); }
static DsResult fn_window_should_close(DsValue* a, int n) { return ds_ok(api->mk_bool(WindowShouldClose())); }
static DsResult fn_set_target_fps(DsValue* a, int n) { SetTargetFPS((int)arg(a, n, 0, 60)); return ds_ok(api->mk_nil()); }
static DsResult fn_is_window_ready(DsValue* a, int n) { return ds_ok(api->mk_bool(IsWindowReady())); }
static DsResult fn_begin_drawing(DsValue* a, int n) { BeginDrawing(); return ds_ok(api->mk_nil()); }
static DsResult fn_end_drawing(DsValue* a, int n) { EndDrawing(); return ds_ok(api->mk_nil()); }

static DsResult fn_clear_background(DsValue* a, int n) { ClearBackground(clr(a, n, 0)); return ds_ok(api->mk_nil()); }

static DsResult fn_begin_mode_3d(DsValue* a, int n) {
    RL_Camera3D cam;
    cam.position = v3(a, 0);
    cam.target = v3(a, 3);
    cam.up = v3(a, 6);
    cam.fovy = (float)arg(a, n, 9, 45);
    cam.projection = (int)arg(a, n, 10, 0);
    BeginMode3D(cam);
    return ds_ok(api->mk_nil());
}
static DsResult fn_end_mode_3d(DsValue* a, int n) { EndMode3D(); return ds_ok(api->mk_nil()); }

static DsResult fn_draw_cube(DsValue* a, int n) {
    DrawCube(v3(a, 0), (float)arg(a, n, 3, 1), (float)arg(a, n, 4, 1), (float)arg(a, n, 5, 1), clr(a, n, 6));
    return ds_ok(api->mk_nil());
}
static DsResult fn_draw_cube_wires(DsValue* a, int n) {
    DrawCubeWires(v3(a, 0), (float)arg(a, n, 3, 1), (float)arg(a, n, 4, 1), (float)arg(a, n, 5, 1), clr(a, n, 6));
    return ds_ok(api->mk_nil());
}
static DsResult fn_draw_sphere(DsValue* a, int n) {
    DrawSphere(v3(a, 0), (float)arg(a, n, 3, 1), clr(a, n, 4));
    return ds_ok(api->mk_nil());
}
static DsResult fn_draw_plane(DsValue* a, int n) {
    RL_Vector2 sz = { (float)arg(a, n, 3, 10), (float)arg(a, n, 4, 10) };
    DrawPlane(v3(a, 0), sz, clr(a, n, 5));
    return ds_ok(api->mk_nil());
}
static DsResult fn_draw_grid(DsValue* a, int n) {
    DrawGrid((int)arg(a, n, 0, 10), (float)arg(a, n, 1, 1));
    return ds_ok(api->mk_nil());
}
static DsResult fn_draw_line_3d(DsValue* a, int n) {
    DrawLine3D(v3(a, 0), v3(a, 3), clr(a, n, 6));
    return ds_ok(api->mk_nil());
}
static DsResult fn_draw_cylinder(DsValue* a, int n) {
    DrawCylinder(v3(a, 0), (float)arg(a, n, 3, 1), (float)arg(a, n, 4, 1), (float)arg(a, n, 5, 1), (int)arg(a, n, 6, 16), clr(a, n, 7));
    return ds_ok(api->mk_nil());
}
static DsResult fn_draw_cylinder_wires(DsValue* a, int n) {
    DrawCylinderWires(v3(a, 0), (float)arg(a, n, 3, 1), (float)arg(a, n, 4, 1), (float)arg(a, n, 5, 1), (int)arg(a, n, 6, 16), clr(a, n, 7));
    return ds_ok(api->mk_nil());
}
static DsResult fn_draw_text(DsValue* a, int n) {
    const char* text = (n > 0 && api->is_str(a[0])) ? api->as_cstr(a[0]) : "";
    DrawText(text, (int)arg(a, n, 1, 0), (int)arg(a, n, 2, 0), (int)arg(a, n, 3, 20), clr(a, n, 4));
    return ds_ok(api->mk_nil());
}
static DsResult fn_draw_fps(DsValue* a, int n) {
    DrawFPS((int)arg(a, n, 0, 10), (int)arg(a, n, 1, 10));
    return ds_ok(api->mk_nil());
}
static DsResult fn_get_time(DsValue* a, int n) { return ds_ok(api->mk_num(GetTime())); }
static DsResult fn_get_frame_time(DsValue* a, int n) { return ds_ok(api->mk_num((double)GetFrameTime())); }
static DsResult fn_is_key_down(DsValue* a, int n) { return ds_ok(api->mk_bool(IsKeyDown((int)arg(a, n, 0, 0)))); }

void ds_init(DsApi* ap) {
    api = ap;
    api->register_fn("rl_init_window", fn_init_window);
    api->register_fn("rl_close_window", fn_close_window);
    api->register_fn("rl_window_should_close", fn_window_should_close);
    api->register_fn("rl_set_target_fps", fn_set_target_fps);
    api->register_fn("rl_is_window_ready", fn_is_window_ready);
    api->register_fn("rl_begin_drawing", fn_begin_drawing);
    api->register_fn("rl_end_drawing", fn_end_drawing);
    api->register_fn("rl_clear_background", fn_clear_background);
    api->register_fn("rl_begin_mode_3d", fn_begin_mode_3d);
    api->register_fn("rl_end_mode_3d", fn_end_mode_3d);
    api->register_fn("rl_draw_cube", fn_draw_cube);
    api->register_fn("rl_draw_cube_wires", fn_draw_cube_wires);
    api->register_fn("rl_draw_sphere", fn_draw_sphere);
    api->register_fn("rl_draw_plane", fn_draw_plane);
    api->register_fn("rl_draw_grid", fn_draw_grid);
    api->register_fn("rl_draw_line_3d", fn_draw_line_3d);
    api->register_fn("rl_draw_cylinder", fn_draw_cylinder);
    api->register_fn("rl_draw_cylinder_wires", fn_draw_cylinder_wires);
    api->register_fn("rl_draw_text", fn_draw_text);
    api->register_fn("rl_draw_fps", fn_draw_fps);
    api->register_fn("rl_get_time", fn_get_time);
    api->register_fn("rl_get_frame_time", fn_get_frame_time);
    api->register_fn("rl_is_key_down", fn_is_key_down);
}
