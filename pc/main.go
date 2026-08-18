// Package main is the entry point for the Avatar PC application.
// It creates a window (WebView2 on Windows, Lorca on Linux) and
// loads the 3D digital human rendering page.
package main

import (
	"embed"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/liuyngchng/avatar-pc/internal/brain"
	"github.com/liuyngchng/avatar-pc/internal/renderer"
)

//go:embed web
var webAssets embed.FS

func main() {
	log.SetFlags(log.Ltime | log.Lshortfile)
	log.Println("Avatar PC starting...")

	// Create the renderer window (platform-specific).
	r, err := renderer.New(webAssets)
	if err != nil {
		log.Fatalf("Failed to create renderer: %v", err)
	}
	defer r.Close()

	// Create the brain (state machine).
	sm := brain.NewStateMachine()

	// Start the FSM loop.
	go sm.Run()

	// Handle incoming events from the renderer (user taps, etc.).
	go func() {
		for msg := range r.Events() {
			sm.HandleEvent(msg)
		}
	}()

	// Forward brain state changes to the renderer.
	go func() {
		for state := range sm.StateChanges() {
			r.SendMessage(state)
		}
	}()

	// Wait for SIGINT or SIGTERM.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	log.Println("Avatar PC shutting down...")
}