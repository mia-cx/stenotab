import Foundation

public struct UTF16Selection: Codable, Sendable, Equatable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public func isValid(for text: String) -> Bool {
        let count = text.utf16.count
        return location >= 0
            && length >= 0
            && location <= count
            && length <= count - location
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
    public let context: PersonalizationContext
    public let capturedAt: Date

    public init(
        id: UUID,
        field: CapturedFieldState,
        insertion: String,
        acceptanceScope: SuggestionAcceptance.Scope,
        context: PersonalizationContext,
        capturedAt: Date
    ) {
        self.id = id
        self.field = field
        self.insertion = insertion
        self.acceptanceScope = acceptanceScope
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
            context: context,
            capturedAt: capturedAt
        )
    }
}
