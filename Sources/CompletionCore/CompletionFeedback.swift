import Foundation

public enum CompletionFeedbackKind: String, Codable, Sendable, Equatable {
    case reverted
    case typedSuggestionMatch = "typed_suggestion_match"
}

public struct CompletionFeedbackCapture: Codable, Sendable, Equatable {
    public let id: UUID
    public let kind: CompletionFeedbackKind
    public let acceptanceID: UUID?
    public let suggestionText: String
    public let affectedText: String
    public let field: CapturedFieldState
    public let context: PersonalizationContext
    public let capturedAt: Date

    public init(
        id: UUID,
        kind: CompletionFeedbackKind,
        acceptanceID: UUID?,
        suggestionText: String,
        affectedText: String,
        field: CapturedFieldState,
        context: PersonalizationContext,
        capturedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.acceptanceID = acceptanceID
        self.suggestionText = suggestionText
        self.affectedText = affectedText
        self.field = field
        self.context = context
        self.capturedAt = capturedAt
    }
}

public extension PersonalizationCapture {
    static func typedSuggestionMatch(
        id: UUID = UUID(),
        fieldText: String,
        selection: UTF16Selection,
        suggestionText: String,
        context: PersonalizationContext,
        capturedAt: Date = Date()
    ) -> CompletionFeedbackCapture? {
        guard
            !suggestionText.isEmpty,
            selection.isValid(for: fieldText),
            !context.editorIdentifier.isEmpty
        else {
            return nil
        }
        return CompletionFeedbackCapture(
            id: id,
            kind: .typedSuggestionMatch,
            acceptanceID: nil,
            suggestionText: suggestionText,
            affectedText: suggestionText,
            field: CapturedFieldState(
                text: fieldText,
                selection: selection
            ),
            context: context,
            capturedAt: capturedAt
        )
    }
}

public struct CompletionReversionTracker: Sendable {
    private struct PendingAcceptance: Sendable {
        let capture: AcceptedSuggestionCapture
        var remainingInsertion: String
    }

    public var timeout: TimeInterval
    private var pending: PendingAcceptance?

    public init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    public mutating func register(_ capture: AcceptedSuggestionCapture) {
        pending = PendingAcceptance(
            capture: capture,
            remainingInsertion: capture.insertion
        )
    }

    public mutating func cancel() {
        pending = nil
    }

    public mutating func recordBackwardDeletion(
        id: UUID = UUID(),
        fieldBefore: CapturedFieldState,
        at date: Date = Date()
    ) -> CompletionFeedbackCapture? {
        guard var pending else { return nil }
        guard
            date.timeIntervalSince(pending.capture.capturedAt) <= timeout,
            fieldBefore.selection.length == 0,
            !pending.remainingInsertion.isEmpty
        else {
            self.pending = nil
            return nil
        }

        let expectedCaret =
            pending.capture.field.selection.location
            + pending.remainingInsertion.utf16.count
        guard fieldBefore.selection.location == expectedCaret else {
            self.pending = nil
            return nil
        }

        let utf16 = fieldBefore.text.utf16
        let caret = utf16.index(
            utf16.startIndex,
            offsetBy: fieldBefore.selection.location
        )
        let prefix = String(decoding: utf16[..<caret], as: UTF16.self)
        guard prefix.hasSuffix(pending.remainingInsertion) else {
            self.pending = nil
            return nil
        }

        pending.remainingInsertion.removeLast()
        if pending.remainingInsertion.isEmpty {
            self.pending = nil
            return CompletionFeedbackCapture(
                id: id,
                kind: .reverted,
                acceptanceID: pending.capture.id,
                suggestionText: pending.capture.insertion,
                affectedText: pending.capture.insertion,
                field: pending.capture.field,
                context: pending.capture.context,
                capturedAt: date
            )
        }
        self.pending = pending
        return nil
    }
}
