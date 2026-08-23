.PHONY: all build avatar-ui avatar-desktop run clean

# Default target
all: build

build: avatar-ui avatar-desktop

# ── C UI program (GTK3 + WebKit2GTK) ──────────────────────────────
avatar-ui:
	gcc -O2 -o avatar-ui cmd/avatar-ui/main.c \
		$(shell pkg-config --cflags --libs gtk+-3.0 webkit2gtk-4.1)

# ── Go backend ────────────────────────────────────────────────────
avatar-desktop:
	go build -o avatar-desktop .

# ── Run (builds everything first) ─────────────────────────────────
run: build
	./avatar-desktop

# ── Clean ─────────────────────────────────────────────────────────
clean:
	rm -f avatar-ui avatar-desktop