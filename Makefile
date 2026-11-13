BINARY ?= ./tinylisp

tinylisp: $(wildcard src/*.zig)
	zig build-exe -OReleaseSafe -lc src/repl.zig -femit-bin=$@

fast: # no bounds or overflow checks, about 4% faster
	zig build-exe -OReleaseFast -lc src/repl.zig -femit-bin=tinylisp-fast

test: $(BINARY)
	python3 spec/tools.py "$(BINARY)"
	python3 spec/repl.py "$(BINARY)"
	"$(BINARY)" -f spec/specs.lisp

bench: $(BINARY) # tinylisp against CPython on bench/*, e.g. make bench ARGS="-n 1 nbody life"
	python3 bench/run.py --binary "$(BINARY)" $(ARGS)

clean:
	rm -rf tinylisp tinylisp.o tinylisp-fast tinylisp-fast.o .zig-cache

.PHONY: fast test bench clean
