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

# Build and run the raylib 3D demo
raylib: build-raylib-plugin
    ./build/engine run examples/raylib_demo.ds

# Build the raylib plugin dylib
build-raylib-plugin:
    cc -shared -o build/libraylib.dylib plugins/raylib/raylib.c \
        -I/opt/homebrew/include -L/opt/homebrew/lib -lraylib \
        -framework OpenGL -framework Cocoa -framework IOKit \
        -framework CoreAudio -framework CoreVideo
