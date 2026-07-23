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
}
