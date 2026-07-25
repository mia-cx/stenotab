import Foundation

public enum PersonalizationLearningSignal:
    String, Codable, Sendable, Equatable
{
    case acceptedSuggestion = "accepted_suggestion"
    case directlyTyped = "directly_typed"
    case revertedSuggestion = "reverted_suggestion"
    case typedSuggestionMatch = "typed_suggestion_match"

    fileprivate var positiveWeight: Double {
        switch self {
        case .directlyTyped:
            1
        case .acceptedSuggestion:
            2.5
        case .typedSuggestionMatch:
            1.5
        case .revertedSuggestion:
            0
        }
    }

    fileprivate var reversionWeight: Double {
        self == .revertedSuggestion ? 1 : 0
    }
}

public enum PersonalCompletionSource:
    String, Codable, Sendable, Equatable
{
    case personalLanguageModel = "personal_language_model"
}

public struct PersonalCompletion: Codable, Sendable, Equatable {
    public let insertion: String
    public let confidence: Double
    public let evidence: Double
    public let source: PersonalCompletionSource

    public init(
        insertion: String,
        confidence: Double,
        evidence: Double,
        source: PersonalCompletionSource
    ) {
        self.insertion = insertion
        self.confidence = confidence
        self.evidence = evidence
        self.source = source
    }
}

public struct PersonalLanguageModel: Codable, Sendable, Equatable {
    private struct TokenEvidence: Codable, Sendable, Equatable {
        var positive = 0.0
        var reversions = 0.0
        var accepted = 0.0
        var typedMatches = 0.0
        var casing: [String: Double] = [:]
        var lastSeen = Date.distantPast
    }

    private struct CandidateEvidence: Codable, Sendable, Equatable {
        var positive = 0.0
        var reversions = 0.0
        var accepted = 0.0
        var typedMatches = 0.0
        var scopePositive: [String: Double] = [:]
        var lastSeen = Date.distantPast
    }

    private struct ScoredCandidate {
        let normalized: String
        let display: String
        let score: Double
        let netEvidence: Double
    }

    public var maximumNGramLength: Int
    public var minimumEvidence: Double
    public var minimumWinningMargin: Double
    public var recencyHalfLife: TimeInterval

    private var vocabulary: [String: TokenEvidence]
    private var transitions: [String: [String: CandidateEvidence]]

    public init(
        maximumNGramLength: Int = 5,
        minimumEvidence: Double = 2,
        minimumWinningMargin: Double = 0.25,
        recencyHalfLife: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.maximumNGramLength = min(max(maximumNGramLength, 1), 5)
        self.minimumEvidence = minimumEvidence
        self.minimumWinningMargin = minimumWinningMargin
        self.recencyHalfLife = recencyHalfLife
        vocabulary = [:]
        transitions = [:]
    }

    public mutating func learn(
        insertedText: String,
        precedingText: String,
        signal: PersonalizationLearningSignal,
        context: PersonalizationContext,
        at date: Date = Date()
    ) {
        let insertedTokens = Self.tokens(in: insertedText)
        guard !insertedTokens.isEmpty else { return }
        let precedingTokens = Self.tokens(in: precedingText)
        let combined = precedingTokens + insertedTokens
        let insertedStart = precedingTokens.count
        let scopeKeys = Self.scopeKeys(for: context)

        for index in insertedStart..<combined.count {
            let displayToken = combined[index]
            let normalized = Self.normalize(displayToken)
            updateVocabulary(
                normalized: normalized,
                display: displayToken,
                signal: signal,
                at: date
            )

            let maximumContext = min(
                maximumNGramLength - 1,
                index
            )
            for contextLength in 0...maximumContext {
                let contextStart = index - contextLength
                let key = Self.contextKey(
                    Array(combined[contextStart..<index])
                )
                updateTransition(
                    contextKey: key,
                    candidate: normalized,
                    signal: signal,
                    scopeKeys: scopeKeys,
                    at: date
                )
            }
        }
    }

    public mutating func ingest(_ episode: WritingEpisodeCapture) {
        for edit in episode.edits
        where edit.provenance == .directlyTyped
            && !edit.insertedText.isEmpty {
            let fieldBefore = edit.fieldBefore ?? episode.initialField
            let prefix = Self.prefix(
                of: fieldBefore.text,
                throughUTF16: min(
                    edit.selectionBefore.location,
                    fieldBefore.text.utf16.count
                )
            )
            learn(
                insertedText: edit.insertedText,
                precedingText: prefix,
                signal: .directlyTyped,
                context: episode.context,
                at: edit.endedAt
            )
        }
    }

    public mutating func ingest(_ capture: AcceptedSuggestionCapture) {
        learn(
            insertedText: capture.insertion,
            precedingText: Self.prefix(
                of: capture.field.text,
                throughUTF16: capture.field.selection.location
            ),
            signal: .acceptedSuggestion,
            context: capture.context,
            at: capture.capturedAt
        )
    }

    public mutating func ingest(_ feedback: CompletionFeedbackCapture) {
        let signal: PersonalizationLearningSignal
        switch feedback.kind {
        case .typedSuggestionMatch:
            signal = .typedSuggestionMatch
        case .reverted:
            signal = .revertedSuggestion
        }
        learn(
            insertedText: feedback.affectedText,
            precedingText: Self.prefix(
                of: feedback.field.text,
                throughUTF16: feedback.field.selection.location
            ),
            signal: signal,
            context: feedback.context,
            at: feedback.capturedAt
        )
    }

    public func completion(
        for prefix: String,
        context: PersonalizationContext,
        maximumTokens: Int = 8,
        at date: Date = Date()
    ) -> PersonalCompletion? {
        guard maximumTokens > 0 else { return nil }
        let fragment = Self.trailingWordFragment(in: prefix)
        let contextText = fragment.map {
            String(prefix.dropLast($0.count))
        } ?? prefix
        var contextTokens = Self.tokens(in: contextText)
        var generated: [String] = []
        var firstScore: ScoredCandidate?
        var currentFragment = fragment

        for _ in 0..<maximumTokens {
            guard
                let candidate = bestCandidate(
                    contextTokens: contextTokens,
                    fragment: currentFragment,
                    context: context,
                    at: date,
                    allowUnigram: generated.isEmpty
                )
            else {
                break
            }
            if firstScore == nil {
                firstScore = candidate
            }
            generated.append(candidate.display)
            contextTokens.append(candidate.display)
            currentFragment = nil
        }

        guard let firstScore, !generated.isEmpty else { return nil }
        let insertion = Self.insertion(
            generatedTokens: generated,
            fragment: fragment,
            prefix: prefix
        )
        guard !insertion.isEmpty else { return nil }
        let confidence = min(
            0.99,
            max(0, 0.55 + firstScore.netEvidence * 0.1)
        )
        return PersonalCompletion(
            insertion: insertion,
            confidence: confidence,
            evidence: firstScore.netEvidence,
            source: .personalLanguageModel
        )
    }

    private mutating func updateVocabulary(
        normalized: String,
        display: String,
        signal: PersonalizationLearningSignal,
        at date: Date
    ) {
        guard Self.isWordToken(display) else { return }
        var evidence = vocabulary[normalized] ?? TokenEvidence()
        evidence.positive += signal.positiveWeight
        evidence.reversions += signal.reversionWeight
        if signal == .acceptedSuggestion {
            evidence.accepted += 1
        }
        if signal == .typedSuggestionMatch {
            evidence.typedMatches += 1
        }
        if signal != .revertedSuggestion {
            evidence.casing[display, default: 0] += signal.positiveWeight
        }
        evidence.lastSeen = max(evidence.lastSeen, date)
        vocabulary[normalized] = evidence
    }

    private mutating func updateTransition(
        contextKey: String,
        candidate: String,
        signal: PersonalizationLearningSignal,
        scopeKeys: [String],
        at date: Date
    ) {
        var candidates = transitions[contextKey] ?? [:]
        var evidence = candidates[candidate] ?? CandidateEvidence()
        evidence.positive += signal.positiveWeight
        evidence.reversions += signal.reversionWeight
        if signal == .acceptedSuggestion {
            evidence.accepted += 1
        }
        if signal == .typedSuggestionMatch {
            evidence.typedMatches += 1
        }
        if signal != .revertedSuggestion {
            for key in scopeKeys {
                evidence.scopePositive[key, default: 0] +=
                    signal.positiveWeight
            }
        }
        evidence.lastSeen = max(evidence.lastSeen, date)
        candidates[candidate] = evidence
        transitions[contextKey] = candidates
    }

    private func bestCandidate(
        contextTokens: [String],
        fragment: String?,
        context: PersonalizationContext,
        at date: Date,
        allowUnigram: Bool
    ) -> ScoredCandidate? {
        let normalizedFragment = fragment.map(Self.normalize)
        let maximumContext = min(
            maximumNGramLength - 1,
            contextTokens.count
        )
        let scopeKeys = Self.scopeKeys(for: context)
        var candidates: [String: CandidateEvidence] = [:]

        let minimumContext = allowUnigram ? 0 : 1
        if maximumContext >= minimumContext {
            for length in stride(
                from: maximumContext,
                through: minimumContext,
                by: -1
            ) {
            let key = Self.contextKey(
                Array(contextTokens.suffix(length))
            )
            let matching = (transitions[key] ?? [:]).filter {
                normalizedFragment.map($0.key.hasPrefix) ?? true
            }
            if !matching.isEmpty {
                candidates = matching
                break
            }
            }
        }

        if candidates.isEmpty, allowUnigram, let normalizedFragment {
            for (token, evidence) in vocabulary
            where token.hasPrefix(normalizedFragment) {
                candidates[token] = CandidateEvidence(
                    positive: evidence.positive,
                    reversions: evidence.reversions,
                    accepted: evidence.accepted,
                    typedMatches: evidence.typedMatches,
                    scopePositive: [:],
                    lastSeen: evidence.lastSeen
                )
            }
        }

        let scored = candidates.compactMap {
            score(
                normalized: $0.key,
                evidence: $0.value,
                scopeKeys: scopeKeys,
                at: date
            )
        }.sorted {
            if $0.score == $1.score {
                return $0.normalized < $1.normalized
            }
            return $0.score > $1.score
        }
        guard let winner = scored.first else { return nil }
        if scored.count > 1,
           winner.score - scored[1].score < minimumWinningMargin {
            return nil
        }
        return winner
    }

    private func score(
        normalized: String,
        evidence: CandidateEvidence,
        scopeKeys: [String],
        at date: Date
    ) -> ScoredCandidate? {
        let netEvidence =
            evidence.positive - evidence.reversions * 4
        guard netEvidence >= minimumEvidence else { return nil }
        let scopeEvidence = scopeKeys.reduce(0.0) {
            $0 + (evidence.scopePositive[$1] ?? 0)
        }
        let age = max(0, date.timeIntervalSince(evidence.lastSeen))
        let recency = recencyHalfLife > 0
            ? exp(-age / recencyHalfLife) * 0.4
            : 0
        let score =
            log1p(netEvidence)
            + log1p(scopeEvidence) * 0.8
            + evidence.accepted * 0.2
            + evidence.typedMatches * 0.15
            + recency
        return ScoredCandidate(
            normalized: normalized,
            display: preferredCasing(for: normalized),
            score: score,
            netEvidence: netEvidence
        )
    }

    private func preferredCasing(for normalized: String) -> String {
        guard let evidence = vocabulary[normalized] else {
            return normalized
        }
        return evidence.casing.max {
            if $0.value == $1.value {
                return $0.key < $1.key
            }
            return $0.value < $1.value
        }?.key ?? normalized
    }

    private static func insertion(
        generatedTokens: [String],
        fragment: String?,
        prefix: String
    ) -> String {
        var result = ""
        for (index, token) in generatedTokens.enumerated() {
            if index == 0, let fragment {
                guard token.count >= fragment.count else { return "" }
                result += String(token.dropFirst(fragment.count))
                continue
            }
            if isPunctuation(token) {
                result += token
            } else if index == 0, prefix.last?.isWhitespace == true {
                result += token
            } else {
                result += " " + token
            }
        }
        return result
    }

    private static func tokens(in text: String) -> [String] {
        var result: [String] = []
        var word = ""
        func flushWord() {
            if !word.isEmpty {
                result.append(word)
                word = ""
            }
        }

        for character in text {
            if isWordCharacter(character)
                || ((!word.isEmpty) && (character == "'" || character == "’"
                    || character == "-")) {
                word.append(character)
            } else {
                flushWord()
                if isPunctuation(String(character)) {
                    result.append(String(character))
                }
            }
        }
        flushWord()
        return result
    }

    private static func trailingWordFragment(in text: String) -> String? {
        var fragment = ""
        for character in text.reversed() {
            guard isWordCharacter(character)
                || character == "'" || character == "’" || character == "-"
            else {
                break
            }
            fragment.insert(character, at: fragment.startIndex)
        }
        return fragment.isEmpty ? nil : fragment
    }

    private static func contextKey(_ tokens: [String]) -> String {
        tokens.map(normalize).joined(separator: "\u{1F}")
    }

    private static func normalize(_ token: String) -> String {
        token.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }

    private static func scopeKeys(
        for context: PersonalizationContext
    ) -> [String] {
        [
            context.applicationBundleIdentifier.map {
                "application=\($0)"
            },
            context.website.map { "website=\($0)" },
            context.inputKind.map { "input_kind=\($0)" },
            context.detectedLanguage.map { "language=\($0)" }
        ].compactMap(\.self)
    }

    private static func isWordToken(_ token: String) -> Bool {
        token.contains(where: isWordCharacter)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
    }

    private static func isPunctuation(_ token: String) -> Bool {
        [".", ",", "!", "?", ";", ":"].contains(token)
    }

    private static func prefix(
        of text: String,
        throughUTF16 location: Int
    ) -> String {
        guard location >= 0, location <= text.utf16.count else {
            return text
        }
        let utf16 = text.utf16
        let index = utf16.index(utf16.startIndex, offsetBy: location)
        return String(decoding: utf16[..<index], as: UTF16.self)
    }
}
