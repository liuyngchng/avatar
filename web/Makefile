.PHONY: build run clean mod

# Default target
build:
	go build -o avatar-server .

# Run (builds first)
run: build
	./avatar-server

# Update go.sum
mod:
	go mod tidy

# Clean
clean:
	rm -f avatar-server