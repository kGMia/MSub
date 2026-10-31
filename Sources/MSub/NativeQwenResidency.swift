import Foundation

/// Lifecycle bookkeeping independent of MLX so races can be checked without GPU weights.
struct NativeQwenResidency {
    private(set) var generation: UInt64 = 0
    private(set) var busy = false
    private var releasePending = false

    mutating func begin() -> Bool {
        guard !busy else { return false }
        generation &+= 1
        busy = true
        releasePending = false
        return true
    }

    /// Returns true only when it is safe to drop the model now.
    mutating func requestRelease() -> Bool {
        generation &+= 1
        releasePending = busy
        return !busy
    }

    mutating func finish(success: Bool) -> Bool {
        busy = false
        let retain = success && !releasePending
        releasePending = false
        return retain
    }

    func canExpire(generation: UInt64) -> Bool {
        !busy && self.generation == generation
    }

    static func idleSeconds(environment: [String: String], physicalMemory: UInt64) -> TimeInterval {
        // Smaller unified-memory Macs release immediately unless explicitly opted in.
        let defaultSeconds: Double = physicalMemory >= 16 * 1024 * 1024 * 1024 ? 45 : 0
        guard let raw = environment["MSUB_NATIVE_QWEN_IDLE_SECONDS"],
              let value = Double(raw), value.isFinite else { return defaultSeconds }
        return min(120, max(0, value))
    }
}

/// Immutable source ownership; GCD serializes event delivery and cancel is thread-safe.
final class NativeQwenMemoryPressureMonitor: @unchecked Sendable {
    private let source: any DispatchSourceMemoryPressure

    init(onPressure: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                         queue: .global(qos: .utility))
        source.setEventHandler(handler: onPressure)
        source.resume()
    }

    deinit { source.cancel() }
}
