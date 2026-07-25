import Foundation

public enum UTF16DeletionDirection: Sendable, Equatable {
    case backward
    case forward
}

public struct UTF16Selection: Codable, Sendable, Equatable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public func isValid(for text: String) -> Bool {
        let count = text.utf16.count
        guard
            location >= 0
            && length >= 0
            && location <= count
            && length <= count - location
        else {
            return false
        }
        let utf16 = text.utf16
        let lowerBound = utf16.index(
            utf16.startIndex,
            offsetBy: location
        )
        let upperBound = utf16.index(
            lowerBound,
            offsetBy: length
        )
        return String.Index(lowerBound, within: text) != nil
            && String.Index(upperBound, within: text) != nil
    }

    public func selectionForDeletion(
        in text: String,
        direction: UTF16DeletionDirection
    ) -> UTF16Selection? {
        guard isValid(for: text) else { return nil }
        if length > 0 {
            return self
        }
        let utf16 = text.utf16
        let utf16Caret = utf16.index(
            utf16.startIndex,
            offsetBy: location
        )
        guard let caret = String.Index(utf16Caret, within: text) else {
            return nil
        }
        let characterRange: Range<String.Index>
        switch direction {
        case .backward:
            guard caret > text.startIndex else { return nil }
            characterRange = text.index(before: caret)..<caret
        case .forward:
            guard caret < text.endIndex else { return nil }
            characterRange = caret..<text.index(after: caret)
        }
        guard
            let utf16Start = characterRange.lowerBound.samePosition(
                in: utf16
            ),
            let utf16End = characterRange.upperBound.samePosition(
                in: utf16
            )
        else {
            return nil
        }
        return UTF16Selection(
            location: utf16.distance(
                from: utf16.startIndex,
                to: utf16Start
            ),
            length: utf16.distance(from: utf16Start, to: utf16End)
        )
    }
}

public struct CapturedFieldState: Codable, Sendable, Equatable {
    public let text: String
    public let selection: UTF16Selection

    public init(text: String, selection: UTF16Selection) {
        self.text = text
        self.selection = selection
    }
}

public struct PersonalizationContext: Codable, Sendable, Equatable {
    public let applicationBundleIdentifier: String?
    public let website: String?
    public let inputKind: String?
    public let detectedLanguage: String?
    public let editorIdentifier: String

    public init(
        applicationBundleIdentifier: String? = nil,
        website: String? = nil,
        inputKind: String? = nil,
        detectedLanguage: String? = nil,
        editorIdentifier: String
    ) {
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.website = website
        self.inputKind = inputKind
        self.detectedLanguage = detectedLanguage
        self.editorIdentifier = editorIdentifier
    }
}

public struct AcceptedSuggestionCapture: Codable, Sendable, Equatable {
    public let id: UUID
    public let field: CapturedFieldState
    public let insertion: String
    public let acceptanceScope: SuggestionAcceptance.Scope
    public let completionEpisodeID: UUID?
    public let context: PersonalizationContext
    public let capturedAt: Date

    public init(
        id: UUID,
        field: CapturedFieldState,
        insertion: String,
        acceptanceScope: SuggestionAcceptance.Scope,
        completionEpisodeID: UUID? = nil,
        context: PersonalizationContext,
        capturedAt: Date
    ) {
        self.id = id
        self.field = field
        self.insertion = insertion
        self.acceptanceScope = acceptanceScope
        self.completionEpisodeID = completionEpisodeID
        self.context = context
        self.capturedAt = capturedAt
    }
}

public enum PersonalizationCapture {
    public static func acceptedSuggestion(
        id: UUID = UUID(),
        fieldText: String,
        selection: UTF16Selection,
        insertion: String,
        acceptanceScope: SuggestionAcceptance.Scope,
        completionEpisodeID: UUID? = nil,
        context: PersonalizationContext,
        capturedAt: Date = Date()
    ) -> AcceptedSuggestionCapture? {
        guard
            !insertion.isEmpty,
            selection.isValid(for: fieldText),
            !context.editorIdentifier.isEmpty
        else {
            return nil
        }

        return AcceptedSuggestionCapture(
            id: id,
            field: CapturedFieldState(
                text: fieldText,
                selection: selection
            ),
            insertion: insertion,
            acceptanceScope: acceptanceScope,
            completionEpisodeID: completionEpisodeID,
            context: context,
            capturedAt: capturedAt
        )
    }
}
