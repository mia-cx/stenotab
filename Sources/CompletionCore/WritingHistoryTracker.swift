import Foundation

public enum WritingEditProvenance: String, Codable, Sendable, Equatable {
    case directlyTyped = "directly_typed"
    case typedThroughSuggestion = "typed_through_suggestion"
    case acceptedSuggestion = "accepted_suggestion"
    case reconciled = "reconciled"
}

public struct WritingEditCapture: Codable, Sendable, Equatable {
    public let insertedText: String
    public let deletedText: String?
    public let provenance: WritingEditProvenance
    public let selectionBefore: UTF16Selection
    public let selectionAfter: UTF16Selection
    public let fieldBefore: CapturedFieldState?
    public let fieldAfter: CapturedFieldState?
    public let startedAt: Date
    public let endedAt: Date

    public init(
        insertedText: String,
        deletedText: String? = nil,
        provenance: WritingEditProvenance,
        selectionBefore: UTF16Selection,
        selectionAfter: UTF16Selection,
        fieldBefore: CapturedFieldState? = nil,
        fieldAfter: CapturedFieldState? = nil,
        startedAt: Date,
        endedAt: Date
    ) {
        self.insertedText = insertedText
        self.deletedText = deletedText
        self.provenance = provenance
        self.selectionBefore = selectionBefore
        self.selectionAfter = selectionAfter
        self.fieldBefore = fieldBefore
        self.fieldAfter = fieldAfter
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public enum WritingEpisodeBoundary: String, Codable, Sendable, Equatable {
    case cleared
    case focusChanged = "focus_changed"
    case idle
    case submitted
    case collectionDisabled = "collection_disabled"
    case applicationDisabled = "application_disabled"
    case applicationTerminated = "application_terminated"
}

public struct WritingEpisodeCapture: Codable, Sendable, Equatable {
    public let id: UUID
    public let initialField: CapturedFieldState
    public let finalField: CapturedFieldState
    public let edits: [WritingEditCapture]
    public let context: PersonalizationContext
    public let startedAt: Date
    public let endedAt: Date
    public let boundary: WritingEpisodeBoundary

    public init(
        id: UUID,
        initialField: CapturedFieldState,
        finalField: CapturedFieldState,
        edits: [WritingEditCapture],
        context: PersonalizationContext,
        startedAt: Date,
        endedAt: Date,
        boundary: WritingEpisodeBoundary
    ) {
        self.id = id
        self.initialField = initialField
        self.finalField = finalField
        self.edits = edits
        self.context = context
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.boundary = boundary
    }
}

public struct WritingHistoryTracker: Sendable {
    private struct ActiveEpisode: Sendable {
        let id: UUID
        let initialField: CapturedFieldState
        var currentField: CapturedFieldState
        var edits: [WritingEditCapture]
        let context: PersonalizationContext
        let startedAt: Date
        var lastActivityAt: Date
    }

    public var burstInterval: TimeInterval
    private var active: ActiveEpisode?

    public init(burstInterval: TimeInterval = 0.75) {
        self.burstInterval = burstInterval
    }

    @discardableResult
    public mutating func observe(
        field: CapturedFieldState,
        context: PersonalizationContext,
        at date: Date = Date(),
        episodeID: UUID = UUID()
    ) -> WritingEpisodeCapture? {
        guard var active else {
            start(
                field: field,
                context: context,
                at: date,
                episodeID: episodeID
            )
            return nil
        }

        guard active.context.editorIdentifier == context.editorIdentifier else {
            let completed = makeCapture(
                from: active,
                boundary: .focusChanged,
                at: date
            )
            start(
                field: field,
                context: context,
                at: date,
                episodeID: episodeID
            )
            return completed
        }

        if !active.currentField.text.isEmpty,
           field.text.isEmpty,
           !active.edits.isEmpty {
            let completed = makeCapture(
                from: active,
                boundary: .cleared,
                at: date
            )
            start(
                field: field,
                context: context,
                at: date,
                episodeID: episodeID
            )
            return completed
        }

        active.currentField = field
        self.active = active
        return nil
    }

    public mutating func recordInsertion(
        _ text: String,
        provenance: WritingEditProvenance,
        fieldBefore: CapturedFieldState,
        fieldAfter: CapturedFieldState,
        at date: Date = Date()
    ) {
        guard
            !text.isEmpty,
            fieldBefore.selection.isValid(for: fieldBefore.text),
            fieldAfter.selection.isValid(for: fieldAfter.text),
            var active
        else {
            return
        }

        let edit = WritingEditCapture(
            insertedText: text,
            provenance: provenance,
            selectionBefore: fieldBefore.selection,
            selectionAfter: fieldAfter.selection,
            fieldBefore: fieldBefore,
            fieldAfter: fieldAfter,
            startedAt: date,
            endedAt: date
        )
        if canMerge(edit, into: active.edits.last) {
            let previous = active.edits.removeLast()
            active.edits.append(
                WritingEditCapture(
                    insertedText: previous.insertedText + text,
                    provenance: provenance,
                    selectionBefore: previous.selectionBefore,
                    selectionAfter: edit.selectionAfter,
                    fieldBefore: previous.fieldBefore,
                    fieldAfter: edit.fieldAfter,
                    startedAt: previous.startedAt,
                    endedAt: date
                )
            )
        } else {
            active.edits.append(edit)
        }
        active.currentField = fieldAfter
        active.lastActivityAt = date
        self.active = active
    }

    public mutating func recordDeletion(
        _ text: String,
        fieldBefore: CapturedFieldState,
        fieldAfter: CapturedFieldState,
        at date: Date = Date()
    ) {
        guard
            !text.isEmpty,
            fieldBefore.selection.isValid(for: fieldBefore.text),
            fieldAfter.selection.isValid(for: fieldAfter.text),
            var active
        else {
            return
        }
        active.edits.append(
            WritingEditCapture(
                insertedText: "",
                deletedText: text,
                provenance: .directlyTyped,
                selectionBefore: fieldBefore.selection,
                selectionAfter: fieldAfter.selection,
                fieldBefore: fieldBefore,
                fieldAfter: fieldAfter,
                startedAt: date,
                endedAt: date
            )
        )
        active.currentField = fieldAfter
        active.lastActivityAt = date
        self.active = active
    }

    public mutating func reconcile(
        field: CapturedFieldState,
        at date: Date = Date()
    ) {
        guard var active else { return }
        active.currentField = field
        active.lastActivityAt = max(active.lastActivityAt, date)
        self.active = active
    }

    public mutating func finalizeIfIdle(
        at date: Date = Date(),
        timeout: TimeInterval
    ) -> WritingEpisodeCapture? {
        guard
            let active,
            !active.edits.isEmpty,
            date.timeIntervalSince(active.lastActivityAt) >= timeout
        else {
            return nil
        }
        return finalize(boundary: .idle, at: date)
    }

    public mutating func finalize(
        boundary: WritingEpisodeBoundary,
        at date: Date = Date()
    ) -> WritingEpisodeCapture? {
        guard let active else { return nil }
        self.active = nil
        return makeCapture(from: active, boundary: boundary, at: date)
    }

    private mutating func start(
        field: CapturedFieldState,
        context: PersonalizationContext,
        at date: Date,
        episodeID: UUID
    ) {
        active = ActiveEpisode(
            id: episodeID,
            initialField: field,
            currentField: field,
            edits: [],
            context: context,
            startedAt: date,
            lastActivityAt: date
        )
    }

    private func makeCapture(
        from active: ActiveEpisode,
        boundary: WritingEpisodeBoundary,
        at date: Date
    ) -> WritingEpisodeCapture? {
        guard !active.edits.isEmpty else { return nil }
        return WritingEpisodeCapture(
            id: active.id,
            initialField: active.initialField,
            finalField: active.currentField,
            edits: active.edits,
            context: active.context,
            startedAt: active.startedAt,
            endedAt: max(active.lastActivityAt, date),
            boundary: boundary
        )
    }

    private func canMerge(
        _ edit: WritingEditCapture,
        into previous: WritingEditCapture?
    ) -> Bool {
        guard
            edit.provenance == .directlyTyped,
            let previous,
            previous.provenance == .directlyTyped,
            edit.startedAt.timeIntervalSince(previous.endedAt)
                <= burstInterval,
            previous.selectionAfter.length == 0,
            edit.selectionBefore.length == 0,
            previous.selectionAfter == edit.selectionBefore
        else {
            return false
        }
        return true
    }
}
