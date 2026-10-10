import Accelerate
import AVFoundation
import CoreML
import Foundation

/// Fixed FireRed/Kaldi contract: PCM16, 16 kHz, 400-sample Povey windows,
/// 160-sample shift, 512-point FFT, 80 log-mel bins and model-provided CMVN.
/// Algorithm reference: csukuangfj/kaldi-native-fbank (Apache-2.0).
final class FireRedFilterbank {
    enum Failure: LocalizedError {
        case invalidCMVN, unavailableFFT, invalidAudio(String), invalidModel, invalidOptions, busy

        var errorDescription: String? {
            switch self {
            case .invalidCMVN: "FireRedVAD: invalid CMVN statistics."
            case .unavailableFFT: "FireRedVAD: could not create FFT setup."
            case .invalidAudio(let detail): "FireRedVAD: \(detail)."
            case .invalidModel: "FireRedVAD: unexpected model output."
            case .invalidOptions: "FireRedVAD: unsupported segmentation options."
            case .busy: "FireRedVAD: another native request is running."
            }
        }
    }
    private let fft: vDSP_DFT_Setup
    private let window: [Float]
    private let banks: [[(Int, Float)]]
    private let means: [Float]
    private let scales: [Float]

    convenience init(cmvn: URL) throws {
        try self.init(cmvnData: Data(contentsOf: cmvn))
    }

    init(cmvnData data: Data) throws {
        guard data.count >= 15, data[0] == 0, data[1] == 66,
              data[4] == 32, data[5] == 4, data[10] == 4 else { throw Failure.invalidCMVN }
        let token = String(decoding: data[2..<4], as: UTF8.self)
        guard token == "DM" || token == "FM" else { throw Failure.invalidCMVN }
        let rows = data.withUnsafeBytes { Int(Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 6, as: Int32.self))) }
        let columns = data.withUnsafeBytes { Int(Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 11, as: Int32.self))) }
        let width = token == "DM" ? 8 : 4
        guard rows == 2, columns == 81, data.count == 15 + rows * columns * width else { throw Failure.invalidCMVN }
        let values: [Double] = data.withUnsafeBytes { bytes in
            (0..<162).map { i in
                if width == 8 { return Double(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 15 + i * 8, as: UInt64.self))) }
                return Double(Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 15 + i * 4, as: UInt32.self))))
            }
        }
        let count = values[80]
        guard values.allSatisfy(\.isFinite), count >= 1 else { throw Failure.invalidCMVN }
        let computedMeans = (0..<80).map { Float(values[$0] / count) }
        let computedScales = (0..<80).map { i in
            let mean = values[i] / count
            return Float(1 / sqrt(max(values[81 + i] / count - mean * mean, 1e-20)))
        }
        guard computedMeans.allSatisfy(\.isFinite), computedScales.allSatisfy(\.isFinite) else { throw Failure.invalidCMVN }
        means = computedMeans
        scales = computedScales
        window = (0..<400).map { Float(pow(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 399), 0.85)) }
        func mel(_ hz: Float) -> Float { 1127 * logf(1 + hz / 700) }
        let low = mel(20), step = (mel(8000) - mel(20)) / 81
        banks = (0..<80).map { bin in
            let left = low + Float(bin) * step
            let center = low + Float(bin + 1) * step
            let right = low + Float(bin + 2) * step
            return (0..<256).compactMap { i in
                let value = mel(Float(i) * 31.25)
                guard value > left, value < right else { return nil }
                let weight = value <= center ? (value - left) / (center - left) : (right - value) / (right - center)
                return (i, weight)
            }
        }
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, 512, .FORWARD) else { throw Failure.unavailableFFT }
        fft = setup
    }

    deinit { vDSP_DFT_DestroySetup(fft) }

    func features(_ samples: UnsafeBufferPointer<Int16>, frames: Int) throws -> [Float] {
        guard frames >= 0, samples.count >= 240, frames <= (samples.count - 240) / 160 else {
            throw Failure.invalidAudio("samples=\(samples.count), frames=\(frames)")
        }
        var result = [Float](); result.reserveCapacity(frames * 80)
        var real = [Float](repeating: 0, count: 512)
        let imaginary = [Float](repeating: 0, count: 512)
        var outReal = real, outImaginary = real
        var power = [Float](repeating: 0, count: 256)
        for frame in 0..<frames {
            try Task.checkCancellation()
            var sum: Float = 0
            for i in 0..<400 { real[i] = Float(samples[frame * 160 + i]); sum += real[i] }
            let mean = sum / 400
            for i in 0..<400 { real[i] -= mean }
            for i in stride(from: 399, through: 1, by: -1) { real[i] -= 0.97 * real[i - 1] }
            real[0] -= 0.97 * real[0]
            for i in 0..<400 { real[i] *= window[i] }
            vDSP_DFT_Execute(fft, real, imaginary, &outReal, &outImaginary)
            for i in 0..<256 { power[i] = outReal[i] * outReal[i] + outImaginary[i] * outImaginary[i] }
            for bin in 0..<80 {
                var energy: Float = 0
                for (index, weight) in banks[bin] { energy += power[index] * weight }
                result.append((logf(max(energy, Float.ulpOfOne)) - means[bin]) * scales[bin])
            }
        }
        return result
    }
}

/// Single-entry cache owned by NativeFireRedVAD. Compare the small CMVN file
/// contents, not just timestamps, so replaced normalization statistics reload.
final class FireRedFilterbankCache {
    private var source: URL?
    private var data: Data?
    private var filterbank: FireRedFilterbank?

    func value(cmvn: URL) throws -> FireRedFilterbank {
        let source = cmvn.standardizedFileURL
        let data = try Data(contentsOf: source)
        if self.source == source, self.data == data, let filterbank { return filterbank }
        let filterbank = try FireRedFilterbank(cmvnData: data)
        self.source = source
        self.data = data
        self.filterbank = filterbank
        return filterbank
    }
}

struct FireRedVADOptions: Codable, Sendable {
    var threshold = 0.4
    var smoothWindow = 5
    var minSpeech = 0.2
    var minSilence = 0.3
    var padding = 0.1
    var maxSegment = 20.0
    var minSegment = 1.0
    var splitSearch = 2.0

    // Restrict the experimental route before allocating smoothing buffers or
    // converting durations to frame counts. Other settings retain Python.
    var isSupported: Bool {
        threshold.isFinite && (0...1).contains(threshold)
            && (1...10_000).contains(smoothWindow)
            && maxSegment.isFinite && (0.1...30).contains(maxSegment)
            && [minSpeech, minSilence, padding, minSegment, splitSearch].allSatisfy {
                $0.isFinite && (0...3600).contains($0)
            }
    }
}

struct FireRedSpeechRange: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
}

actor NativeFireRedVAD {
    static let shared = NativeFireRedVAD()
    private var busy = false
    private let filterbankCache = FireRedFilterbankCache()
    private var loadedKey: String?
    private var loadedModel: MLModel?
    private var compiledURL: URL?

    deinit { if let compiledURL { try? FileManager.default.removeItem(at: compiledURL) } }

    func segments(audio: URL, modelDirectory: URL, options: FireRedVADOptions,
                  checkpoint: @Sendable () async throws -> Void = {},
                  progress: @Sendable (Double) async -> Void = { _ in }) async throws -> [FireRedSpeechRange] {
        guard options.isSupported else { throw FireRedFilterbank.Failure.invalidOptions }
        let result = try await probabilities(audio: audio, modelDirectory: modelDirectory,
                                             checkpoint: checkpoint, progress: progress)
        try await checkpoint()
        try Task.checkCancellation()
        // Keep both inference and linear-time boundary cleanup off MainActor.
        let ranges = FireRedVADSegmentation.ranges(probabilities: result.values, duration: result.duration, options: options)
        try Task.checkCancellation()
        return ranges
    }

    func probabilities(audio: URL, modelDirectory: URL,
                       checkpoint: @Sendable () async throws -> Void = {},
                       progress: @Sendable (Double) async -> Void = { _ in }) async throws -> (values: [Float], duration: Double) {
        guard !busy else { throw FireRedFilterbank.Failure.busy }
        busy = true
        defer { busy = false }
        try await checkpoint()
        try Task.checkCancellation()
        let input = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatInt16, interleaved: false)
        guard input.fileFormat.sampleRate == 16000, input.fileFormat.channelCount == 1,
              input.fileFormat.commonFormat == .pcmFormatInt16 else {
            throw FireRedFilterbank.Failure.invalidAudio("Expected 16 kHz mono PCM16 audio")
        }
        let duration = Double(input.length) / 16000
        guard input.length >= 400 else { return ([], duration) }
        let totalFrames = Int((input.length - 400) / 160 + 1)
        let fbank = try filterbankCache.value(cmvn: modelDirectory.appending(path: "cmvn.ark"))
        let model = try await model(at: modelDirectory.appending(path: "FireRedVAD.mlpackage"))
        var caches = [String: MLFeatureValue]()
        for i in 0..<8 {
            let array = try MLMultiArray(shape: [1, 128, 19], dataType: .float32)
            array.dataPointer.assumingMemoryBound(to: Float.self).initialize(repeating: 0, count: array.count)
            caches["cache_\(i)"] = MLFeatureValue(multiArray: array)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 512 * 160 + 240) else {
            throw FireRedFilterbank.Failure.invalidAudio("Could not allocate PCM buffer")
        }
        var probabilities: [Float] = []; probabilities.reserveCapacity(totalFrames)
        var retained: [Int16] = []
        for start in stride(from: 0, to: totalFrames, by: 512) {
            try await checkpoint()
            try Task.checkCancellation()
            let count = min(512, totalFrames - start)
            // Read sequentially, retaining the 240-sample overlap. AVAudioFile
            // may return a short read; fill the batch before extracting frames.
            var samples = retained
            let needed = count * 160 + 240
            while samples.count < needed {
                try Task.checkCancellation()
                try input.read(into: buffer, frameCount: AVAudioFrameCount(needed - samples.count))
                guard buffer.frameLength > 0, let pointer = buffer.int16ChannelData?[0] else {
                    throw FireRedFilterbank.Failure.invalidAudio("Unexpected end of PCM stream")
                }
                samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength)))
            }
            let values = try samples.withUnsafeBufferPointer { try fbank.features($0, frames: count) }
            retained = Array(samples.suffix(240))
            let features = try MLMultiArray(shape: [1, NSNumber(value: count), 80], dataType: .float32)
            values.withUnsafeBufferPointer { src in
                features.dataPointer.assumingMemoryBound(to: Float.self).update(from: src.baseAddress!, count: values.count)
            }
            var dictionary = caches
            dictionary["feat"] = MLFeatureValue(multiArray: features)
            let prediction = try predict(model, inputs: dictionary)
            guard let output = prediction.featureValue(for: "probs")?.multiArrayValue,
                  output.count == count else { throw FireRedFilterbank.Failure.invalidModel }
            for i in 0..<count {
                let value = output[i].floatValue
                guard value.isFinite else { throw FireRedFilterbank.Failure.invalidModel }
                probabilities.append(value)
            }
            for i in 0..<8 {
                guard let value = prediction.featureValue(for: "new_cache_\(i)"),
                      value.multiArrayValue?.shape == [1, 128, 19] else { throw FireRedFilterbank.Failure.invalidModel }
                caches["cache_\(i)"] = value
            }
            await progress(Double(start + count) / Double(totalFrames))
        }
        try Task.checkCancellation()
        return (probabilities, duration)
    }

    // Keep the cached non-Sendable model on this actor. Each synchronous
    // prediction is bounded to 512 frames, with cancellation between batches.
    private func predict(_ model: MLModel, inputs: [String: MLFeatureValue]) throws -> MLFeatureProvider {
        try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
    }

    private func model(at package: URL) async throws -> MLModel {
        let paths = ["Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]
        var key = package.standardizedFileURL.path
        for path in paths {
            let attributes = try FileManager.default.attributesOfItem(atPath: package.appending(path: path).path)
            key += "#\(attributes[.size] ?? 0)#\(attributes[.modificationDate] ?? Date.distantPast)"
        }
        if key == loadedKey, let loadedModel { return loadedModel }
        let compiled = try await MLModel.compileModel(at: package)
        var installed = false
        defer { if !installed { try? FileManager.default.removeItem(at: compiled) } }
        try Task.checkCancellation()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        loadedModel = nil
        if let compiledURL { try? FileManager.default.removeItem(at: compiledURL) }
        compiledURL = compiled
        loadedModel = model
        loadedKey = key
        installed = true
        return model
    }
}

/// Mirrors the existing stream state machine and subsequent range cleanup in cli.py.
/// Only sample probabilities cross the actor boundary; Core ML state stays private.
enum FireRedVADSegmentation {
    private static func rounded(_ value: Double) -> Double { (value * 1000).rounded(.toNearestOrEven) / 1000 }

    static func ranges(probabilities: [Float], duration: Double, options o: FireRedVADOptions) -> [FireRedSpeechRange] {
        guard o.isSupported, !probabilities.isEmpty, probabilities.allSatisfy(\.isFinite),
              duration.isFinite, duration > 0 else { return [] }
        let windowSize = max(1, o.smoothWindow)
        let minimumSpeech = max(1, Int(ceil(o.minSpeech / 0.01)))
        let minimumSilence = max(1, Int(ceil(o.minSilence / 0.01)))
        let maximumSpeech = max(minimumSpeech, Int(ceil(max(o.maxSegment, 20) / 0.01)))
        enum State { case silence, possibleSpeech, speech, possibleSilence }
        var state = State.silence
        var speechCount = 0, silenceCount = 0, lastStart = -1, lastEnd = -1
        var hitMaximum = false
        var smoothed: [Float] = []; smoothed.reserveCapacity(probabilities.count)
        var ring = [Double](repeating: 0, count: windowSize)
        var sum = 0.0
        var ranges: [FireRedSpeechRange] = []
        func append(_ end: Int) {
            let startTime = max(0, Double(lastStart - 1) * 0.01)
            let endTime = min(duration, max(0, Double(end - 1) * 0.01))
            if endTime - startTime > 0.05 { ranges.append(.init(start: startTime, end: endTime)) }
        }
        for (offset, raw) in probabilities.enumerated() {
            let frame = offset + 1
            let value = min(1, max(0, Double(raw)))
            let position = offset % windowSize
            // Preserve Python's add-then-subtract order for threshold parity.
            sum += value
            if offset >= windowSize { sum -= ring[position] }
            ring[position] = value
            let smooth = sum / Double(min(frame, windowSize))
            smoothed.append(Float(smooth))
            let speech = smooth >= o.threshold
            if hitMaximum { lastStart = frame; hitMaximum = false }
            switch state {
            case .silence:
                if speech { state = .possibleSpeech; speechCount += 1 }
                else { silenceCount += 1; speechCount = 0 }
            case .possibleSpeech:
                if speech {
                    speechCount += 1
                    if speechCount >= minimumSpeech {
                        state = .speech
                        lastStart = max(1, frame - speechCount + 1 - max(windowSize, 5), lastEnd + 1)
                        silenceCount = 0
                    }
                } else { state = .silence; silenceCount = 1; speechCount = 0 }
            case .speech, .possibleSilence:
                speechCount += 1
                if speech {
                    state = .speech
                    silenceCount = 0
                    if speechCount >= maximumSpeech {
                        append(frame)
                        hitMaximum = true; speechCount = 0; lastEnd = frame; lastStart = -1
                    }
                } else if state == .speech {
                    state = .possibleSilence; silenceCount += 1
                } else {
                    silenceCount += 1
                    if silenceCount >= minimumSilence {
                        state = .silence
                        if lastStart > 0 { append(frame) }
                        lastEnd = frame; lastStart = -1; speechCount = 0
                    }
                }
            }
        }
        if lastStart > 0 { append(probabilities.count) }
        ranges = ranges.map { .init(start: max(0, $0.start - o.padding), end: min(duration, $0.end + o.padding)) }
        var merged: [FireRedSpeechRange] = []
        for range in ranges {
            if let last = merged.last, range.start - last.end <= o.minSilence {
                merged[merged.count - 1].end = max(last.end, range.end)
            } else { merged.append(range) }
        }
        let split = split(merged, options: o, probabilities: smoothed, search: o.splitSearch)
        var trimmed: [FireRedSpeechRange] = []
        // NumPy compares the float32 array to a float32-cast threshold.
        let threshold = Float(o.threshold)
        for range in split {
            let lo = max(0, Int(floor(range.start / 0.01)))
            let hi = min(smoothed.count, Int(ceil(range.end / 0.01)))
            guard hi > lo,
                  let first = (lo..<hi).first(where: { smoothed[$0] >= threshold }),
                  let last = (lo..<hi).last(where: { smoothed[$0] >= threshold }) else { continue }
            let start = max(range.start, Double(first) * 0.01 - o.padding)
            let end = min(range.end, Double(last + 1) * 0.01 + o.padding)
            if end - start > 0.05 { trimmed.append(.init(start: rounded(start), end: rounded(end))) }
        }
        let strict = preventOverlaps(self.split(preventOverlaps(trimmed), options: o, probabilities: smoothed, search: 0))
        guard o.maxSegment > 0, strict.count > 1 else { return strict }
        // Preserve the backend's legacy default treatment of a zero setting.
        let minSegment = o.minSegment == 0 ? 0.8 : o.minSegment
        let minSilence = o.minSilence == 0 ? 0.28 : o.minSilence
        let mergeGap = max(0.75, minSilence + o.padding * 2 + 0.08)
        let tightGap = max(0.32, minSilence + min(0.12, o.padding))
        let shortTail = max(2.2, minSegment * 3)
        merged = []
        for range in strict {
            if let last = merged.last {
                let gap = range.start - last.end
                let short = min(last.end - last.start, range.end - range.start) <= shortTail
                if gap >= -0.001, gap <= mergeGap, range.end - last.start <= o.maxSegment + 1e-6,
                   short || gap <= tightGap {
                    merged[merged.count - 1].end = range.end
                    continue
                }
            }
            merged.append(range)
        }
        return preventOverlaps(merged)
    }

    private static func split(_ ranges: [FireRedSpeechRange], options o: FireRedVADOptions,
                              probabilities: [Float], search: Double) -> [FireRedSpeechRange] {
        guard o.maxSegment > 0 else { return ranges }
        var result: [FireRedSpeechRange] = []
        for range in ranges {
            var boundaries = [range.start], cursor = range.start
            while range.end - cursor > o.maxSegment {
                let target = cursor + o.maxSegment
                let low = cursor + max(0.05, o.minSegment)
                let high = range.end - max(0.05, o.minSegment)
                if target >= high {
                    if high > low { boundaries.append(rounded(high)) }
                    break
                }
                var cut = target
                if search > 0 {
                    let windowStart = max(low, target - search)
                    let windowEnd = min(high, target)
                    let lo = max(0, Int(windowStart / 0.01))
                    let hi = min(probabilities.count, Int(ceil(windowEnd / 0.01)))
                    if windowEnd > windowStart, hi > lo {
                        var best = lo
                        for i in (lo + 1)..<hi where probabilities[i] < probabilities[best] { best = i }
                        cut = rounded(Double(best) * 0.01)
                    }
                }
                if cut <= low || cut >= high { cut = target }
                boundaries.append(cut); cursor = cut
            }
            boundaries.append(range.end)
            for i in 1..<boundaries.count {
                let start = boundaries[i - 1], end = boundaries[i]
                guard end - start > 0.05 else { continue }
                if let last = result.last, o.minSegment > 0, end - start < o.minSegment - 1e-6,
                   abs(last.end - start) < 0.001 {
                    result[result.count - 1].end = end
                } else { result.append(.init(start: start, end: end)) }
            }
        }
        return result
    }

    private static func preventOverlaps(_ ranges: [FireRedSpeechRange]) -> [FireRedSpeechRange] {
        guard let first = ranges.first else { return [] }
        var result = [first]
        for var range in ranges.dropFirst() {
            let last = result[result.count - 1]
            if range.start < last.end {
                let midpoint = rounded((range.start + last.end) / 2)
                result[result.count - 1].end = max(last.start + 0.05, midpoint)
                range.start = min(range.end - 0.05, midpoint)
            }
            if range.end - range.start > 0.05 { result.append(range) }
        }
        return result
    }
}
