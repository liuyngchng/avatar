.PHONY: build run clean mod

# Fail fast if go is missing
ifeq ($(shell command -v go),)
$(error "Go not found in PATH")
endif

export GOTOOLCHAIN  := local
export GOGARBLE     := github.com/liuyngchng/avatar-web
export GOPROXY      := https://goproxy.cn,direct

GARBLE := $(HOME)/go/bin/garble

# Default target (with garble obfuscation); auto-installs garble if missing
build: $(GARBLE)
	$(GARBLE) -literals -tiny build -o avatar-server .

# Plain build (no obfuscation, for debugging)
build-dev:
	go build -o avatar-server .

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

# Clean
clean:
	rm -f avatar-server