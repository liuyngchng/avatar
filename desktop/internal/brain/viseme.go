// Package brain contains the state machine and the digital human's
// "mind": mode FSM, emotion mapping, and viseme generation.
//
// This file implements the Chinese pinyin → VRM viseme mapping and
// timeline generation for lip-sync.
package brain

import (
	"strings"
	"unicode"

	"github.com/mozillazg/go-pinyin"
)

// VisemeName is a VRM1 viseme (mouth shape) name.
type VisemeName string

const (
	VisemeA  VisemeName = "aa" // big open mouth
	VisemeI  VisemeName = "ih" // wide grin
	VisemeU  VisemeName = "ou" // rounded lips
	VisemeE  VisemeName = "ee" // half open
	VisemeO  VisemeName = "oh" // rounded wide
	VisemeRest VisemeName = "rest" // closed mouth (reset all visemes to 0)
)

// VisemeEvent is a viseme instruction sent to the renderer.
type VisemeEvent struct {
	Type   string     `json:"type"`
	Viseme VisemeName `json:"viseme"`
	Weight float64    `json:"weight"`
}

// finalToViseme maps Chinese finals (韵母) to VRM visemes.
// Based on the README table.
var finalToViseme = map[string]VisemeName{
	// A group: a, ai, an, ang, ia, ua, iao, uan, iang
	"a":    VisemeA,
	"ai":   VisemeA,
	"an":   VisemeA,
	"ang":  VisemeA,
	"ia":   VisemeA,
	"ua":   VisemeA,
	"iao":  VisemeA,
	"uan":  VisemeA,
	"iang": VisemeA,

	// I group: i, ei, in, ing, ui, iu, ian
	"i":   VisemeI,
	"ei":  VisemeI,
	"in":  VisemeI,
	"ing": VisemeI,
	"ui":  VisemeI,
	"iu":  VisemeI,
	"ian": VisemeI,

	// U group: u, ou, ong, ü, un, iong
	"u":    VisemeU,
	"ou":   VisemeU,
	"ong":  VisemeU,
	"v":    VisemeU, // ü (go-pinyin uses 'v' for ü)
	"ue":   VisemeU, // üe
	"un":   VisemeU,
	"iong": VisemeU,

	// E group: e, ie, üe, er, en, eng, uen
	"e":   VisemeE,
	"ie":  VisemeE,
	"er":  VisemeE,
	"en":  VisemeE,
	"eng": VisemeE,
	"uen": VisemeE,

	// O group: o, uo, ao
	"o":  VisemeO,
	"uo": VisemeO,
	"ao": VisemeO,
}

// bilabialInitials are consonants that produce a closed-mouth shape ONLY
// at the very start of the syllable. The viseme for the full character
// should be determined by the final (韵母), not the initial, so we no
// longer force VisemeRest for bilabial initials. This map is kept as
// reference but is not currently used.
var bilabialInitials = map[string]bool{
	"b": true,
	"p": true,
	"m": true,
}

// GetViseme returns the VRM viseme for a Chinese character's pinyin.
// If the character is not a Chinese character (punctuation, space, etc.),
// returns VisemeRest.
func GetViseme(char rune) VisemeName {
	// Non-Chinese characters: return rest (closed mouth).
	if !unicode.Is(unicode.Han, char) {
		return VisemeRest
	}

	// Get pinyin with tone marks (e.g. "nǐ")
	a := pinyin.NewArgs()
	a.Style = pinyin.Tone
	py := pinyin.SinglePinyin(char, a)
	if len(py) == 0 {
		return VisemeRest
	}

	// Strip tone number/diacritic to get the base syllable.
	base := stripTone(py[0])

	// Look up the final (韵母) to determine the mouth shape. The initial
	// (声母) is ignored — the final determines the sustained mouth shape,
	// which is what the viseme should reflect.
	_, final := splitInitialFinal(base)

	// Look up the final.
	if viseme, ok := finalToViseme[final]; ok {
		return viseme
	}

	// Fallback: try to determine by the final's first character.
	if len(final) > 0 {
		for k, v := range finalToViseme {
			if strings.HasPrefix(final, k) {
				return v
			}
		}
	}

	return VisemeA // default to open mouth
}

// VisemeTimelineEntry is a single entry in the viseme timeline.
type VisemeTimelineEntry struct {
	Char    string     `json:"char"`    // the Chinese character
	Viseme  VisemeName `json:"viseme"`  // VRM viseme name
	StartMs int        `json:"startMs"` // start time in milliseconds
}

// VisemeTimeline is the full viseme timeline sent to the frontend.
type VisemeTimeline struct {
	Type     string                `json:"type"`
	Timeline []VisemeTimelineEntry `json:"timeline"`
}

// GenerateVisemeTimeline creates a viseme timeline from text and audio duration.
// Uses the "even distribution" approach (方案A): total duration ÷ number of
// Chinese characters, with punctuation getting shorter pauses.
func GenerateVisemeTimeline(text string, audioDurationMs int) *VisemeTimeline {
	chars := []rune(text)
	if len(chars) == 0 {
		return nil
	}

	// Count Chinese characters (hanzi) for time distribution.
	hanziCount := 0
	for _, c := range chars {
		if unicode.Is(unicode.Han, c) {
			hanziCount++
		}
	}
	if hanziCount == 0 {
		return nil
	}

	totalMs := audioDurationMs
	// Punctuation gets a shorter slot (1/3 of a hanzi slot).
	punctuationCount := len(chars) - hanziCount
	effectiveSlots := float64(hanziCount) + float64(punctuationCount)/3.0
	hanziSlotMs := float64(totalMs) / effectiveSlots
	punctuationSlotMs := hanziSlotMs / 3.0

	entries := make([]VisemeTimelineEntry, 0, len(chars))
	currentMs := 0.0

	for _, c := range chars {
		var slotMs float64
		var viseme VisemeName

		if unicode.Is(unicode.Han, c) {
			slotMs = hanziSlotMs
			viseme = GetViseme(c)
		} else {
			slotMs = punctuationSlotMs
			viseme = VisemeRest
		}

		entries = append(entries, VisemeTimelineEntry{
			Char:    string(c),
			Viseme:  viseme,
			StartMs: int(currentMs),
		})
		currentMs += slotMs
	}

	return &VisemeTimeline{
		Type:     "viseme_timeline",
		Timeline: entries,
	}
}

// stripTone removes tone digits and diacritics from a pinyin syllable.
// e.g. "nǐ" → "ni", "hǎo" → "hao", "nǚ" → "nv"
func stripTone(py string) string {
	// Remove tone numbers (e.g. "ni3" → "ni")
	result := strings.TrimRight(py, "0123456789")

	// Remove tone diacritics by mapping to base letters.
	toneMap := map[rune]rune{
		'ā': 'a', 'á': 'a', 'ǎ': 'a', 'à': 'a',
		'ē': 'e', 'é': 'e', 'ě': 'e', 'è': 'e',
		'ī': 'i', 'í': 'i', 'ǐ': 'i', 'ì': 'i',
		'ō': 'o', 'ó': 'o', 'ǒ': 'o', 'ò': 'o',
		'ū': 'u', 'ú': 'u', 'ǔ': 'u', 'ù': 'u',
		'ǖ': 'v', 'ǘ': 'v', 'ǚ': 'v', 'ǜ': 'v',
		'ü': 'v',
	}

	var sb strings.Builder
	for _, r := range result {
		if mapped, ok := toneMap[r]; ok {
			sb.WriteRune(mapped)
		} else {
			sb.WriteRune(r)
		}
	}
	return sb.String()
}

// splitInitialFinal splits a pinyin syllable into initial (声母) and final (韵母).
// e.g. "hao" → ("h", "ao"), "ni" → ("n", "i"), "a" → ("", "a")
//
// y/w are NOT real initials — they mark zero-initial syllables. They are
// folded back into the final by restoring the medial vowel, so the final
// correctly maps to a viseme (e.g. "yao" → final "iao", not "ao").
func splitInitialFinal(py string) (initial, final string) {
	// Multi-char initials: zh, ch, sh.
	if len(py) >= 2 && (py[:2] == "zh" || py[:2] == "ch" || py[:2] == "sh") {
		return py[:2], py[2:]
	}

	// y → restore i / ü medial.
	if strings.HasPrefix(py, "y") {
		rest := py[1:]
		switch rest {
		case "i":
			return "", "i" // yi
		case "in":
			return "", "in" // yin
		case "ing":
			return "", "ing" // ying
		case "ou":
			return "", "iu" // you
		case "u":
			return "", "v" // yu (ü)
		case "ue":
			return "", "ue" // yue (üe)
		case "un":
			return "", "un" // yun (ün)
		case "ong":
			return "", "iong" // yong
		}
		return "", "i" + rest // ya→ia, yan→ian, yao→iao, yang→iang, ye→ie
	}

	// w → restore u medial.
	if strings.HasPrefix(py, "w") {
		rest := py[1:]
		switch rest {
		case "u":
			return "", "u" // wu
		case "ei":
			return "", "ui" // wei
		}
		return "", "u" + rest // wa→ua, wo→uo, wan→uan, wen→uen
	}

	// Single-char initials.
	singleInitials := []string{"b", "p", "m", "f", "d", "t", "n", "l",
		"g", "k", "h", "j", "q", "x", "r", "z", "c", "s"}
	for _, ini := range singleInitials {
		if strings.HasPrefix(py, ini) {
			return ini, py[len(ini):]
		}
	}
	return "", py
}