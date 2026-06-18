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
    c3c build ds && ./build/ds example/todo/todo.ds

# Build the ds-run host binary
build-ds:
    c3c build ds

# Run any .ds file: just ds <file>
ds file: build-ds
    ./build/ds {{file}}

# DS example apps
counter: build-ds
    ./build/ds examples/counter.ds

spinner: build-ds
    ./build/ds examples/spinner.ds

progress: build-ds
    ./build/ds examples/progress.ds

tabs: build-ds
    ./build/ds examples/tabs.ds

timer: build-ds
    ./build/ds examples/timer.ds

repl: build-ds
    ./build/ds examples/repl.ds

snake: build-ds
    ./build/ds examples/snake.ds

# Run all DS examples in sequence (each must be quit with q)
examples: build-ds
    @echo "=== counter ===" && ./build/ds examples/counter.ds || true
    @echo "=== spinner ===" && ./build/ds examples/spinner.ds || true
    @echo "=== progress ===" && ./build/ds examples/progress.ds || true
    @echo "=== tabs ===" && ./build/ds examples/tabs.ds || true
    @echo "=== timer ===" && ./build/ds examples/timer.ds || true
    @echo "=== repl ===" && ./build/ds examples/repl.ds || true

# Build and run the raylib 3D demo
raylib: build-raylib-plugin
    ./build/engine run examples/raylib_demo.ds

# Build the raylib plugin dylib
build-raylib-plugin:
    cc -shared -o build/libraylib.dylib plugins/raylib/raylib.c \
        -I/opt/homebrew/include -L/opt/homebrew/lib -lraylib \
        -framework OpenGL -framework Cocoa -framework IOKit \
        -framework CoreAudio -framework CoreVideo
