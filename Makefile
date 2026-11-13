BINARY ?= ./tinylisp
BUILD = zig build-exe -OReleaseSafe -lc

tinylisp: $(wildcard src/*.zig src/*/*.zig)
	$(BUILD) src/repl.zig -femit-bin=$@

fast: # no bounds or overflow checks, about 4% faster
	zig build-exe -OReleaseFast -lc src/repl.zig -femit-bin=tinylisp-fast

test: $(BINARY)
	python3 spec/tools.py "$(BINARY)"
	python3 spec/repl.py "$(BINARY)"
	"$(BINARY)" -f spec/specs.lisp

# The same tests on a variant of the interpreter: a copy of src/ with one constant changed ($(1): name, $(2): file,
# $(3): the text, $(4): what replaces it). cmp makes sure that the text was there.
define test-variant
	rm -rf .variants/$(1) && mkdir -p .variants && cp -r src .variants/$(1)
	sed -i.bak 's/$(3)/$(4)/' .variants/$(1)/$(2)
	! cmp -s src/$(2) .variants/$(1)/$(2)
	$(BUILD) .variants/$(1)/repl.zig -femit-bin=.variants/tinylisp-$(1)
	$(MAKE) test BINARY=.variants/tinylisp-$(1)
endef

test-tree: # the bytecode tier off: the tree evaluator runs everything, and must give the same results
	$(call test-variant,tree,bytecode.zig,const enabled = true;,const enabled = false;)

test-gc: # a collection after every 2 KB allocated: whatever the collector cannot reach from a root is freed at once
	$(call test-variant,gc,runtime/gc.zig,2 << 20,2048)

bench: $(BINARY) # tinylisp against CPython on bench/*, e.g. make bench ARGS="-n 1 nbody life"
	python3 bench/run.py --binary "$(BINARY)" $(ARGS)

clean:
	rm -rf tinylisp tinylisp.o tinylisp-fast tinylisp-fast.o .zig-cache .variants

.PHONY: fast test test-tree test-gc bench clean
