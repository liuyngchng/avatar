// Package main — custom slog handler that emits a compact, human-friendly
// one-line format:
//
//	2026-09-05T15:56:40.931+08:00 [INFO] tts_mode_offline_matcha key=value key=value
//
// This is used instead of slog's default TextHandler (which prefixes every
// field with time= / level= / msg=) to keep the log lines short and scannable
// while still carrying the level and structured attributes.
package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"runtime"
	"strconv"
	"sync"
)

// humanHandler implements slog.Handler with a compact single-line format.
type humanHandler struct {
	w         io.Writer
	mu        *sync.Mutex
	min       slog.Level
	addSource bool
}

// newHumanHandler returns a handler writing to w, emitting records at or
// above minLevel.
func newHumanHandler(w io.Writer, minLevel slog.Level) *humanHandler {
	if minLevel == 0 {
		minLevel = slog.LevelInfo
	}
	return &humanHandler{w: w, mu: &sync.Mutex{}, min: minLevel, addSource: true}
}

// Enabled reports whether the handler handles records at the given level.
func (h *humanHandler) Enabled(_ context.Context, level slog.Level) bool {
	return level >= h.min
}

// Handle formats a record as:
//
//	<time> [<LEVEL>] <file:line> <msg> <key>=<value> ...
func (h *humanHandler) Handle(_ context.Context, r slog.Record) error {
	buf := make([]byte, 0, 128)

	buf = append(buf, r.Time.Format("2006-01-02T15:04:05.000-07:00")...)
	buf = append(buf, " ["...)
	buf = append(buf, r.Level.String()...)
	buf = append(buf, "] "...)

	if h.addSource {
		buf = appendSource(buf)
	}

	buf = append(buf, r.Message...)

	r.Attrs(func(a slog.Attr) bool {
		buf = append(buf, ' ')
		buf = append(buf, a.Key...)
		buf = append(buf, '=')
		buf = appendValue(buf, a.Value)
		return true
	})

	buf = append(buf, '\n')

	h.mu.Lock()
	defer h.mu.Unlock()
	_, err := h.w.Write(buf)
	return err
}

// WithAttrs returns a new handler with the given attributes (we ignore them:
// this handler is used directly with no pre-attached attributes).
func (h *humanHandler) WithAttrs([]slog.Attr) slog.Handler { return h }

// WithGroup returns a new handler with the given group (groups are not used).
func (h *humanHandler) WithGroup(string) slog.Handler { return h }

// appendValue renders a slog value, quoting only when necessary.
func appendValue(buf []byte, v slog.Value) []byte {
	return appendQuoted(buf, valueString(v))
}

// valueString renders a slog value to its plain string form.
func valueString(v slog.Value) string {
	if v.Kind() == slog.KindAny {
		a := v.Any()
		if a == nil {
			return "<nil>"
		}
		if err, ok := a.(error); ok {
			return err.Error()
		}
		return fmt.Sprint(a)
	}
	return v.String()
}

// appendQuoted appends s to buf, quoting it when it contains characters that
// would make the line ambiguous (spaces, '=', quotes, etc.).
func appendQuoted(buf []byte, s string) []byte {
	if !needsQuoting(s) {
		return append(buf, s...)
	}
	return strconv.AppendQuote(buf, s)
}

// needsQuoting reports whether s must be quoted to stay unambiguous in the
// key=value output.
func needsQuoting(s string) bool {
	if s == "" {
		return true
	}
	for _, r := range s {
		if r <= ' ' || r == '=' || r == '"' || r == '\'' || r == '\\' || r == '[' || r == ']' {
			return true
		}
	}
	return false
}

// appendSource walks the call stack to find the caller of slog.Info/Warn/Error
// and appends "file:line " to buf.  When garble strips source paths, this
// produces "?:1 "; when built with `go build` (no obfuscation), it gives the
// real file name and line.
//
// We capture a few frames from within Handle and skip over the log/slog
// package (and this file) so inlining of slog.Info/Logger.Info can't shift
// the result off by a frame.
func appendSource(buf []byte) []byte {
	var pcs [8]uintptr
	n := runtime.Callers(3, pcs[:])
	frames := runtime.CallersFrames(pcs[:n])

	for {
		frame, more := frames.Next()
		// Skip the log/slog package and our own log.go helper.
		if isLoggingPackage(frame.File) {
			if !more {
				break
			}
			continue
		}
		buf = appendFileLine(buf, frame.File, frame.Line)
		return buf
	}
	return append(buf, "?:? "...)
}

// isLoggingPackage reports whether the file belongs to the logging machinery
// itself (the standard log/slog package or our own log.go).
func isLoggingPackage(file string) bool {
	// Match "log/slog/" anywhere in the path (covers the stdlib), plus the
	// bare "log.go" file in this package.
	if len(file) >= 5 && file[len(file)-5:] == "log.go" {
		return true
	}
	for i := 0; i+8 <= len(file); i++ {
		if file[i:i+8] == "log/slog" {
			return true
		}
	}
	return false
}

// appendFileLine appends "<basename>:<line> " to buf.
func appendFileLine(buf []byte, file string, line int) []byte {
	// Strip leading path segments, keep only the basename.
	short := file
	for i := len(short) - 1; i >= 0; i-- {
		if short[i] == '/' {
			short = short[i+1:]
			break
		}
	}
	buf = append(buf, short...)
	buf = append(buf, ':')
	buf = strconv.AppendInt(buf, int64(line), 10)
	buf = append(buf, ' ')
	return buf
}
