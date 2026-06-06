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
