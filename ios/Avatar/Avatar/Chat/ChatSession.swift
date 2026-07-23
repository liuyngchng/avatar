//
//  ChatSession.swift
//  SiriApp
//
//  Multi-turn conversation manager. Keeps last MAX_HISTORY messages.
//  Integrates knowledge base retrieval before LLM calls.
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

    /// Knowledge base manager for retrieving relevant company info.
    private let kbManager = KnowledgeBaseManager()

    /// Config repository for reading LLM config (used by embedding API).
    private let configRepo: ConfigRepository

    init(llmClient: LlmClient, configRepo: ConfigRepository = ConfigRepository(), maxHistory: Int = 20, maxScreenMessages: Int = 20) {
        self.llmClient = llmClient
        self.configRepo = configRepo
        self.maxHistory = maxHistory
        self.maxScreenMessages = maxScreenMessages
        // Load knowledge base if present
        kbManager.loadIfExists()
    }

    /// Send message (non-streaming)
    func send(_ text: String) -> AnyPublisher<String, Error> {
        let userMsg = ChatMessage(role: .user, content: text)
        appendToScreen(userMsg)
        contextBuffer.append(userMsg)

        return Future<String, Error> { [weak self] promise in
            guard let self = self else { return }
            Task {
                let (kbContext, historyStr) = await self.preparePromptContext(for: text)
                let publisher = self.llmClient.chat(
                    messages: self.contextMessages,
                    knowledgeContext: kbContext,
                    chatHistory: historyStr
                )
                var cancellable: AnyCancellable?
                cancellable = publisher
                    .sink(
                        receiveCompletion: { completion in
                            if case .failure(let error) = completion {
                                _ = self.messages.popLast()
                                _ = self.contextBuffer.popLast()
                                promise(.failure(error))
                            }
                            _ = cancellable
                        },
                        receiveValue: { reply in
                            let assistantMsg = ChatMessage(role: .assistant, content: reply)
                            self.appendToScreen(assistantMsg)
                            self.contextBuffer.append(assistantMsg)
                            promise(.success(reply))
                        }
                    )
            }
        }.eraseToAnyPublisher()
    }

    /// Send message with streaming (iOS 14+)
    func sendStream(_ text: String) -> AnyPublisher<AnyPublisher<String, Error>, Error> {
        let userMsg = ChatMessage(role: .user, content: text)
        appendToScreen(userMsg)
        contextBuffer.append(userMsg)

        return Future<AnyPublisher<String, Error>, Error> { [weak self] promise in
            guard let self = self else { return }
            Task {
                let (kbContext, historyStr) = await self.preparePromptContext(for: text)
                let streamPublisher = self.llmClient.chatStreamPublisher(
                    messages: self.contextMessages,
                    knowledgeContext: kbContext,
                    chatHistory: historyStr
                )
                promise(.success(streamPublisher))
            }
        }.eraseToAnyPublisher()
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

    /// Whether the knowledge base is loaded.
    var isKnowledgeBaseLoaded: Bool {
        kbManager.isLoaded
    }

    /// Number of knowledge base chunks available.
    var knowledgeBaseChunkCount: Int {
        kbManager.chunkCount
    }

    /// Reload the knowledge base (call after importing new KB).
    func reloadKnowledgeBase() {
        kbManager.loadIfExists()
    }

    // MARK: - Private Helpers

    /// Search the knowledge base (hybrid: keyword + embedding) and build prompt context strings.
    private func preparePromptContext(for userQuery: String) async -> (kbContext: String, historyStr: String) {
        // Hybrid search KB for relevant chunks
        let kbContext: String
        if kbManager.isLoaded {
            let config = configRepo.getConfig()
            let results = await kbManager.searchHybrid(query: userQuery, topK: 5, config: config)
            kbContext = kbManager.formatContext(from: results)
        } else {
            kbContext = ""
        }

        // Format chat history (last N exchanges, excluding current user message)
        let historyMessages = contextBuffer.dropLast()
        let historyStr: String
        if historyMessages.isEmpty {
            historyStr = ""
        } else {
            historyStr = historyMessages.map { msg in
                let role = msg.role == .user ? "用户" : "客服"
                return "\(role)：\(msg.content)"
            }.joined(separator: "\n")
        }

        return (kbContext, historyStr)
    }
}
