// Package brain contains the state machine and the digital human's
// "mind": mode FSM, emotion mapping, and viseme generation.
//
// This file generates the viseme timeline that drives the mouth while
// speaking. We deliberately do NOT try to align mouth shapes with the
// actual spoken text — the Matcha-TTS engine does not expose per-phoneme
// timestamps, so any alignment would be a rough guess. Instead we cycle
// through random mouth shapes so the lips read as "talking".
package brain

import "math/rand"

// VisemeName is a VRM1 viseme (mouth shape) name.
type VisemeName string

const (
	VisemeA    VisemeName = "aa"   // big open mouth
	VisemeI    VisemeName = "ih"   // wide grin
	VisemeU    VisemeName = "ou"   // rounded lips
	VisemeE    VisemeName = "ee"   // half open
	VisemeO    VisemeName = "oh"   // rounded wide
	VisemeRest VisemeName = "rest" // closed mouth (reset all visemes to 0)
)

// mouthVisemes are the shapes we cycle through while speaking.
var mouthVisemes = []VisemeName{VisemeA, VisemeI, VisemeU, VisemeE, VisemeO}

// VisemeEvent is a viseme instruction sent to the renderer.
type VisemeEvent struct {
	Type   string     `json:"type"`
	Viseme VisemeName `json:"viseme"`
	Weight float64    `json:"weight"`
}

// VisemeTimelineEntry is a single entry in the viseme timeline.
type VisemeTimelineEntry struct {
	Viseme  VisemeName `json:"viseme"`  // VRM viseme name
	StartMs int        `json:"startMs"` // start time in milliseconds
}

// VisemeTimeline is the full viseme timeline sent to the frontend.
type VisemeTimeline struct {
	Type     string                `json:"type"`
	Timeline []VisemeTimelineEntry `json:"timeline"`
}

// GenerateVisemeTimeline creates a viseme timeline that cycles through
// random mouth shapes for the full audio duration. Every mouthStepMs we
// pick a random mouth shape, with a ~20% chance of a closed-mouth (rest)
// frame so the lips open and close naturally instead of staying frozen
// open.
func GenerateVisemeTimeline(text string, audioDurationMs int) *VisemeTimeline {
	if audioDurationMs <= 0 {
		return nil
	}

	const mouthStepMs = 120

	entries := make([]VisemeTimelineEntry, 0, audioDurationMs/mouthStepMs+2)
	for currentMs := 0; currentMs < audioDurationMs; currentMs += mouthStepMs {
		var viseme VisemeName
		if rand.Intn(5) == 0 {
			// Briefly close the mouth for an open/close rhythm.
			viseme = VisemeRest
		} else {
			viseme = mouthVisemes[rand.Intn(len(mouthVisemes))]
		}

		entries = append(entries, VisemeTimelineEntry{
			Viseme:  viseme,
			StartMs: currentMs,
		})
	}

	return &VisemeTimeline{
		Type:     "viseme_timeline",
		Timeline: entries,
	}
}
