BINARY ?= ./tinylisp
BUILD = zig build-exe -OReleaseSafe -lc
ZIG_SRC = $(shell find src -name '*.zig')

tinylisp: $(ZIG_SRC)
	$(BUILD) src/repl.zig -femit-bin=$@

# A copy of src/ with one constant changed ($(1): name, $(2): file, $(3): find, $(4): replace).
# cmp makes sure the patch applied.
define test-variant
	rm -rf .variants/$(1) && mkdir -p .variants && cp -r src .variants/$(1)
	sed -i.bak 's/$(3)/$(4)/' .variants/$(1)/$(2)
	! cmp -s src/$(2) .variants/$(1)/$(2)
	$(BUILD) .variants/$(1)/repl.zig -femit-bin=.variants/tinylisp-$(1)
endef

define run-tests
	python3 spec/tools.py "$(1)"
	python3 spec/repl.py "$(1)"
	"$(1)" -f spec/specs.lisp
	"$(1)" -f spec/top-level-rebind.lisp
	"$(1)" -f spec/body-scope.lisp
	"$(1)" -f examples/microgpt.lisp | cmp -s - spec/microgpt.expected
endef

test: $(BINARY)
	$(call run-tests,$(BINARY))
	@$(MAKE) .test-gc

.test-gc:
	$(call test-variant,gc,runtime/gc.zig,2 << 20,2048)
	$(call run-tests,.variants/tinylisp-gc)

bench: $(BINARY)
	python3 bench/run.py --binary "$(BINARY)" $(ARGS)

lint:
	zig fmt --check src/
	@for f in $(ZIG_SRC); do zig ast-check $$f || exit 1; done
	python3 spec/repo_rules.py

check-all: test lint

fmt:
	zig fmt src/

clean:
	rm -rf tinylisp tinylisp.o tinylisp-fast tinylisp-fast.o .zig-cache .variants

fast:
	zig build-exe -OReleaseFast -lc src/repl.zig -femit-bin=tinylisp-fast

.PHONY: test .test-gc bench lint check-all fmt clean fast