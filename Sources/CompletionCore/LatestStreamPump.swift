public actor LatestStreamPump<Request: Sendable, Output: Sendable> {
    public typealias Operation =
        @Sendable (Request) async -> AsyncStream<Output>
    public typealias Delivery = @Sendable (Output) async -> Void

    private let operation: Operation
    private let delivery: Delivery
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?

    public init(
        operation: @escaping Operation,
        deliver: @escaping Delivery
    ) {
        self.operation = operation
        self.delivery = deliver
    }

    public func submit(_ request: Request) {
        generation &+= 1
        let requestGeneration = generation
        worker?.cancel()
        worker = Task {
            await run(request, generation: requestGeneration)
        }
    }

    public func cancel() {
        generation &+= 1
        worker?.cancel()
        worker = nil
    }

    private func run(
        _ request: Request,
        generation requestGeneration: UInt64
    ) async {
        let updates = await operation(request)
        for await update in updates {
            guard
                !Task.isCancelled,
                requestGeneration == generation
            else {
                break
            }
            await delivery(update)
        }

        if requestGeneration == generation {
            worker = nil
        }
    }
}
