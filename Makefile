tiny-lisp: src/repl.zig src/lang.zig src/gc.zig src/stdlib_native.zig
	zig build-exe -OReleaseFast -lc src/repl.zig -femit-bin=$@

safe: # bounds and overflow checks on
	zig build-exe -OReleaseSafe -lc src/repl.zig -femit-bin=tiny-lisp-safe

test: tiny-lisp
	python3 spec/repl.py ./tiny-lisp
	./tiny-lisp -f spec/specs.lisp

clean:
	rm -rf tiny-lisp tiny-lisp.o tiny-lisp-safe tiny-lisp-safe.o .zig-cache

.PHONY: safe test clean
