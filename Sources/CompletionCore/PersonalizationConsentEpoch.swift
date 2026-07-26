import Foundation

public final class PersonalizationConsentEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64

    public init(generation: UInt64 = 0) {
        self.generation = generation
    }

    public var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    public func advance(to generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        self.generation = max(self.generation, generation)
    }

    public func advance(
        to generation: UInt64,
        performing action: () -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        action()
        self.generation = max(self.generation, generation)
    }

    public func performIfCurrent(
        _ expectedGeneration: UInt64,
        _ action: () throws -> Void
    ) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration else { return false }
        try action()
        return true
    }
}
