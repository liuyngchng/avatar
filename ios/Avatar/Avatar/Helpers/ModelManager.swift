//
//  ModelManager.swift
//  SiriApp
//
//  Model file management: check, download, import, extract.
//  Per-slot state + serial operation queue — user can submit all 3 at once.
//

import Foundation
import OSLog

private let modelLog = Logger(subsystem: "com.siri.app", category: "ModelManager")

// MARK: - Download State

enum ModelDownloadState: Equatable {
    case idle
    case queued                     // waiting in queue
    case downloading(progress: Double)
    case importing(progress: Double) // reading file from local/remote source (not HTTP download)
    case extracting(progress: Double)
    case completed(Date)
    case failed(String)
}

// MARK: - Operation Queue (serializes all model operations)

private actor OperationQueue {
    private var lastTask: Task<Void, Never>?

    func enqueue(_ operation: @escaping () async -> Void) {
        let prev = lastTask
        lastTask = Task {
            await prev?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func cancelAll() {
        lastTask?.cancel()
        lastTask = nil
    }
}

// MARK: - Model Manager

@MainActor
final class ModelManager: ObservableObject {
    @Published var asrState: ModelDownloadState = .idle
    @Published var ttsState: ModelDownloadState = .idle
    @Published var vocoderState: ModelDownloadState = .idle
    @Published var kwsState: ModelDownloadState = .idle

    private let queue = OperationQueue()
    private var currentDownloadTask: URLSessionDownloadTask?
    private var currentDownloadSession: URLSession?

    // MARK: - Paths

    static let asrModelDir = "asr"
    static let ttsModelDir = "tts"
    static let kwsModelDir = "kws"

    private static let asrRequired = ["model.int8.onnx", "tokens.txt"]
    private static let ttsRequired = ["model.onnx", "vocos.onnx", "tokens.txt", "lexicon.txt"]
    private static let kwsRequired = ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"]

    /// KWS model archive contains multiple epochs and quantisation variants.
    /// Match Android's selection:
    ///   encoder – epoch-12 int8   (4.7 MB)
    ///   decoder  – epoch-12 full   (675 KB, NOT int8)
    ///   joiner   – epoch-12 int8   (65 KB)
    ///
    /// Strategy: scan the directory; for encoder/joiner prefer `.int8.onnx`,
    /// for decoder prefer plain `.onnx` (not `.int8.onnx`). Falls back to
    /// any match if the preferred variant is absent.
    nonisolated static func applyKwsRenames() {
        let dir = kwsModelDirURL()
        let fm = FileManager.default

        typealias Rule = (keyword: String, preferInt8: Bool, targetName: String)
        let rules: [Rule] = [
            ("encoder", true,  "encoder.onnx"),
            ("decoder", false, "decoder.onnx"),
            ("joiner",  true,  "joiner.onnx"),
        ]

        for (keyword, preferInt8, targetName) in rules {
            let dst = dir.appendingPathComponent(targetName)
            if fm.fileExists(atPath: dst.path) { continue }

            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            var bestMatch: URL?

            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent
                guard name.contains(keyword) && name.hasSuffix(".onnx") else { continue }
                if bestMatch == nil {
                    bestMatch = fileURL
                }
                let isInt8 = name.contains(".int8.onnx")
                if preferInt8 && isInt8 {
                    bestMatch = fileURL  // int8 is preferred
                } else if !preferInt8 && !isInt8 {
                    bestMatch = fileURL  // full precision is preferred
                }
            }

            if let src = bestMatch {
                try? fm.removeItem(at: dst)
                try? fm.moveItem(at: src, to: dst)
                modelLog.info("KWS rename: \(src.lastPathComponent) -> \(targetName)")
            } else {
                modelLog.warning("KWS rename: no match found for '\(keyword)'")
            }
        }
    }

    private static let asrDownloadURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2"
    )!
    private static let ttsDownloadURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/matcha-icefall-zh-baker.tar.bz2"
    )!
    private static let vocoderDownloadURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos-22khz-univ.onnx"
    )!
    private static let kwsDownloadURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar.bz2"
    )!

    deinit {
        currentDownloadSession?.invalidateAndCancel()
    }

    // MARK: - Path Helpers

    nonisolated static func documentsDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    nonisolated static func modelsDir() -> URL {
        documentsDir().appendingPathComponent("models")
    }
    nonisolated static func asrModelDirURL() -> URL {
        modelsDir().appendingPathComponent(asrModelDir)
    }
    nonisolated static func ttsModelDirURL() -> URL {
        modelsDir().appendingPathComponent(ttsModelDir)
    }
    nonisolated static func kwsModelDirURL() -> URL {
        modelsDir().appendingPathComponent(kwsModelDir)
    }

    // MARK: - Ready Checks

    nonisolated static func checkAllReady() -> Bool { checkAsrReady() && checkTtsReady() }

    nonisolated static func checkAsrReady() -> Bool {
        let dir = asrModelDirURL()
        return asrRequired.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }
    nonisolated static func checkTtsReady() -> Bool {
        let dir = ttsModelDirURL()
        return ttsRequired.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }
    nonisolated static func checkTtsExtracted() -> Bool {
        let dir = ttsModelDirURL()
        return ["tokens.txt", "lexicon.txt"].allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }
    nonisolated static func checkVocoderReady() -> Bool {
        let path = ttsModelDirURL().appendingPathComponent("vocos.onnx").path
        let exists = FileManager.default.fileExists(atPath: path)
        modelLog.info("checkVocoderReady: path=\(path), exists=\(exists)")
        return exists
    }
    nonisolated static func checkKwsReady() -> Bool {
        let dir = kwsModelDirURL()
        return kwsRequired.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    // MARK: - Cancel

    func cancelAll() {
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
        currentDownloadSession?.invalidateAndCancel()
        currentDownloadSession = nil
        Task { await queue.cancelAll() }
        // Reset queued/processing states
        if case .queued = asrState { asrState = .idle }
        if case .queued = ttsState { ttsState = .idle }
        if case .queued = vocoderState { vocoderState = .idle }
        if case .queued = kwsState { kwsState = .idle }
    }

    // MARK: - Download (enqueue, returns immediately)

    func downloadAsrModel() {
        guard asrState != .completed(Date()) else { return }
        modelLog.info("downloadAsrModel enqueued")
        asrState = .queued
        Task {
            await queue.enqueue { [weak self] in
                await self?._downloadAsrModel()
            }
        }
    }

    func downloadTtsModel() {
        guard ttsState != .completed(Date()) else { return }
        modelLog.info("downloadTtsModel enqueued")
        ttsState = .queued
        Task {
            await queue.enqueue { [weak self] in
                await self?._downloadTtsModel()
            }
        }
    }

    func downloadVocoder() {
        guard vocoderState != .completed(Date()) else { return }
        modelLog.info("downloadVocoder enqueued")
        vocoderState = .queued
        Task {
            await queue.enqueue { [weak self] in
                await self?._downloadVocoder()
            }
        }
    }

    func downloadKwsModel() {
        guard kwsState != .completed(Date()) else { return }
        modelLog.info("downloadKwsModel enqueued")
        kwsState = .queued
        Task {
            await queue.enqueue { [weak self] in
                await self?._downloadKwsModel()
            }
        }
    }

    // MARK: - Import (enqueue, returns immediately)

    func importAsrModel(from sourceURL: URL, cleanup: (() -> Void)? = nil) {
        modelLog.info("importAsrModel enqueued: \(sourceURL.lastPathComponent)")
        asrState = .queued
        Task {
            await queue.enqueue { [weak self] in
                await self?._importAsrModel(from: sourceURL, cleanup: cleanup)
            }
        }
    }

    func importTtsModel(from sourceURL: URL, cleanup: (() -> Void)? = nil) {
        modelLog.info("importTtsModel enqueued: \(sourceURL.lastPathComponent)")
        ttsState = .queued
        Task {
            await queue.enqueue { [weak self] in
                await self?._importTtsModel(from: sourceURL, cleanup: cleanup)
            }
        }
    }

    func importVocoder(from sourceURL: URL, cleanup: (() -> Void)? = nil) {
        modelLog.info("importVocoder enqueued: \(sourceURL.lastPathComponent)")
        vocoderState = .queued
        Task {
            await queue.enqueue { [weak self] in
                await self?._importVocoder(from: sourceURL, cleanup: cleanup)
            }
        }
    }

    func importKwsModel(from sourceURL: URL, cleanup: (() -> Void)? = nil) {
        modelLog.info("importKwsModel enqueued: \(sourceURL.lastPathComponent)")
        kwsState = .queued
        Task {
            await queue.enqueue { [weak self] in
                await self?._importKwsModel(from: sourceURL, cleanup: cleanup)
            }
        }
    }

    // MARK: - Private: Actual Download Logic (runs sequentially)

    private func _downloadAsrModel() async {
        await _downloadAndExtract(
            url: Self.asrDownloadURL,
            destDir: Self.asrModelDir,
            archiveName: "asr_model.tar.bz2",
            statePath: \.asrState,
            checkReady: { Self.checkAsrReady() }
        )
    }

    private func _downloadTtsModel() async {
        await _downloadAndExtract(
            url: Self.ttsDownloadURL,
            destDir: Self.ttsModelDir,
            archiveName: "tts_model.tar.bz2",
            statePath: \.ttsState,
            checkReady: { Self.checkTtsExtracted() }
        )
    }

    private func _downloadVocoder() async {
        modelLog.info("Starting vocoder download")
        vocoderState = .downloading(progress: 0)

        let destDir = Self.ttsModelDirURL()
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destFile = destDir.appendingPathComponent("vocos.onnx")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("vocoder-download-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempFile = tempDir.appendingPathComponent("vocos-22khz-univ.onnx")

        do {
            try await _downloadFile(from: Self.vocoderDownloadURL, to: tempFile) { [weak self] p in
                self?.vocoderState = .downloading(progress: p)
            }
        } catch {
            if error is CancellationError {
                modelLog.info("Vocoder download cancelled")
                vocoderState = .idle; return
            }
            modelLog.error("Vocoder download failed: \(error.localizedDescription)")
            vocoderState = .failed("下载失败: \(error.localizedDescription)")
            return
        }

        try? FileManager.default.removeItem(at: destFile)
        try? FileManager.default.copyItem(at: tempFile, to: destFile)
        modelLog.info("Vocoder download completed")
        vocoderState = .completed(Date())
    }

    private func _downloadKwsModel() async {
        await _downloadAndExtract(
            url: Self.kwsDownloadURL,
            destDir: Self.kwsModelDir,
            archiveName: "kws_model.tar.bz2",
            statePath: \.kwsState,
            checkReady: {
                Self.applyKwsRenames()
                return Self.checkKwsReady()
            }
        )
    }

    // MARK: - Private: Actual Import Logic (runs sequentially)

    private func _importAsrModel(from sourceURL: URL, cleanup: (() -> Void)?) async {
        await _importArchive(from: sourceURL, destDir: Self.asrModelDir, statePath: \.asrState, cleanup: cleanup)
    }

    private func _importTtsModel(from sourceURL: URL, cleanup: (() -> Void)?) async {
        await _importArchive(from: sourceURL, destDir: Self.ttsModelDir, statePath: \.ttsState, cleanup: cleanup)
    }

    private func _importKwsModel(from sourceURL: URL, cleanup: (() -> Void)?) async {
        await _importArchive(from: sourceURL, destDir: Self.kwsModelDir, statePath: \.kwsState, cleanup: cleanup)
        // Rename long KWS file names to standard short names after extraction
        if case .completed = kwsState {
            Self.applyKwsRenames()
            if !Self.checkKwsReady() {
                modelLog.warning("KWS import: files extracted but verification failed after rename")
                kwsState = .failed("解压完成但文件验证失败")
            }
        }
    }

    private func _importVocoder(from sourceURL: URL, cleanup: (() -> Void)?) async {
        modelLog.info("Starting vocoder import from \(sourceURL.lastPathComponent)")
        vocoderState = .importing(progress: 0)

        let destDir = Self.ttsModelDirURL()
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destFile = destDir.appendingPathComponent("vocos.onnx")

        do {
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                try? fm.removeItem(at: destFile)
                let data: Data
                do { data = try Data(contentsOf: sourceURL, options: []) }
                catch {
                    modelLog.warning("Data(contentsOf:) failed, falling back to FileHandle: \(error.localizedDescription)")
                    let handle = try FileHandle(forReadingFrom: sourceURL)
                    defer { try? handle.close() }
                    data = handle.readDataToEndOfFile()
                }
                modelLog.debug("Read \(data.count) bytes, writing to dest")
                try data.write(to: destFile)
                modelLog.info("Vocoder file written to \(destFile.lastPathComponent)")
            }.value
        } catch {
            modelLog.error("Vocoder import failed: \(error.localizedDescription)")
            vocoderState = .failed("文件复制失败: \(error.localizedDescription)")
            cleanup?()
            return
        }

        modelLog.info("Vocoder import completed")
        cleanup?()
        vocoderState = .completed(Date())
    }

    // MARK: - Private: Download + Extract Pipeline

    private func _downloadAndExtract(
        url: URL?,
        destDir: String,
        archiveName: String,
        statePath: ReferenceWritableKeyPath<ModelManager, ModelDownloadState>,
        checkReady: @escaping () -> Bool
    ) async {
        self[keyPath: statePath] = .downloading(progress: 0)

        guard let downloadURL = url else {
            modelLog.error("Invalid download URL for \(archiveName)")
            self[keyPath: statePath] = .failed("无效的下载地址")
            return
        }

        modelLog.info("Downloading \(archiveName) from \(downloadURL.absoluteString)")

        let fm = FileManager.default
        let modelsDir = Self.modelsDir()
        try? fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let tempDir = fm.temporaryDirectory.appendingPathComponent("model-download-\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let archiveURL = tempDir.appendingPathComponent(archiveName)

        // Download
        do {
            try await _downloadFile(from: downloadURL, to: archiveURL) { [weak self] p in
                self?[keyPath: statePath] = .downloading(progress: p)
            }
        } catch {
            if error is CancellationError {
                modelLog.info("Download cancelled for \(archiveName)")
                self[keyPath: statePath] = .idle; return
            }
            modelLog.error("Download failed for \(archiveName): \(error.localizedDescription)")
            self[keyPath: statePath] = .failed("下载失败: \(error.localizedDescription)")
            return
        }

        modelLog.info("Download complete, extracting \(archiveName)")

        // Extract on background thread to keep UI responsive
        self[keyPath: statePath] = .extracting(progress: 0)
        let destinationDir = modelsDir.appendingPathComponent(destDir)
        do {
            try await Task.detached(priority: .userInitiated) {
                var lastReported: Float = -1
                try TarBz2Extractor.extract(
                    sourceURL: archiveURL,
                    destinationDir: destinationDir,
                    progress: { p in
                        // Throttle: only update when changed by ≥2% or reached end
                        guard p - lastReported >= 0.02 || p >= 1.0 else { return }
                        lastReported = p
                        Task { @MainActor [weak self] in
                            self?[keyPath: statePath] = .extracting(progress: Double(p))
                        }
                    }
                )
            }.value
        } catch {
            modelLog.error("Extraction failed for \(archiveName): \(error.localizedDescription)")
            self[keyPath: statePath] = .failed("解压失败: \(error.localizedDescription)")
            return
        }

        guard checkReady() else {
            modelLog.error("Verification failed for \(archiveName)")
            self[keyPath: statePath] = .failed("完成但验证失败，文件缺失")
            return
        }

        modelLog.info("Download + extract completed: \(archiveName)")
        self[keyPath: statePath] = .completed(Date())
    }

    private func _importArchive(
        from sourceURL: URL,
        destDir: String,
        statePath: ReferenceWritableKeyPath<ModelManager, ModelDownloadState>,
        cleanup: (() -> Void)?
    ) async {
        self[keyPath: statePath] = .importing(progress: 0)

        let fm = FileManager.default
        let modelsDir = Self.modelsDir()
        try? fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let destinationDir = modelsDir.appendingPathComponent(destDir)

        let srcExt = sourceURL.pathExtension.lowercased()
        let isTar = (srcExt == "tar")

        let tempDir = fm.temporaryDirectory.appendingPathComponent("model-import-\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let archiveName = isTar ? "uploaded.tar" : "uploaded.tar.bz2"
        let archiveURL = tempDir.appendingPathComponent(archiveName)

        modelLog.info("Import archive from \(sourceURL.lastPathComponent) (isTar=\(isTar))")

        // Copy file to temp
        do {
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                try? fm.removeItem(at: archiveURL)
                let data: Data
                do { data = try Data(contentsOf: sourceURL, options: []) }
                catch {
                    modelLog.warning("Data(contentsOf:) failed, falling back to FileHandle: \(error.localizedDescription)")
                    let handle = try FileHandle(forReadingFrom: sourceURL)
                    defer { try? handle.close() }
                    data = handle.readDataToEndOfFile()
                }
                modelLog.debug("Read \(data.count) bytes (\(data.count / 1024 / 1024) MB) from source")
                try data.write(to: archiveURL)
                modelLog.info("Copied to temp: \(archiveURL.lastPathComponent)")
            }.value
        } catch {
            modelLog.error("File read failed: \(error.localizedDescription)")
            self[keyPath: statePath] = .failed("文件读取失败: \(error.localizedDescription)")
            cleanup?()
            return
        }

        // File data is now in local temp — safe to release security-scoped URL
        cleanup?()

        // Extract on background thread to keep UI responsive
        self[keyPath: statePath] = .extracting(progress: 0)
        modelLog.info("Starting extraction to \(destinationDir.path)")
        do {
            try await Task.detached(priority: .userInitiated) {
                var lastReported: Float = -1
                try TarBz2Extractor.extract(
                    sourceURL: archiveURL,
                    destinationDir: destinationDir,
                    progress: { p in
                        // Throttle: only update when changed by ≥2% or reached end
                        guard p - lastReported >= 0.02 || p >= 1.0 else { return }
                        lastReported = p
                        Task { @MainActor [weak self] in
                            self?[keyPath: statePath] = .extracting(progress: Double(p))
                        }
                    }
                )
            }.value
        } catch {
            modelLog.error("Extraction failed: \(error.localizedDescription)")
            self[keyPath: statePath] = .failed("解压失败: \(error.localizedDescription)")
            return
        }

        modelLog.info("Import completed successfully")
        self[keyPath: statePath] = .completed(Date())
    }

    // MARK: - Private: File Download

    private func _downloadFile(
        from url: URL,
        to targetURL: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            let delegate = DownloadProgressDelegate(onProgress: onProgress)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            self?.currentDownloadSession = session

            delegate.onCompletion = { [weak self] result in
                Task { @MainActor [weak self] in
                    switch result {
                    case .success(let tempURL):
                        do {
                            try? FileManager.default.removeItem(at: targetURL)
                            try FileManager.default.copyItem(at: tempURL, to: targetURL)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                        try? FileManager.default.removeItem(at: tempURL)
                        self?.currentDownloadSession?.finishTasksAndInvalidate()
                        self?.currentDownloadSession = nil
                    case .failure(let error):
                        self?.currentDownloadSession?.invalidateAndCancel()
                        self?.currentDownloadSession = nil
                        let nsError = error as NSError
                        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }

            let task = session.downloadTask(with: url)
            self?.currentDownloadTask = task
            task.resume()
        }
    }
}

// MARK: - Download Errors

enum DownloadError: LocalizedError {
    case invalidURL
    case extractionFailed(String)
    case verificationFailed
    case fileImportFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的下载地址"
        case .extractionFailed(let msg): return "解压错误: \(msg)"
        case .verificationFailed: return "下载完成但文件验证失败，请重试"
        case .fileImportFailed(let msg): return "文件导入失败: \(msg)"
        }
    }
}

// MARK: - URLSessionDownloadDelegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    var onCompletion: ((Result<URL, Error>) -> Void)?

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { [weak self] in self?.onProgress(progress) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        let cacheDir = fm.temporaryDirectory.appendingPathComponent("download-cache")
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cachedURL = cacheDir.appendingPathComponent(location.lastPathComponent)
        try? fm.removeItem(at: cachedURL)
        do {
            try fm.copyItem(at: location, to: cachedURL)
            onCompletion?(.success(cachedURL))
        } catch {
            onCompletion?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            onCompletion?(.failure(error))
        }
    }
}
