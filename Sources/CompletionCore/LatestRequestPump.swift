public actor LatestRequestPump<Request: Sendable, Output: Sendable> {
    public typealias Operation = @Sendable (Request) async -> Output
    public typealias Delivery = @Sendable (Output) async -> Void

    private let operation: Operation
    private let delivery: Delivery
    private var newestID: UInt64 = 0
    private var pending: (id: UInt64, request: Request)?
    private var worker: Task<Void, Never>?

    public init(
        operation: @escaping Operation,
        deliver: @escaping Delivery
    ) {
        self.operation = operation
        self.delivery = deliver
    }

    public func submit(_ request: Request) {
        newestID &+= 1
        pending = (newestID, request)

        guard worker == nil else { return }
        worker = Task { await self.drain() }
    }

    private func drain() async {
        while let next = pending {
            pending = nil
            let output = await operation(next.request)

            if next.id == newestID, pending == nil {
                await delivery(output)
            }
        }

        worker = nil

        // A submit cannot interleave between the loop condition and this
        // assignment while the actor is isolated, but keeping this guard
        // makes the invariant explicit if the implementation evolves.
        if pending != nil {
            worker = Task { await self.drain() }
        }
    }
}
