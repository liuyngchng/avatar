.PHONY: build run clean mod

# Only obfuscate our own code, not dependencies
GOGARBLE  := github.com/liuyngchng/avatar-web
GOTOOLCHAIN := local
GOPROXY   := https://goproxy.cn,direct
GARBLE    := $(HOME)/go/bin/garble

# Default target (with garble obfuscation)
build:
	$(GARBLE) -literals -tiny build -o avatar-server .

# Plain build (no obfuscation, for debugging)
build-dev:
	go build -o avatar-server .

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