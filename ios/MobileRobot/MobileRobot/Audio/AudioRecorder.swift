//
//  AudioRecorder.swift
//  SiriApp
//
//  Audio recording via AVAudioEngine input tap.
//  iOS 15+: AsyncStream<[Float]>
//  iOS 14: Combine PassthroughSubject<[Float], Never>
//
//  Ported from Android: AudioRecorder.kt
//

import Foundation
import AVFoundation
import Combine
import os.log

class AudioRecorder {
    private let engine = AVAudioEngine()
    private let sampleRate: Double = 16000.0
    private let subject = PassthroughSubject<[Float], Never>()
    private var isRecording = false

    /// Cached audio converter — created once per recording session and reused
    /// for every buffer to avoid repeated allocations.
    private var cachedConverter: AVAudioConverter?
    private var cachedOutputFormat: AVAudioFormat?

    // MARK: - iOS 14+ (Combine)

    func startRecordingPublisher() -> AnyPublisher<[Float], Never> {
        setupEngineTap()
        return subject.eraseToAnyPublisher()
    }

    // MARK: - iOS 15+ (AsyncStream)

    @available(iOS 15.0, *)
    func startRecordingStream() -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            self.setupEngineTapWithCallback { samples in
                continuation.yield(samples)
            }

            continuation.onTermination = { @Sendable _ in
                self.stopInternal()
            }
        }
    }

    // MARK: - Setup

    private var onSamplesCallback: (([Float]) -> Void)?

    private func setupEngineTapWithCallback(callback: @escaping ([Float]) -> Void) {
        self.onSamplesCallback = callback
        setupEngineTap()
    }

    private func setupEngineTap() {
        guard !isRecording else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Create format for 16kHz mono float32
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            os_log(.error, "AudioRecorder: failed to create audio format")
            return
        }

        // Create and cache format + converter for this recording session
        let outputFormat = format
        cachedOutputFormat = outputFormat

        // Install tap on input node (with format conversion if needed)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            // Convert to desired format if needed
            guard let self = self else { return }
            let converted: AVAudioPCMBuffer
            if buffer.format.sampleRate == outputFormat.sampleRate
                && buffer.format.channelCount == outputFormat.channelCount {
                converted = buffer
            } else {
                // Create converter lazily on first buffer that needs conversion
                if self.cachedConverter == nil {
                    self.cachedConverter = AVAudioConverter(from: buffer.format, to: outputFormat)
                }
                guard let converter = self.cachedConverter,
                      let convertedBuffer = self.convert(buffer: buffer, using: converter) else {
                    return
                }
                converted = convertedBuffer
            }

            guard let channelData = converted.floatChannelData else { return }
            let frameLength = Int(converted.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

            if let callback = self.onSamplesCallback {
                callback(samples)
            } else {
                self.subject.send(samples)
            }
        }

        do {
            engine.prepare()
            try engine.start()
            isRecording = true
            os_log(.info, "AudioRecorder: recording started at %{public}.0f Hz", sampleRate)
        } catch {
            os_log(.error, "AudioRecorder: failed to start: %{public}@",
                   error.localizedDescription)
        }
    }

    private func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: frameCapacity
        ) else { return nil }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            os_log(.error, "AudioRecorder: conversion error: %{public}@", error.localizedDescription)
            return nil
        }

        return outputBuffer
    }

    func stop() {
        stopInternal()
    }

    private func stopInternal() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        cachedConverter = nil
        cachedOutputFormat = nil
        os_log(.info, "AudioRecorder: stopped")
    }
}
