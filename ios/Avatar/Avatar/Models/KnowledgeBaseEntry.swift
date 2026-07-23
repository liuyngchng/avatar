//
//  KnowledgeBaseEntry.swift
//  Avatar
//
//  Data models for the gas company knowledge base.
//  PC-side vectorizes documents → exports JSON → phone imports & searches locally.
//

import Foundation

/// A single chunk of knowledge base content.
struct KnowledgeBaseChunk: Codable, Identifiable {
    let id: String
    let text: String
    /// Optional pre-computed embedding vector (from PC-side vectorization).
    let embedding: [Float]?
    /// Optional keywords for boosting keyword-search accuracy.
    let keywords: [String]?

    init(id: String, text: String, embedding: [Float]? = nil, keywords: [String]? = nil) {
        self.id = id
        self.text = text
        self.embedding = embedding
        self.keywords = keywords
    }
}

/// Top-level knowledge base container, serialized as JSON for import/export.
struct KnowledgeBase: Codable {
    let version: Int
    let companyName: String?
    let chunks: [KnowledgeBaseChunk]

    init(version: Int = 1, companyName: String? = nil, chunks: [KnowledgeBaseChunk]) {
        self.version = version
        self.companyName = companyName
        self.chunks = chunks
    }
}

/// A single search result with relevance score.
struct KnowledgeBaseSearchResult {
    let chunk: KnowledgeBaseChunk
    let score: Float
}
