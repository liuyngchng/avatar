.PHONY: all build avatar-ui avatar-pc run clean

# Default target
all: build

build: avatar-ui avatar-pc

# ── C UI program (GTK3 + WebKit2GTK) ──────────────────────────────
avatar-ui:
	gcc -O2 -o avatar-ui cmd/avatar-ui/main.c \
		$(shell pkg-config --cflags --libs gtk+-3.0 webkit2gtk-4.1)

# ── Go backend ────────────────────────────────────────────────────
avatar-pc:
	go build -o avatar-pc .

# ── Run (builds everything first) ─────────────────────────────────
run: build
	./avatar-pc

# ── Clean ─────────────────────────────────────────────────────────
clean:
	rm -f avatar-ui avatar-pc