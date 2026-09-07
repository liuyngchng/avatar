.PHONY: build run clean mod package

# Release package name (e.g. avatar-server-linux-amd64.tar.gz)
VERSION  ?= $(shell date +%Y%m%d)
DISTNAME := avatar-server-linux-amd64-$(VERSION)
PKG      := $(DISTNAME).tar

# Fail fast if go is missing
ifeq ($(shell command -v go),)
$(error "Go not found in PATH")
endif

export GOTOOLCHAIN  := local
export GOGARBLE     := github.com/liuyngchng/avatar-web
export GOPROXY      := https://goproxy.cn,direct

GARBLE := $(HOME)/go/bin/garble

# Sherpa-onnx shared libraries — bundled into lib/ so the binary is portable.
SHERPA_LIB_DIR  := $(shell go list -m -f '{{.Dir}}' github.com/k2-fsa/sherpa-onnx-go-linux 2>/dev/null)/lib/x86_64-unknown-linux-gnu
SHERPA_LIBS     := libsherpa-onnx-c-api.so libonnxruntime.so libsherpa-onnx-cxx-api.so

# Append $ORIGIN/lib to the RUNPATH set by the sherpa-onnx package.
# This way the binary looks for .so files next to itself (lib/) first,
# and falls back to the Go module cache on the build machine.
export CGO_LDFLAGS = -Wl,-rpath,$$ORIGIN/lib

# Default target (with garble obfuscation + JS obfuscation)
build: obfuscate-js $(GARBLE)
	$(GARBLE) -literals -tiny build -o avatar-server .
	$(MAKE) copy-libs

# ── JS obfuscation (our own code only, third-party libs untouched) ──
# Uses javascript-obfuscator in light mode: string-array + rename, no
# control-flow flattening so it won't hurt animation-loop performance.
obfuscate-js:
	@echo "Obfuscating app.js..."
	npx --yes javascript-obfuscator web/js/app.js \
	  --output web/js/app.min.js \
	  --string-array true \
	  --string-array-encoding base64 \
	  --identifier-names-generator hexadecimal

# Plain build (no obfuscation, for debugging) — copies app.js directly
# so you can set breakpoints and read the source in devtools.
build-dev:
	cp web/js/app.js web/js/app.min.js
	go build -o avatar-server .
	$(MAKE) copy-libs

# Copy sherpa-onnx .so files into lib/ next to the binary.
# Run avatar-server with:  LD_LIBRARY_PATH=./lib ./avatar-server
# or just: ./avatar-server  (RUNPATH already includes $ORIGIN/lib)
copy-libs:
	@mkdir -p lib
	@for f in $(SHERPA_LIBS); do \
		cp -fv "$(SHERPA_LIB_DIR)/$$f" lib/; \
	done
	@echo "lib/ ready — copy it alongside avatar-server on the target machine."

# One-shot garble install target
$(GARBLE):
	@echo "garble not found, installing..."
	go install mvdan.cc/garble@v0.14.2

# Run (builds first)
run: build
	./avatar-server

# Run dev (no obfuscation)
run-dev: build-dev
	./avatar-server

# Update go.sum
mod:
	go mod tidy

# Package: build + bundle libs & models into a single tar.gz for distribution.
# On the target machine:  tar xzf <pkg>.tar.gz && cd <pkg> && ./avatar-server
package: build
	@rm -rf $(DISTNAME)
	mkdir -p $(DISTNAME)
	cp -a avatar-server $(DISTNAME)/
	cp -a lib $(DISTNAME)/
	cp -aL models $(DISTNAME)/
	tar chf $(PKG) $(DISTNAME)
	rm -rf $(DISTNAME)
	@echo ""
	@echo "Package ready: $(PKG)"
	@echo "Copy to target machine and run:"
	@echo "  tar xf $(PKG) && cd $(DISTNAME) && ./avatar-server"

# Clean
clean:
	rm -rf avatar-server lib $(DISTNAME) $(PKG) web/js/app.min.js