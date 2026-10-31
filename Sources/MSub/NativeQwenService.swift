import AVFoundation
import Foundation
import Metal
import OSLog
import MLX
import MLXNN
@preconcurrency import MLXAudioSTT

actor NativeQwenService {
    static let shared = NativeQwenService()
    private static let performanceLog = Logger(subsystem: "local.msub.MSub", category: "QwenPerformance")
    private static let signposter = OSSignposter(subsystem: "local.msub.MSub", category: "QwenPerformance")
    private var model: Qwen3ASRModel?
    private struct EncodedSegment {
        let features: MLXArray
        let tokenCount: Int
    }
    // Actor-confined, at most two segments; never shared with another model task.
    private var encodedSegments: [EncodedSegment] = []
    private var modelPath: String?
    private var runtimeLibraryURL: URL?
    private var residency = NativeQwenResidency()
    private var idleTask: Task<Void, Never>?
    private var memoryPressureMonitor: NativeQwenMemoryPressureMonitor?
    private var pressureCooldownUntil: TimeInterval = 0

    private var idleSeconds: TimeInterval {
        NativeQwenResidency.idleSeconds(environment: ProcessInfo.processInfo.environment,
                                        physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    private func handleMemoryPressure() {
        pressureCooldownUntil = ProcessInfo.processInfo.systemUptime + 60
        release()
    }

    private func clearModel() {
        model = nil
        modelPath = nil
        // A failed runtime check (or empty VAD result) must not initialize MLX
        // just to clear its allocator: no Metal device can make that abort.
        if runtimeLibraryURL != nil { Memory.clearCache() }
    }

    private func finishRequest(success: Bool) {
        encodedSegments.removeAll()
        let mayRetain = residency.finish(success: success)
        guard mayRetain, model != nil, idleSeconds > 0,
              ProcessInfo.processInfo.systemUptime >= pressureCooldownUntil else {
            clearModel()
            return
        }
        // Retain one model, not the transient decode allocator cache.
        Memory.clearCache()
        let generation = residency.generation
        let delay = idleSeconds
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.expireIdleModel(generation: generation)
        }
    }

    private func expireIdleModel(generation: UInt64) {
        guard residency.canExpire(generation: generation) else { return }
        idleTask = nil
        clearModel()
    }

    struct Options: Sendable {
        let modelDirectory: URL
        let language: String?
        let context: String
        let maxTokens: Int
        let lineCharacters: Int
        var batchEncodingEnabled: Bool = false
        var optimizedDecodingEnabled: Bool = true
        // Match the existing Python Qwen policy; 1 explicitly disables penalty.
        var repetitionPenalty: Float = 1.05
        var repetitionContextSize: Int = 100
        var repetitionRecoveryEnabled: Bool = true
    }

    enum Failure: LocalizedError {
        case busy, invalidAudio, invalidSegment, missingResult, runtimeUnavailable
        var errorDescription: String? {
            switch self {
            case .busy: "Native Qwen is already processing audio."
            case .invalidAudio: "Native Qwen requires the preview's 16 kHz mono audio."
            case .invalidSegment: "Invalid or oversized native Qwen segment (maximum 30 seconds)."
            case .missingResult: "Native Qwen did not return a completed transcript."
            case .runtimeUnavailable: "Native MLX requires a Metal device and compiled MLX shaders. Build the app with Xcode and the Metal Toolchain."
            }
        }
    }

    func release() {
        idleTask?.cancel()
        idleTask = nil
        // A release during decode is deferred until its task has drained.
        if residency.requestRelease() { clearModel() }
    }

    func transcribe(
        audioURL: URL,
        segments: [SubtitleSegment],
        timeOffset: Double,
        options: Options,
        checkpoint: @escaping @Sendable () async throws -> Void,
        onProgress: @escaping @Sendable (Double) async -> Void,
        onCue: @escaping @Sendable (SubtitleCue) async -> Void = { _ in },
        onDiagnostics: @escaping @Sendable (NativeQwenDiagnostics.Snapshot) async -> Void = { _ in }
    ) async throws -> [SubtitleCue] {
        guard residency.begin() else { throw Failure.busy }
        idleTask?.cancel()
        idleTask = nil
        if memoryPressureMonitor == nil {
            memoryPressureMonitor = NativeQwenMemoryPressureMonitor { [weak self] in
                Task { await self?.handleMemoryPressure() }
            }
        }
        var success = false
        defer { finishRequest(success: success) }
        var diagnostics = NativeQwenDiagnostics(totalSegments: segments.count)
        diagnostics.transition(to: .preparation)
        do {
            let cues = try await transcribePreparedAudio(
                audioURL: audioURL, segments: segments, timeOffset: timeOffset, options: options,
                checkpoint: checkpoint, onProgress: onProgress, onCue: onCue, onDiagnostics: onDiagnostics,
                diagnostics: &diagnostics)
            try Task.checkCancellation()
            await onDiagnostics(diagnostics.finish(.completed))
            try Task.checkCancellation()
            success = true
            return cues
        } catch {
            await onDiagnostics(diagnostics.finish(error is CancellationError || Task.isCancelled ? .cancelled : .failed))
            throw error
        }
    }

    private func publishDiagnostics(
        _ diagnostics: inout NativeQwenDiagnostics,
        nextStage: NativeQwenDiagnostics.Stage?,
        callback: @Sendable (NativeQwenDiagnostics.Snapshot) async -> Void
    ) async {
        diagnostics.transition(to: nil)
        await callback(diagnostics.snapshot(stage: nextStage))
        diagnostics.transition(to: nextStage)
    }

    private func transcribePreparedAudio(
        audioURL: URL,
        segments: [SubtitleSegment],
        timeOffset: Double,
        options: Options,
        checkpoint: @escaping @Sendable () async throws -> Void,
        onProgress: @escaping @Sendable (Double) async -> Void,
        onCue: @escaping @Sendable (SubtitleCue) async -> Void,
        onDiagnostics: @escaping @Sendable (NativeQwenDiagnostics.Snapshot) async -> Void,
        diagnostics: inout NativeQwenDiagnostics
    ) async throws -> [SubtitleCue] {
        try Task.checkCancellation()
        guard timeOffset.isFinite else { throw Failure.invalidSegment }
        // Empty VAD output is silence: do not load ASR or invent a full-file cue.
        guard !segments.isEmpty else { return [] }
        let pcm = try NativeQwenAudioSource(audioURL: audioURL, segments: segments)
        runtimeLibraryURL = try Self.checkRuntime(preferredLibrary: runtimeLibraryURL)
        let needsModel = modelPath != options.modelDirectory.path || model == nil
        diagnostics.modelCache = needsModel ? .miss : .hit
        if needsModel {
            await publishDiagnostics(&diagnostics, nextStage: .modelLoading, callback: onDiagnostics)
            try Task.checkCancellation()
            let configURL = options.modelDirectory.appending(path: "config.json")
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
            guard config?["model_type"] as? String == "qwen3_asr" else {
                throw Failure.missingResult
            }
            model = nil
            modelPath = nil
            Memory.clearCache()
            // Upstream generates tokenizer.json if absent. Use a writable staging
            // directory so installed model bundles and user weights stay untouched.
            let staging = FileManager.default.temporaryDirectory.appending(path: "msub-qwen-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            for source in try FileManager.default.contentsOfDirectory(at: options.modelDirectory, includingPropertiesForKeys: nil) {
                try FileManager.default.createSymbolicLink(at: staging.appending(path: source.lastPathComponent), withDestinationURL: source)
            }
            model = try await Qwen3ASRModel.fromModelDirectory(staging)
            modelPath = options.modelDirectory.path
        }
        try Task.checkCancellation()
        guard model != nil else { throw Failure.missingResult }
        await publishDiagnostics(&diagnostics, nextStage: .checkpoint, callback: onDiagnostics)
        var cues: [SubtitleCue] = []
        cues.reserveCapacity(segments.count)
        // PCM I/O can overlap GPU decoding. Keep only one next-segment task;
        // every range was validated before model loading. Pauses do not queue more reads.
        let firstRange = pcm.ranges[0]
        var pendingRead = Task { try await pcm.samples(in: firstRange) }
        do {
            for (index, range) in pcm.ranges.enumerated() {
                diagnostics.transition(to: .checkpoint)
                try await checkpoint()
                try Task.checkCancellation()
                diagnostics.transition(to: .preparation)
                let samples = try await pendingRead.value
                try Task.checkCancellation()
                if index + 1 < pcm.ranges.count {
                    let nextRange = pcm.ranges[index + 1]
                    pendingRead = Task { try await pcm.samples(in: nextRange) }
                }
                // Opt-in diagnostic only: at most two already validated 30-second
                // segments, once per request. It never feeds unvalidated features
                // into production decoding or runs concurrent model evaluations.
                if index == 0, pcm.ranges.count > 1,
                   ProcessInfo.processInfo.environment["MSUB_NATIVE_QWEN_ENCODER_PROBE"] == "1",
                   ProcessInfo.processInfo.physicalMemory >= 16 * 1024 * 1024 * 1024 {
                    diagnostics.transition(to: nil)
                    let nextSamples = try await pendingRead.value
                    try Task.checkCancellation()
                    profileEncoderBatch([samples, nextSamples])
                }
                if encodedSegments.isEmpty, options.optimizedDecodingEnabled,
                   ProcessInfo.processInfo.environment["MSUB_NATIVE_QWEN_STREAM_REFERENCE"] != "1",
                   (ProcessInfo.processInfo.environment["MSUB_NATIVE_QWEN_BATCH_SIZE"].map { $0 == "2" } ?? options.batchEncodingEnabled),
                   ProcessInfo.processInfo.physicalMemory >= 16 * 1024 * 1024 * 1024,
                   ProcessInfo.processInfo.systemUptime >= pressureCooldownUntil,
                   index + 1 < pcm.ranges.count {
                    let nextSamples = try await pendingRead.value
                    try Task.checkCancellation()
                    diagnostics.transition(to: .decoding)
                    prepareEncodedPair([samples, nextSamples])
                    try Task.checkCancellation()
                }
                // Capture only Sendable values. MLX model/arrays remain inside this
                // actor, including while the uncancelled task drains a segment.
                diagnostics.transition(to: .decoding)
                let decode = Task { [self] in
                    try await decodeSegment(samples: samples, options: options)
                }
                let finalText = try await decode.value
                try Task.checkCancellation()
                diagnostics.transition(to: .postprocessing)
                let text = Self.wrap(finalText.trimmingCharacters(in: .whitespacesAndNewlines), limit: options.lineCharacters)
                if !text.isEmpty {
                    let cue = SubtitleCue(
                        index: cues.count + 1,
                        start: Double(range.lowerBound) / 16000 + timeOffset,
                        end: Double(range.upperBound) / 16000 + timeOffset,
                        text: text, confidence: nil, speaker: nil
                    )
                    cues.append(cue)
                    diagnostics.transition(to: nil)
                    await onCue(cue)
                    try Task.checkCancellation()
                }
                diagnostics.completedSegments = index + 1
                diagnostics.transition(to: nil)
                await onProgress(Double(index + 1) / Double(segments.count))
                await publishDiagnostics(&diagnostics, nextStage: .checkpoint, callback: onDiagnostics)
            }
        } catch {
            // Drain the CPU reader as well as the existing bounded GPU decode.
            pendingRead.cancel()
            _ = await pendingRead.result
            throw error
        }
        return cues
    }

    private func decodeSegment(samples: [Float], options: Options) async throws -> String {
        guard let model else { throw Failure.missingResult }
        if !encodedSegments.isEmpty {
            let prepared = encodedSegments.removeFirst()
            // Match upstream per-segment allocator cleanup; retained encoder
            // features remain live while free transient decode buffers are dropped.
            defer { Memory.clearCache() }
            return try decodeWithRepetitionRecovery(prepared, model: model, options: options)
        }
        // Avoid per-token stream events/tokenizer work when the UI consumes
        // completed cues. Preserve upstream as a compatibility/reference path.
        if options.optimizedDecodingEnabled,
           ProcessInfo.processInfo.environment["MSUB_NATIVE_QWEN_STREAM_REFERENCE"] != "1",
           model.namedModules().contains(where: { $0.0 == "model.embed_tokens" && $0.1 is Embedding }) {
            let (features, mask, count) = model.preprocessAudio(MLXArray(samples))
            let encoded = model.getAudioFeatures(features, featureAttentionMask: mask)
            eval(encoded)
            if count > 0, encoded.dim(0) == count {
                defer { Memory.clearCache() }
                return try decodeWithRepetitionRecovery(EncodedSegment(features: encoded, tokenCount: count), model: model, options: options)
            }
        }
        let text = try await decodeStream(samples: samples, model: model, options: options)
        guard options.repetitionRecoveryEnabled, NativeQwenRepetition.hasPhraseLoop(text) else { return text }
        Self.performanceLog.notice("repetitionRetry path=stream")
        let retry = try await decodeStream(samples: samples, model: model, options: retryOptions(options))
        return NativeQwenRepetition.acceptsRetry(retry) ? retry : text
    }

    private func decodeStream(samples: [Float], model: Qwen3ASRModel, options: Options) async throws -> String {
        let input = MLXArray(samples)
        let started = ProcessInfo.processInfo.systemUptime
        let interval = Self.signposter.beginInterval("QwenSegment")
        defer { Self.signposter.endInterval("QwenSegment", interval) }
        var firstTextTime: TimeInterval?
        var finalText: String?
        for try await event in model.generateStream(
            audio: input, maxTokens: max(1, min(options.maxTokens, 8192)),
            temperature: 0, context: options.context, language: options.language,
            chunkDuration: 30, minChunkDuration: 0,
            repetitionPenalty: options.repetitionPenalty,
            repetitionContextSize: options.repetitionContextSize
        ) {
            switch event {
            case .token(let text) where !text.isEmpty:
                if firstTextTime == nil {
                    firstTextTime = ProcessInfo.processInfo.systemUptime
                    Self.signposter.emitEvent("QwenFirstText")
                }
            case .result(let result): finalText = result.text
            default: break
            }
        }
        let finished = ProcessInfo.processInfo.systemUptime
        // First text includes audio preprocessing, encoder, prefill and possibly
        // buffered language tokens. It is deliberately not labelled encoder time.
        if let firstTextTime {
            Self.performanceLog.info("segment seconds=\(finished - started) firstTextSeconds=\(firstTextTime - started) afterFirstTextSeconds=\(finished - firstTextTime)")
        } else {
            Self.performanceLog.info("segment seconds=\(finished - started) noTextEvent=true")
        }
        guard let finalText else { throw Failure.missingResult }
        return finalText
    }

    private func retryOptions(_ options: Options) -> Options {
        var retry = options
        retry.repetitionPenalty = max(1.15, options.repetitionPenalty)
        retry.repetitionContextSize = max(140, options.repetitionContextSize)
        return retry
    }

    private func decodeWithRepetitionRecovery(_ prepared: EncodedSegment, model: Qwen3ASRModel, options: Options) throws -> String {
        let text = try decodePrepared(prepared, model: model, options: options)
        guard options.repetitionRecoveryEnabled, NativeQwenRepetition.hasPhraseLoop(text) else { return text }
        Self.performanceLog.notice("repetitionRetry path=prepared")
        // Same audio encoder features, fresh decoder/KV cache, at most one retry.
        let retry = try decodePrepared(prepared, model: model, options: retryOptions(options))
        let accepted = NativeQwenRepetition.acceptsRetry(retry)
        Self.performanceLog.notice("repetitionRetry accepted=\(accepted)")
        return accepted ? retry : text
    }

    private func prepareEncodedPair(_ samples: [[Float]]) {
        guard let model, samples.count == 2,
              samples.allSatisfy({ !$0.isEmpty && $0.count <= 480_000 }),
              model.namedModules().contains(where: { $0.0 == "model.embed_tokens" && $0.1 is Embedding }) else { return }
        let interval = Self.signposter.beginInterval("QwenBatchEncoder")
        defer { Self.signposter.endInterval("QwenBatchEncoder", interval) }
        let prepared = samples.map { model.preprocessAudio(MLXArray($0)) }
        let frames = prepared.map { $0.0.dim(2) }.max() ?? 0
        let features = MLX.concatenated(prepared.map {
            MLX.padded($0.0, widths: [IntOrPair((0, 0)), IntOrPair((0, 0)), IntOrPair((0, frames - $0.0.dim(2)))])
        }, axis: 0)
        let masks = MLX.concatenated(prepared.map {
            MLX.padded($0.1, widths: [IntOrPair((0, 0)), IntOrPair((0, frames - $0.1.dim(1)))])
        }, axis: 0)
        let output = model.getAudioFeatures(features, featureAttentionMask: masks)
        eval(output)
        let counts = prepared.map { $0.2 }
        guard counts.allSatisfy({ $0 > 0 }), output.dim(0) == counts.reduce(0, +) else {
            Self.performanceLog.notice("batchEncoder fallback=featureCountMismatch")
            return
        }
        encodedSegments = [EncodedSegment(features: output[0..<counts[0]], tokenCount: counts[0]),
                           EncodedSegment(features: output[counts[0]..<(counts[0] + counts[1])], tokenCount: counts[1])]
    }

    /// Narrow greedy adapter for the pinned upstream Qwen stream contract:
    /// temperature=0, sign-aware recent-token penalty, same EOS/backstop policy.
    /// Public module lookup preserves quantized Embedding subclasses as well.
    private func decodePrepared(_ prepared: EncodedSegment, model: Qwen3ASRModel, options: Options) throws -> String {
        guard let tokenizer = model.tokenizer,
              let embedding = model.namedModules().first(where: { $0.0 == "model.embed_tokens" })?.1 as? Embedding else {
            throw Failure.missingResult
        }
        let ids = model.buildPrompt(numAudioTokens: prepared.tokenCount, context: options.context, language: options.language)
        let embeddings = embedding(ids)
        let merged = model.mergeAudioFeatures(inputsEmbeds: embeddings,
            audioFeatures: prepared.features.asType(embeddings.dtype), inputIds: ids)
        let cache = model.makeCache()
        let started = ProcessInfo.processInfo.systemUptime
        let prefillInterval = Self.signposter.beginInterval("QwenPreparedPrefill")
        let logits = model.callAsFunction(inputIds: ids, inputEmbeddings: merged, cache: cache)
        var nextToken = logits[0..., -1, 0...].argMax(axis: -1)
        eval(nextToken)
        Self.signposter.endInterval("QwenPreparedPrefill", prefillInterval)
        let prefillSeconds = ProcessInfo.processInfo.systemUptime - started
        let decodeInterval = Self.signposter.beginInterval("QwenPreparedDecode")
        defer { Self.signposter.endInterval("QwenPreparedDecode", decodeInterval) }
        var tokens: [Int] = []
        let tokenLimit = max(1, min(options.maxTokens, 8192))
        for _ in 0..<tokenLimit {
            try Task.checkCancellation()
            let next = nextToken.item(Int.self)
            if next == 151645 || next == 151643 { break }
            tokens.append(next)
            if options.repetitionPenalty == 1, tokens.count >= 24, Set(tokens.suffix(24)).count <= 3 { break }
            // The final allowed token needs no unused forward pass. Keep the
            // selected token on device and evaluate selection with the next pass,
            // rather than synchronizing logits then launching a separate argmax.
            if tokens.count == tokenLimit { break }
            let logits = model.callAsFunction(inputIds: nextToken.asType(.int32).expandedDimensions(axis: 0), cache: cache)
            let adjusted = Self.penalizedLogits(logits[0..., -1, 0...], tokens: tokens,
                penalty: options.repetitionPenalty, contextSize: options.repetitionContextSize)
            nextToken = adjusted.argMax(axis: -1)
            eval(nextToken)
        }
        Self.performanceLog.info("preparedDecode prefillSeconds=\(prefillSeconds) generationSeconds=\(ProcessInfo.processInfo.systemUptime - started - prefillSeconds) tokenCount=\(tokens.count)")
        let text = tokenizer.decode(tokens: tokens).trimmingCharacters(in: .whitespacesAndNewlines)
        if options.language == nil, text.hasPrefix("language "), let marker = text.range(of: "<asr_text>") {
            return String(text[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Positive scores are divided, negative scores multiplied: dividing a
    /// negative logit would encourage repetition. Only this segment's emitted
    /// tokens participate; never penalize the prompt or neighboring subtitles.
    static func penalizedLogits(_ logits: MLXArray, tokens: [Int], penalty: Float, contextSize: Int) -> MLXArray {
        guard penalty.isFinite, penalty > 0, penalty != 1, !tokens.isEmpty else { return logits }
        let recent = Array(Set(tokens.suffix(max(1, contextSize)))).sorted().map { Int32($0) }
        let indices = MLXArray(recent)
        let scores = logits[0..., indices]
        let adjusted = MLX.where(scores .> 0, scores / penalty, scores * penalty)
        // MLX arrays use reference semantics; detach the container before indexed
        // assignment so callers retain their original unmodified logits.
        let result = logits[0...]
        result[0..., indices] = adjusted
        return result
    }

    private func profileEncoderBatch(_ samples: [[Float]]) {
        guard let model, samples.count == 2,
              samples.allSatisfy({ !$0.isEmpty && $0.count <= 480_000 }) else { return }
        let interval = Self.signposter.beginInterval("QwenEncoderProbe")
        defer { Self.signposter.endInterval("QwenEncoderProbe", interval) }
        var features: [MLXArray] = []
        var masks: [MLXArray] = []
        var reference: [MLXArray] = []
        var preparationSeconds: Double = 0
        var sequentialSeconds: Double = 0
        for pcm in samples {
            let preparationStart = ProcessInfo.processInfo.systemUptime
            let (feature, mask, _) = model.preprocessAudio(MLXArray(pcm))
            eval(feature, mask)
            preparationSeconds += ProcessInfo.processInfo.systemUptime - preparationStart
            features.append(feature)
            masks.append(mask)
            let start = ProcessInfo.processInfo.systemUptime
            let output = model.getAudioFeatures(feature, featureAttentionMask: mask)
            eval(output)
            sequentialSeconds += ProcessInfo.processInfo.systemUptime - start
            reference.append(output)
        }
        let frames = features.map { $0.dim(2) }.max() ?? 0
        let paddedFeatures = features.map {
            MLX.padded($0, widths: [IntOrPair((0, 0)), IntOrPair((0, 0)), IntOrPair((0, frames - $0.dim(2)))])
        }
        let paddedMasks = masks.map {
            MLX.padded($0, widths: [IntOrPair((0, 0)), IntOrPair((0, frames - $0.dim(1)))])
        }
        let featureBatch = MLX.concatenated(paddedFeatures, axis: 0)
        let maskBatch = MLX.concatenated(paddedMasks, axis: 0)
        eval(featureBatch, maskBatch)
        let start = ProcessInfo.processInfo.systemUptime
        let actual = model.getAudioFeatures(featureBatch, featureAttentionMask: maskBatch)
        eval(actual)
        let batchSeconds = ProcessInfo.processInfo.systemUptime - start
        let expected = MLX.concatenated(reference, axis: 0)
        guard actual.shape == expected.shape else {
            Self.performanceLog.error("encoderProbe batchShapeMismatch=true")
            return
        }
        let maxError = MLX.max(MLX.abs(actual.asType(.float32) - expected.asType(.float32))).item(Float.self)
        Self.performanceLog.info("encoderProbe samples=2 preparationSeconds=\(preparationSeconds) sequentialSeconds=\(sequentialSeconds) batchSeconds=\(batchSeconds) maxFeatureError=\(maxError) processPeakBytes=\(Memory.peakMemory)")
    }

    /// Cue re-recognition can use AVFoundation directly, without a Python job.
    /// The bounded clip has its own zero-based timeline; the editor keeps the
    /// original cue's timing and replaces only the recognized text.
    func transcribeClip(audioURL: URL, options: Options) async throws -> [SubtitleCue] {
        guard !residency.busy else { throw Failure.busy }
        try Task.checkCancellation()
        let input = try AVAudioFile(forReading: audioURL)
        let duration = Double(input.length) / input.processingFormat.sampleRate
        _ = try Self.sampleRange(start: 0, end: duration, duration: duration)
        if input.processingFormat.sampleRate == 16000, input.processingFormat.channelCount == 1 {
            return try await transcribe(
                audioURL: audioURL,
                segments: [SubtitleSegment(index: 1, start: 0, end: duration, duration: duration)],
                timeOffset: 0, options: options,
                checkpoint: { try Task.checkCancellation() }, onProgress: { _ in })
        }
        guard let source = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(duration * 16000) + 1024)) else {
            throw Failure.invalidAudio
        }
        try input.read(into: source)
        let inputSource = ConversionInput(source)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            inputSource.next(status)
        }
        if let conversionError { throw conversionError }
        guard status != .error, output.frameLength > 0 else { throw Failure.invalidAudio }
        let wav = FileManager.default.temporaryDirectory.appending(path: "msub-native-cue-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        do {
            let writer = try AVAudioFile(forWriting: wav, settings: format.settings)
            try writer.write(from: output)
        }
        let convertedDuration = Double(output.frameLength) / 16000
        return try await transcribe(
            audioURL: wav,
            segments: [SubtitleSegment(index: 1, start: 0, end: convertedDuration, duration: convertedDuration)],
            timeOffset: 0, options: options,
            checkpoint: { try Task.checkCancellation() }, onProgress: { _ in }
        )
    }

    /// Owns the buffer exclusively after reading. The converter receives it at
    /// most once; neither the caller nor a second callback can mutate it.
    private final class ConversionInput: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: AVAudioPCMBuffer?

        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            lock.lock()
            defer { lock.unlock() }
            guard let buffer else {
                status.pointee = .endOfStream
                return nil
            }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }

    nonisolated static func sampleRange(start: Double, end: Double, duration: Double) throws -> Range<Int> {
        guard start.isFinite, end.isFinite, duration.isFinite,
              duration < Double(Int.max / 16000),
              start >= 0, end > start, end - start <= 30.001,
              start < duration, end <= duration + 0.05 else { throw Failure.invalidSegment }
        let lower = Int((start * 16000).rounded())
        let upper = Int((min(end, duration) * 16000).rounded())
        guard upper > lower else { throw Failure.invalidSegment }
        return lower..<upper
    }

    /// MLX aborts rather than throws when its default metallib is absent. Check
    /// the packaged resources before the first MLX call so fallback stays safe.
    nonisolated static func checkRuntime(preferredLibrary: URL? = nil) throws -> URL {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.runtimeUnavailable }
        let library = NativeMLXLibrarySearch.find(preferred: preferredLibrary, candidates: {
            let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
            let bundles = Bundle.allBundles
            let roots = [Bundle.main.bundleURL, Bundle.main.resourceURL, executableDirectory].compactMap { $0 }
                + bundles.compactMap(\.resourceURL)
                + bundles.compactMap { $0.executableURL?.deletingLastPathComponent() }
            return roots.flatMap { root in
                ["mlx.metallib", "Resources/mlx.metallib", "Resources/default.metallib",
                 "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib",
                 "mlx-swift_Cmlx.bundle/default.metallib"].map { root.appending(path: $0) }
            }
        }, load: { (try? device.makeLibrary(URL: $0)) != nil })
        guard let library else {
            throw Failure.runtimeUnavailable
        }
        return library
    }

    nonisolated static func wrap(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return text }
        // Preserve words in space-separated scripts; split CJK at Characters,
        // never UTF-16 offsets (which can cut emoji or combining sequences).
        return text.components(separatedBy: .newlines).map { paragraph in
            var lines: [String] = []
            var line = ""
            let tokens = paragraph.contains(" ") ? paragraph.split(separator: " ").map(String.init) : paragraph.map(String.init)
            let separator = paragraph.contains(" ") ? " " : ""
            for token in tokens {
                if !line.isEmpty && line.count + separator.count + token.count > limit {
                    lines.append(line)
                    line = ""
                }
                if !line.isEmpty { line += separator }
                line += token
            }
            if !line.isEmpty { lines.append(line) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}
