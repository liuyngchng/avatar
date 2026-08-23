package renderer

import (
	"embed"
	"io/fs"

	"github.com/liuyngchng/avatar-desktop/internal/brain"
)

// Renderer is the platform-neutral window host interface.
type Renderer interface {
	SendMessage(msg any)
	Events() <-chan brain.Event
	Run() // blocks until the window closes (GTK main loop on Linux, no-op on Windows)
	Close()
}

// New creates a platform-specific renderer that serves the embedded
// web/ assets and opens a window to display the 3D digital human.
// enableFBX controls whether the frontend loads FBX animations.
func New(assets embed.FS, enableFBX bool) (Renderer, error) {
	webFS, err := fs.Sub(assets, "web")
	if err != nil {
		return nil, err
	}
	return newPlatformRenderer(webFS, enableFBX)
}