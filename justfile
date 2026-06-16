# Build targets
default: build

build:
    c3c build

build-release:
    c3c build release

# Run a .ds file
run file:
    ./build/engine run {{file}}

# Format a .ds file
fmt file:
    ./build/engine fmt {{file}}

# Run all tests
test:
    c3c test --test-noleak

# Run benchmarks
bench: build
    ./benchmarks/run.sh

# Build and run the todo TUI app (DS-scripted)
todo:
    c3c build todo && ./build/todo

# Build the todo host binary (needed for all DS examples below)
build-todo:
    c3c build todo

# DS example apps — each requires `just build-todo` first
counter: build-todo
    ./build/todo examples/counter.ds

spinner: build-todo
    ./build/todo examples/spinner.ds

progress: build-todo
    ./build/todo examples/progress.ds

tabs: build-todo
    ./build/todo examples/tabs.ds

timer: build-todo
    ./build/todo examples/timer.ds

repl: build-todo
    ./build/todo examples/repl.ds

snake: build-todo
    ./build/todo examples/snake.ds

# Run all DS examples in sequence (each must be quit with q)
examples: build-todo
    @echo "=== counter ===" && ./build/todo examples/counter.ds || true
    @echo "=== spinner ===" && ./build/todo examples/spinner.ds || true
    @echo "=== progress ===" && ./build/todo examples/progress.ds || true
    @echo "=== tabs ===" && ./build/todo examples/tabs.ds || true
    @echo "=== timer ===" && ./build/todo examples/timer.ds || true
    @echo "=== repl ===" && ./build/todo examples/repl.ds || true

# Build and run the raylib 3D demo
raylib: build-raylib-plugin
    ./build/engine run examples/raylib_demo.ds

# Build the raylib plugin dylib
build-raylib-plugin:
    cc -shared -o build/libraylib.dylib plugins/raylib/raylib.c \
        -I/opt/homebrew/include -L/opt/homebrew/lib -lraylib \
        -framework OpenGL -framework Cocoa -framework IOKit \
        -framework CoreAudio -framework CoreVideo
