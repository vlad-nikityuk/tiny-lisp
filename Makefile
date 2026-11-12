tinylisp: $(wildcard src/*.zig)
	zig build-exe -OReleaseSafe -lc src/repl.zig -femit-bin=$@

fast: # no bounds or overflow checks, about 4% faster
	zig build-exe -OReleaseFast -lc src/repl.zig -femit-bin=tinylisp-fast

test: tinylisp
	python3 spec/repl.py ./tinylisp
	./tinylisp -f spec/specs.lisp

clean:
	rm -rf tinylisp tinylisp.o tinylisp-fast tinylisp-fast.o .zig-cache

.PHONY: fast test clean
