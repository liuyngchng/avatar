//
//  VisemeGenerator.swift
//  Avatar
//
//  Ported from desktop/internal/brain/viseme.go.
//  Generates the viseme timeline that drives the VRM mouth while speaking.
//

import Foundation

/// VRM1 viseme (mouth shape) names.
enum VisemeName: String {
    case a    = "aa"   // big open mouth
    case i    = "ih"   // wide grin
    case u    = "ou"   // rounded lips
    case e    = "ee"   // half open
    case o    = "oh"   // rounded wide
    case rest = "rest" // closed mouth (reset all visemes to 0)
}

/// One entry in the viseme timeline.
struct VisemeTimelineEntry: Codable {
    let viseme: String
    let startMs: Int
}

/// Full viseme timeline sent to the WebView frontend.
struct VisemeTimeline: Codable {
    let type: String
    let timeline: [VisemeTimelineEntry]

    init(timeline: [VisemeTimelineEntry]) {
        self.type = "viseme_timeline"
        self.timeline = timeline
    }

    var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
}

enum VisemeGenerator {
    private static let mouthVisemes: [VisemeName] = [.a, .i, .u, .e, .o]

    /// Generate a viseme timeline that cycles through random mouth shapes for
    /// the full audio duration. Every `mouthStepMs` we pick a random mouth
    /// shape, with a ~20% chance of a closed-mouth (rest) frame.
    static func generateTimeline(text: String, audioDurationMs: Int) -> VisemeTimeline? {
        guard audioDurationMs > 0 else { return nil }

        let mouthStepMs = 120
        var entries: [VisemeTimelineEntry] = []
        entries.reserveCapacity(audioDurationMs / mouthStepMs + 2)

        var currentMs = 0
        while currentMs < audioDurationMs {
            let viseme: VisemeName
            if Int.random(in: 0..<5) == 0 {
                viseme = .rest
            } else {
                viseme = mouthVisemes[Int.random(in: 0..<mouthVisemes.count)]
            }
            entries.append(VisemeTimelineEntry(viseme: viseme.rawValue, startMs: currentMs))
            currentMs += mouthStepMs
        }

        return VisemeTimeline(timeline: entries)
    }
}