import CompletionCore
import Foundation
import XCTest

private actor RequestProbe {
    private var started: [String] = []
    private var delivered: [String] = []
    private var releaseFirst: CheckedContinuation<Void, Never>?

    func operation(_ request: String) async -> String {
        started.append(request)
        if request == "first" {
            await withCheckedContinuation { releaseFirst = $0 }
        }
        return request.uppercased()
    }

    func deliver(_ value: String) {
        delivered.append(value)
    }

    func releaseBlockedRequest() {
        releaseFirst?.resume()
        releaseFirst = nil
    }

    func snapshot() -> (started: [String], delivered: [String]) {
        (started, delivered)
    }
}

final class LatestRequestPumpTests: XCTestCase {
    func testCollapsesRapidRequests() async {
        let probe = RequestProbe()
        let pump = LatestRequestPump<String, String>(
            operation: { request in await probe.operation(request) },
            deliver: { value in await probe.deliver(value) }
        )

        await pump.submit("first")

        for _ in 0..<100 {
            if await probe.snapshot().started == ["first"] {
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }

        await pump.submit("second")
        await pump.submit("third")
        await probe.releaseBlockedRequest()

        for _ in 0..<100 {
            let snapshot = await probe.snapshot()
            if snapshot.delivered == ["THIRD"] {
                XCTAssertEqual(snapshot.started, ["first", "third"])
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTFail("Timed out waiting for the newest request")
    }

    func testDeliversStreamingUpdatesBeforeTheRequestFinishes() async {
        let probe = StreamingRequestProbe()
        let pump = LatestStreamPump<String, String>(
            operation: { request in await probe.stream(for: request) },
            deliver: { value in await probe.deliver(value) }
        )

        await pump.submit("first")
        await probe.waitUntilStarted("first")
        await probe.yield("f", for: "first")
        await probe.waitUntilDelivered(["f"])

        let firstDelivery = await probe.deliveredValues()
        XCTAssertEqual(firstDelivery, ["f"])

        await probe.yield("fi", for: "first")
        await probe.finish("first")
        await probe.waitUntilDelivered(["f", "fi"])

        let completedDelivery = await probe.deliveredValues()
        XCTAssertEqual(completedDelivery, ["f", "fi"])
    }

    func testSupersedingARequestCancelsItsStream() async {
        let probe = StreamingRequestProbe()
        let pump = LatestStreamPump<String, String>(
            operation: { request in await probe.stream(for: request) },
            deliver: { value in await probe.deliver(value) }
        )

        await pump.submit("first")
        await probe.waitUntilStarted("first")
        await probe.yield("old", for: "first")
        await probe.waitUntilDelivered(["old"])

        await pump.submit("second")
        await probe.waitUntilStarted("second")
        await probe.waitUntilCancelled("first")
        await probe.yield("stale", for: "first")
        await probe.yield("new", for: "second")
        await probe.finish("second")
        await probe.waitUntilDelivered(["old", "new"])

        let cancelled = await probe.cancelledRequests()
        let delivered = await probe.deliveredValues()
        XCTAssertEqual(cancelled, ["first"])
        XCTAssertEqual(delivered, ["old", "new"])
    }
}

private actor StreamingRequestProbe {
    private var started = Set<String>()
    private var cancelled = Set<String>()
    private var continuations:
        [String: AsyncStream<String>.Continuation] = [:]
    private var delivered: [String] = []

    func stream(for request: String) -> AsyncStream<String> {
        let pair = AsyncStream<String>.makeStream()
        started.insert(request)
        pair.continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task {
                await self?.recordCancellation(of: request)
            }
        }
        continuations[request] = pair.continuation
        return pair.stream
    }

    func yield(_ value: String, for request: String) {
        continuations[request]?.yield(value)
    }

    func finish(_ request: String) {
        continuations[request]?.finish()
        continuations[request] = nil
    }

    func deliver(_ value: String) {
        delivered.append(value)
    }

    func deliveredValues() -> [String] {
        delivered
    }

    func cancelledRequests() -> Set<String> {
        cancelled
    }

    private func recordCancellation(of request: String) {
        cancelled.insert(request)
        continuations[request] = nil
    }

    func waitUntilStarted(_ request: String) async {
        for _ in 0..<100 where !started.contains(request) {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func waitUntilDelivered(_ expected: [String]) async {
        for _ in 0..<100 where delivered != expected {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func waitUntilCancelled(_ request: String) async {
        for _ in 0..<100 where !cancelled.contains(request) {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}
