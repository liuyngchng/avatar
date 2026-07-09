//
//  TarBz2Extractor.swift
//  SiriApp
//
//  tar.bz2 extraction using stream-based bzip2 (via Bzip2Helper.h) and
//  FileHandle-based tar parsing. Memory efficient — no full file loads.
//  Ported from VoiceNote: ASRModelManager.swift tar extraction logic.
//

import Foundation

enum TarBz2Extractor {
    private static let tarBlockSize = 512

    /// Known file name mappings (auto-rename after extraction)
    static let renameMap: [String: String] = [
        "model-steps-3.onnx": "model.onnx",
        "vocos-22khz-univ.onnx": "vocos.onnx",
    ]

    // MARK: - Public API

    /// Extract a .tar.bz2 or .tar file to destination directory.
    /// Uses streaming I/O — safe for large files on iOS.
    static func extract(
        sourceURL: URL,
        destinationDir: URL,
        progress: ((Float) -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let isTar = sourceURL.pathExtension.lowercased() == "tar"

        let tarURL: URL
        if isTar {
            tarURL = sourceURL
            progress?(0.1)
        } else {
            // Decompress bzip2 → tar in temp directory
            let tmpDir = fm.temporaryDirectory.appendingPathComponent("tar-extract-\(UUID().uuidString)")
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmpDir) }

            let decompressedURL = tmpDir.appendingPathComponent(
                sourceURL.deletingLastPathComponent().lastPathComponent
            ).deletingPathExtension().appendingPathExtension("tar")

            progress?(0.0)

            let result = bzip2_decompress_file(sourceURL.path, decompressedURL.path)
            guard result == 0 else {
                throw NSError(
                    domain: "TarBz2Extractor", code: Int(result),
                    userInfo: [NSLocalizedDescriptionKey: "bzip2 decompress failed, code: \(result)"]
                )
            }

            progress?(0.3)
            tarURL = decompressedURL

            // Extract from tar
            try extractTar(tarURL: tarURL, to: destinationDir, progress: { p in
                progress?(0.3 + p * 0.6)
            })
        }

        // Extract from tar if not already done (for .tar files)
        if isTar {
            try extractTar(tarURL: tarURL, to: destinationDir, progress: { p in
                progress?(0.1 + p * 0.8)
            })
        }

        // Rename known files
        for (oldName, newName) in renameMap {
            let src = destinationDir.appendingPathComponent(oldName)
            let dst = destinationDir.appendingPathComponent(newName)
            if fm.fileExists(atPath: src.path) && !fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: dst)
                try? fm.moveItem(at: src, to: dst)
            }
        }

        progress?(1.0)
    }

    // MARK: - Tar Extraction (streaming)

    private static func extractTar(
        tarURL: URL,
        to destDir: URL,
        progress: ((Float) -> Void)? = nil
    ) throws {
        let fm = FileManager.default

        // Get total file size for progress
        let totalSize: Float
        if let attrs = try? fm.attributesOfItem(atPath: tarURL.path),
           let size = attrs[.size] as? NSNumber {
            totalSize = Float(size.int64Value)
        } else {
            totalSize = 1
        }

        let fileHandle = try FileHandle(forReadingFrom: tarURL)
        defer { try? fileHandle.close() }

        while true {
            // Read 512-byte tar header
            guard let headerData = try? fileHandle.read(upToCount: tarBlockSize),
                  headerData.count == tarBlockSize else {
                break
            }

            // Check for end-of-archive (two consecutive zero blocks)
            if headerData.allSatisfy({ $0 == 0 }) {
                if let nextBlock = try? fileHandle.read(upToCount: tarBlockSize),
                   nextBlock.allSatisfy({ $0 == 0 }) {
                    break
                }
                // Not actually end — rewind
                try? fileHandle.seek(toOffset: fileHandle.offsetInFile - UInt64(tarBlockSize))
                break
            }

            // Parse file name (offset 0, length 100)
            let nameData = headerData[0..<100]
            guard let name = String(data: nameData, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
                continue
            }

            // Parse file size (offset 124, length 12, octal string)
            let sizeData = headerData[124..<136]
            guard let sizeStr = String(data: sizeData, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")),
                  let fileSize = UInt64(sizeStr, radix: 8) else {
                continue
            }

            // Strip first directory component (--strip-components=1)
            var relativePath = name
            if let slashRange = relativePath.range(of: "/") {
                relativePath = String(relativePath[slashRange.upperBound...])
            }

            // Calculate padded size (512-byte aligned)
            let paddedSize = ((fileSize + UInt64(tarBlockSize) - 1) / UInt64(tarBlockSize)) * UInt64(tarBlockSize)

            if relativePath.isEmpty || name.hasSuffix("/") || fileSize == 0 {
                // Directory entry — skip padding
                if paddedSize > 0 {
                    try? fileHandle.seek(toOffset: fileHandle.offsetInFile + paddedSize)
                }
                progress?(Float(fileHandle.offsetInFile) / totalSize)
                continue
            }

            // Extract file
            let destPath = destDir.appendingPathComponent(relativePath)
            try fm.createDirectory(at: destPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destPath)

            if fileSize > 0 {
                guard let fileData = try? fileHandle.read(upToCount: Int(fileSize)) else {
                    throw NSError(
                        domain: "TarBz2Extractor", code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to read tar entry: \(relativePath)"]
                    )
                }
                try fileData.write(to: destPath)
            } else {
                // Empty file
                fm.createFile(atPath: destPath.path, contents: nil)
            }

            // Skip padding bytes (already read fileSize bytes, need to skip paddedSize - fileSize)
            let padding = Int(paddedSize - fileSize)
            if padding > 0 {
                try? fileHandle.seek(toOffset: fileHandle.offsetInFile + UInt64(padding))
            }

            progress?(Float(fileHandle.offsetInFile) / totalSize)
        }
    }
}
