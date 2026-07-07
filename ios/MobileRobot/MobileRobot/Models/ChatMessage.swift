//
//  ChatMessage.swift
//  SiriApp
//
//  Ported from Android: ChatMessage.kt
//

import Foundation

struct ChatMessage: Identifiable, Codable {
    let id: String
    let role: Role
    let content: String
    let timestamp: Date

    enum Role: String, Codable {
        case user
        case assistant
        case system

        var value: String { rawValue }

        static func fromValue(_ value: String) -> Role {
            Role(rawValue: value) ?? .user
        }
    }

    init(id: String = UUID().uuidString,
         role: Role,
         content: String,
         timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}
