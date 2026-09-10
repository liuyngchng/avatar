//
//  ChatSession.swift
//  SiriApp
//
//  Multi-turn conversation manager. Keeps last MAX_HISTORY messages.
//  Ported from Android: ChatSession.kt
//

import Foundation
import Combine

class ChatSession: ObservableObject {
    /// Messages shown on screen — capped at maxScreenMessages.
    @Published private(set) var messages: [ChatMessage] = []

    /// LLM context buffer — preserved across screen clears so the model
    /// remembers previous turns. Never cleared except by user action.
    private var contextBuffer: [ChatMessage] = []

    /// Maximum messages shown on screen (older messages are trimmed).
    private let maxScreenMessages: Int

    /// Context window for LLM — last N messages from the full context buffer.
    private var contextMessages: [ChatMessage] {
        Array(contextBuffer.suffix(maxHistory))
    }

    private let llmClient: LlmClient
    private let maxHistory: Int
    private var cancellables = Set<AnyCancellable>()

    init(llmClient: LlmClient, maxHistory: Int = 20, maxScreenMessages: Int = 20) {
        self.llmClient = llmClient
        self.maxHistory = maxHistory
        self.maxScreenMessages = maxScreenMessages
    }

    /// Send message (non-streaming)
    func send(_ text: String) -> AnyPublisher<String, Error> {
        let userMsg = ChatMessage(role: .user, content: text)
        appendToScreen(userMsg)
        contextBuffer.append(userMsg)

        return llmClient.chat(messages: contextMessages)
            .handleEvents(receiveOutput: { [weak self] reply in
                let assistantMsg = ChatMessage(role: .assistant, content: reply)
                self?.appendToScreen(assistantMsg)
                self?.contextBuffer.append(assistantMsg)
            }, receiveCompletion: { [weak self] completion in
                if case .failure = completion {
                    self?.messages.removeLast()
                    self?.contextBuffer.removeLast()
                }
            })
            .eraseToAnyPublisher()
    }

    /// Send message with streaming (iOS 14+)
    func sendStream(_ text: String) -> AnyPublisher<AnyPublisher<String, Error>, Error> {
        sendStreamInternal(text, appendUser: true)
    }

    /// Streaming send without appending the user message — used for LLM
    /// retries so the message doesn't end up twice in the context.
    func sendStreamNoAppend(_ text: String) -> AnyPublisher<AnyPublisher<String, Error>, Error> {
        sendStreamInternal(text, appendUser: false)
    }

    private func sendStreamInternal(
        _ text: String, appendUser: Bool
    ) -> AnyPublisher<AnyPublisher<String, Error>, Error> {
        if appendUser {
            appendUserMessage(text)
        }

        let streamPublisher = llmClient.chatStreamPublisher(messages: contextMessages)
        return Just(streamPublisher)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }

    /// Append a user message to the context buffer (with a date hint on the
    /// first message) WITHOUT sending a request. Used by the retry flow so
    /// the user's utterance is persisted before any LLM call is attempted —
    /// a subsequent retry (appendUser: false) then still has full context.
    func appendUserMessage(_ text: String) {
        let content = contextBuffer.isEmpty
            ? LlmClient.dateHint() + " " + text
            : text
        let userMsg = ChatMessage(role: .user, content: content)
        appendToScreen(userMsg)
        contextBuffer.append(userMsg)
    }

    /// Save assistant reply to history (called after streaming completes)
    func appendAssistantReply(_ text: String) {
        guard text.isNotBlank else { return }
        let msg = ChatMessage(role: .assistant, content: text)
        appendToScreen(msg)
        contextBuffer.append(msg)
    }

    /// Append a message to the on-screen list, trimming to maxScreenMessages.
    private func appendToScreen(_ msg: ChatMessage) {
        messages.append(msg)
        if messages.count > maxScreenMessages {
            messages = Array(messages.suffix(maxScreenMessages))
        }
    }

    /// Clear screen only — LLM context is preserved.
    func clearScreen() {
        messages = []
    }

    /// Full clear — both screen and LLM context (user-initiated).
    func clear() {
        messages = []
        contextBuffer = []
    }

    var messageCount: Int {
        messages.count
    }
}
