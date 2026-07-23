//
//  KnowledgeBaseManager.swift
//  Avatar
//
//  Manages the gas company knowledge base: load, save, search.
//  Supports keyword-based search (offline) and optional embedding search.
//

import Foundation
import os.log

private let kbLog = Logger(subsystem: "com.siri.app", category: "KnowledgeBase")

final class KnowledgeBaseManager: ObservableObject {
    @Published var knowledgeBase: KnowledgeBase?
    @Published var isLoaded: Bool = false
    @Published var chunkCount: Int = 0

    private let kbFileName = "knowledge_base.json"
    private var searchIndex: [String: [Int]] = [:]  // token → chunk indices
    private var chunkTexts: [String] = []

    // MARK: - Paths

    private var kbFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(kbFileName)
    }

    // MARK: - Load / Save

    /// Load the knowledge base from disk on app start.
    func loadIfExists() {
        let url = kbFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let kb = try? JSONDecoder().decode(KnowledgeBase.self, from: data) else {
            kbLog.info("No knowledge base file found at \(url.path)")
            return
        }
        self.knowledgeBase = kb
        self.isLoaded = true
        self.chunkCount = kb.chunks.count
        buildIndex()
        kbLog.info("Knowledge base loaded: \(kb.chunks.count) chunks, company: \(kb.companyName ?? "unknown")")
    }

    /// Import a knowledge base JSON file from a URL (e.g., document picker).
    func importFromURL(_ sourceURL: URL) throws {
        let data: Data
        var didAccess = false
        if sourceURL.startAccessingSecurityScopedResource() {
            didAccess = true
        }
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            kbLog.error("Failed to read KB file: \(error.localizedDescription)")
            throw KnowledgeBaseError.fileReadFailed(error.localizedDescription)
        }

        let kb: KnowledgeBase
        do {
            kb = try JSONDecoder().decode(KnowledgeBase.self, from: data)
        } catch {
            kbLog.error("Failed to decode KB JSON: \(error.localizedDescription)")
            throw KnowledgeBaseError.invalidFormat(error.localizedDescription)
        }

        guard !kb.chunks.isEmpty else {
            throw KnowledgeBaseError.emptyChunks
        }

        // Save to documents directory
        let destURL = kbFileURL
        try? FileManager.default.removeItem(at: destURL)
        try data.write(to: destURL)

        self.knowledgeBase = kb
        self.isLoaded = true
        self.chunkCount = kb.chunks.count
        buildIndex()
        kbLog.info("Knowledge base imported: \(kb.chunks.count) chunks, company: \(kb.companyName ?? "unknown")")
    }

    /// Remove the knowledge base.
    func clear() {
        let url = kbFileURL
        try? FileManager.default.removeItem(at: url)
        knowledgeBase = nil
        isLoaded = false
        chunkCount = 0
        searchIndex = [:]
        chunkTexts = []
        kbLog.info("Knowledge base cleared")
    }

    // MARK: - Index

    private func buildIndex() {
        guard let kb = knowledgeBase else { return }
        var index: [String: [Int]] = [:]
        var texts: [String] = []

        for (i, chunk) in kb.chunks.enumerated() {
            texts.append(chunk.text)
            let tokens = Self.tokenize(chunk.text)

            // Index chunk text tokens
            for token in tokens {
                index[token, default: []].append(i)
            }

            // Index explicit keywords with higher priority (add multiple times)
            if let keywords = chunk.keywords {
                for kw in keywords {
                    let kwTokens = Self.tokenize(kw)
                    for kt in kwTokens {
                        // Add twice to boost keyword matches
                        index[kt, default: []].append(i)
                        index[kt, default: []].append(i)
                    }
                }
            }
        }

        self.searchIndex = index
        self.chunkTexts = texts
    }

    // MARK: - Search

    /// Search the knowledge base for chunks relevant to the query.
    /// - Parameters:
    ///   - query: The user's question.
    ///   - topK: Maximum number of results to return.
    ///   - minScore: Minimum score threshold (0.0–1.0) for a chunk to be included.
    /// - Returns: Ranked search results.
    func search(query: String, topK: Int = 5, minScore: Float = 0.05) -> [KnowledgeBaseSearchResult] {
        guard isLoaded, !searchIndex.isEmpty else { return [] }

        let queryTokens = Self.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        // Score each chunk by token overlap
        var scores: [Int: Float] = [:]
        let tokenWeight: Float = 1.0 / Float(max(1, queryTokens.count))

        for token in queryTokens {
            guard let matchingChunks = searchIndex[token] else { continue }
            for chunkIdx in matchingChunks {
                scores[chunkIdx, default: 0] += tokenWeight
            }
        }

        // Also check for exact phrase/substring matches (bonus)
        let lowerQuery = query.lowercased()
        for (i, text) in chunkTexts.enumerated() {
            if text.lowercased().contains(lowerQuery) {
                scores[i, default: 0] += 0.3
            }
            // Check if any query token appears as substring in chunk
            for qt in queryTokens where qt.count >= 2 {
                if text.lowercased().contains(qt.lowercased()) {
                    scores[i, default: 0] += tokenWeight * 0.5
                }
            }
        }

        // Filter by min score, sort descending, take top K
        let results = scores
            .filter { $0.value >= minScore }
            .sorted { $0.value > $1.value }
            .prefix(topK)
            .compactMap { (idx, score) -> KnowledgeBaseSearchResult? in
                guard let kb = knowledgeBase, idx < kb.chunks.count else { return nil }
                return KnowledgeBaseSearchResult(chunk: kb.chunks[idx], score: score)
            }

        kbLog.debug("KB search: query='\(query.prefix(50))...' → \(results.count) results, top score=\(results.first?.score ?? 0)")
        return results
    }

    /// Format search results into a context string for the LLM prompt.
    func formatContext(from results: [KnowledgeBaseSearchResult]) -> String {
        guard !results.isEmpty else { return "" }
        return results.enumerated().map { (i, r) in
            "- [\(i + 1)] \(r.chunk.text)"
        }.joined(separator: "\n")
    }

    // MARK: - Hybrid Search (Keyword + Embedding)

    /// Hybrid search: keyword coarse-rank → embedding fine-rank.
    /// Falls back to keyword-only if embeddings are unavailable or API fails.
    /// - Parameters:
    ///   - query: User question.
    ///   - topK: Final result count.
    ///   - coarseK: Keyword coarse-rank count (default 20).
    ///   - config: LLM config for embedding API access.
    /// - Returns: Ranked search results.
    func searchHybrid(
        query: String,
        topK: Int = 5,
        coarseK: Int = 20,
        config: LlmConfig? = nil
    ) async -> [KnowledgeBaseSearchResult] {
        // 1. Keyword coarse rank
        let coarseResults = search(query: query, topK: coarseK)
        guard !coarseResults.isEmpty else { return [] }

        // 2. Check if candidates have embeddings
        let hasEmbeddings = coarseResults.contains { $0.chunk.embedding != nil }
        guard hasEmbeddings, let config = config else {
            kbLog.debug("Hybrid search: no embeddings found or no config, falling back to keyword")
            return Array(coarseResults.prefix(topK))
        }

        // 3. Fetch query embedding from API
        let queryEmbedding: [Float]
        do {
            queryEmbedding = try await fetchQueryEmbedding(
                text: query,
                apiUrl: config.apiUrl,
                apiKey: config.apiKey,
                model: config.effectiveEmbeddingModel
            )
        } catch {
            kbLog.warning("Hybrid search: embedding API failed: \(error.localizedDescription), falling back to keyword")
            return Array(coarseResults.prefix(topK))
        }

        // 4. Rerank with cosine similarity
        let reranked = rerankByEmbedding(
            queryEmbedding: queryEmbedding,
            candidates: coarseResults,
            keywordWeight: 0.3,
            embeddingWeight: 0.7,
            topK: topK
        )
        kbLog.debug("Hybrid search: \(coarseResults.count) coarse → \(reranked.count) fine-ranked")
        return reranked
    }

    /// Call the embedding API to get a vector for the query text.
    /// Uses OpenAI-compatible `/embeddings` endpoint.
    private func fetchQueryEmbedding(
        text: String,
        apiUrl: String,
        apiKey: String,
        model: String
    ) async throws -> [Float] {
        let baseUrl = apiUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseUrl)/embeddings") else {
            throw KnowledgeBaseError.invalidEmbeddingURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        let body: [String: Any] = [
            "model": model,
            "input": text,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw KnowledgeBaseError.embeddingAPIError(code)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let first = dataArray.first else {
            throw KnowledgeBaseError.invalidEmbeddingResponse
        }

        // Try multiple JSON number array formats
        if let embedding = first["embedding"] as? [Double] {
            return embedding.map { Float($0) }
        }
        if let embedding = first["embedding"] as? [NSNumber] {
            return embedding.map { $0.floatValue }
        }

        throw KnowledgeBaseError.invalidEmbeddingResponse
    }

    /// Compute cosine similarity between two vectors.
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0 }
        return dotProduct / denominator
    }

    /// Rerank candidate results using embedding similarity combined with keyword scores.
    private func rerankByEmbedding(
        queryEmbedding: [Float],
        candidates: [KnowledgeBaseSearchResult],
        keywordWeight: Float,
        embeddingWeight: Float,
        topK: Int
    ) -> [KnowledgeBaseSearchResult] {
        var scored: [(result: KnowledgeBaseSearchResult, combinedScore: Float)] = []

        for candidate in candidates {
            guard let chunkEmbedding = candidate.chunk.embedding else {
                // Keep chunks without embeddings with their keyword score only
                scored.append((candidate, candidate.score * keywordWeight))
                continue
            }

            let semanticScore = cosineSimilarity(queryEmbedding, chunkEmbedding)
            // Normalize keyword score to 0–1 range for fair combination
            let normalizedKeyword = min(candidate.score, 1.0)
            let combined = normalizedKeyword * keywordWeight + semanticScore * embeddingWeight
            scored.append((candidate, combined))
        }

        // Sort by combined score descending, take top K
        return scored
            .sorted { $0.combinedScore > $1.combinedScore }
            .prefix(topK)
            .map { KnowledgeBaseSearchResult(chunk: $0.result.chunk, score: $0.combinedScore) }
    }

    // MARK: - Tokenization (Chinese text segmentation)

    /// Tokenize text into meaningful terms. For Chinese, uses CFStringTokenizer
    /// for word segmentation; falls back to character n-grams.
    static func tokenize(_ text: String) -> [String] {
        let nsText = text as NSString
        let range = CFRangeMake(0, nsText.length)
        let locale = CFLocaleCopyCurrent()

        guard let tokenizer = CFStringTokenizerCreate(nil, text as CFString, range, kCFStringTokenizerUnitWord, locale) else {
            return ngramTokenize(text)
        }

        var tokens: [String] = []
        var hasRealTokens = false

        // Use the original string to extract tokens by range (avoids CFTypeRef casting issues)
        CFStringTokenizerGoToTokenAtIndex(tokenizer, 0)
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType != CFStringTokenizerTokenType(rawValue: 0) {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if tokenRange.length > 0 {
                // Convert CFRange to NSRange for substring extraction
                let nsRange = NSRange(location: tokenRange.location, length: tokenRange.length)
                if nsRange.location + nsRange.length <= nsText.length {
                    let tokenStr = nsText.substring(with: nsRange)
                    let trimmed = tokenStr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if trimmed.count >= 1 {
                        // Include if contains letters, digits, or CJK characters
                        let hasLetter = trimmed.rangeOfCharacter(from: CharacterSet.letters) != nil
                        let hasDigit = trimmed.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil
                        let cjkRange = trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "\u{4e00}-\u{9fff}"))
                        let hasCJK = cjkRange != nil
                        if hasLetter || hasDigit || hasCJK {
                            tokens.append(trimmed.lowercased())
                            hasRealTokens = true
                        }
                    }
                }
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        // If tokenization produced too few results, supplement with character bigrams
        if !hasRealTokens || tokens.count < 2 {
            let ngrams = ngramTokenize(text)
            tokens.append(contentsOf: ngrams)
        }

        // Deduplicate while preserving order
        var seen = Set<String>()
        tokens = tokens.filter { seen.insert($0).inserted }

        return tokens
    }

    /// Fallback: character bigrams for CJK text.
    private static func ngramTokenize(_ text: String) -> [String] {
        let chars = Array(text)
        var ngrams: [String] = []
        guard chars.count >= 2 else {
            if let c = chars.first { ngrams.append(String(c)) }
            return ngrams
        }
        for i in 0..<(chars.count - 1) {
            ngrams.append(String(chars[i...i+1]))
        }
        return ngrams
    }
}

// MARK: - Errors

enum KnowledgeBaseError: LocalizedError {
    case fileReadFailed(String)
    case invalidFormat(String)
    case emptyChunks
    case invalidEmbeddingURL
    case embeddingAPIError(Int)
    case invalidEmbeddingResponse

    var errorDescription: String? {
        switch self {
        case .fileReadFailed(let msg):
            return "文件读取失败: \(msg)"
        case .invalidFormat(let msg):
            return "知识库格式错误: \(msg)"
        case .emptyChunks:
            return "知识库文件为空，请检查文件内容"
        case .invalidEmbeddingURL:
            return "无效的 Embedding API 地址"
        case .embeddingAPIError(let code):
            return "Embedding API 错误 (\(code))"
        case .invalidEmbeddingResponse:
            return "Embedding API 返回格式异常"
        }
    }
}
