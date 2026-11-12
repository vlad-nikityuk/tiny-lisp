CC ?= cc
CFLAGS ?= -O2 -std=gnu11

tiny-lisp: src/lisp.c src/gc.c src/stdlib_native.c
	$(CC) $(CFLAGS) -o $@ src/lisp.c -lm

tiny-lisp-zig: src/zig/lisp.zig src/zig/gc.zig src/zig/stdlib_native.zig
	zig build-exe -OReleaseFast -lc src/zig/lisp.zig -femit-bin=$@

test: tiny-lisp
	python3 spec/repl.py ./tiny-lisp
	./tiny-lisp -f spec/specs.lisp
	@lines=$$(wc -l < src/lisp.c); [ $$lines -le 100 ] || { echo "src/lisp.c has $$lines lines (max 100)"; exit 1; }

test-zig: tiny-lisp-zig
	python3 spec/repl.py ./tiny-lisp-zig
	./tiny-lisp-zig -f spec/specs.lisp

asan:
	$(CC) -g -fsanitize=address -std=gnu11 -o tiny-lisp-asan src/lisp.c -lm

clean:
	rm -rf tiny-lisp tiny-lisp-asan tiny-lisp-asan.dSYM tiny-lisp-zig tiny-lisp-zig.o .zig-cache

.PHONY: test test-zig asan clean
