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

public struct PersonalVocabularyEntry:
    Sendable, Equatable, Identifiable
{
    public var id: String { normalized }
    public let normalized: String
    public let preferredCasing: String
    public let positiveEvidence: Double
    public let reversionEvidence: Double
    public let acceptedCount: Double
    public let typedMatchCount: Double
    public let lastSeen: Date

    public init(
        normalized: String,
        preferredCasing: String,
        positiveEvidence: Double,
        reversionEvidence: Double,
        acceptedCount: Double,
        typedMatchCount: Double,
        lastSeen: Date
    ) {
        self.normalized = normalized
        self.preferredCasing = preferredCasing
        self.positiveEvidence = positiveEvidence
        self.reversionEvidence = reversionEvidence
        self.acceptedCount = acceptedCount
        self.typedMatchCount = typedMatchCount
        self.lastSeen = lastSeen
    }
}

public struct PersonalLanguageModel: Codable, Sendable, Equatable {
    private static let currentProjectionVersion = 8

    private struct WordOccurrence {
        let display: String
        let range: Range<String.Index>
        let leadingSeparator: String
        var trailingSeparator: String
    }

    private struct WordEvidence: Codable, Sendable, Equatable {
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
        let leadingSeparator: String
        let trailingSeparator: String
        let score: Double
        let netEvidence: Double
    }

    public var maximumNGramLength: Int
    public var minimumEvidence: Double
    public var minimumWinningMargin: Double
    public var recencyHalfLife: TimeInterval

    private var projectionVersion: Int?
    private var vocabulary: [String: WordEvidence]
    private var transitions: [String: [String: CandidateEvidence]]

    public var requiresRebuild: Bool {
        projectionVersion != Self.currentProjectionVersion
    }

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
        projectionVersion = Self.currentProjectionVersion
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
        learnFieldChange(
            before: precedingText,
            after: precedingText + insertedText,
            signal: signal,
            context: context,
            at: date
        )
    }

    public mutating func ingest(_ episode: WritingEpisodeCapture) {
        let authoritativeWords = Set(
            Self.words(in: episode.finalField.text).map(Self.normalize)
        )
        let authoritativeEdits = Self.authoritativeEditFields(in: episode)
        let directlyTypedEdits = episode.edits.enumerated().filter {
            $0.element.provenance == .directlyTyped
                && !$0.element.insertedText.isEmpty
        }
        for indexedEdit in directlyTypedEdits {
            let editIndex = indexedEdit.offset
            let edit = indexedEdit.element
            guard
                let fieldBefore = edit.fieldBefore,
                let authoritativeEdit = authoritativeEdits[editIndex]
            else {
                continue
            }
            let immediatelyFollowsAcceptedSuggestion =
                episode.edits[..<editIndex].last.map {
                    $0.provenance == .acceptedSuggestion
                        && $0.fieldAfter == fieldBefore
                        && $0.selectionAfter == edit.selectionBefore
                } ?? false
            learnFieldChange(
                before: authoritativeEdit.before,
                after: authoritativeEdit.after,
                signal: .directlyTyped,
                context: episode.context,
                at: edit.endedAt,
                includeBoundaryTouch:
                    !immediatelyFollowsAcceptedSuggestion,
                excludeUnterminatedTrailingWord:
                    editIndex != episode.edits.indices.last
                    || episode.boundary == .idle,
                allowedNormalizedWords: authoritativeWords
            )
        }
    }

    public mutating func ingest(_ capture: AcceptedSuggestionCapture) {
        guard let fieldAfter = Self.replacing(
            capture.field.selection,
            in: capture.field.text,
            with: capture.insertion
        ) else {
            return
        }
        learnFieldChange(
            before: capture.field.text,
            after: fieldAfter,
            signal: .acceptedSuggestion,
            context: capture.context,
            at: capture.capturedAt,
            includeBoundaryTouch:
                !capture.insertion.contains(where: Self.isWordCharacter)
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
        guard let fieldAfter = Self.replacing(
            feedback.field.selection,
            in: feedback.field.text,
            with: feedback.affectedText
        ) else {
            return
        }
        learnFieldChange(
            before: feedback.field.text,
            after: fieldAfter,
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
        let existingSeparator = Self.trailingSeparator(in: contextText)
        var contextWords = Self.words(in: contextText)
        var generated: [ScoredCandidate] = []
        var firstScore: ScoredCandidate?
        var currentFragment = fragment

        for _ in 0..<maximumTokens {
            guard
                let candidate = bestCandidate(
                    contextWords: contextWords,
                    fragment: currentFragment,
                    context: context,
                    at: date,
                    allowUnigram: generated.isEmpty,
                    separatorPrefix:
                        generated.isEmpty ? existingSeparator : nil
                )
            else {
                break
            }
            if firstScore == nil {
                firstScore = candidate
            }
            generated.append(candidate)
            contextWords.append(candidate.display)
            currentFragment = nil
            if !candidate.trailingSeparator.isEmpty {
                break
            }
        }

        guard let firstScore, !generated.isEmpty else { return nil }
        let insertion = Self.insertion(
            generatedWords: generated,
            fragment: fragment,
            existingSeparator: existingSeparator
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

    public func vocabularyEntries(
        limit: Int = 100
    ) -> [PersonalVocabularyEntry] {
        guard limit > 0 else { return [] }
        return vocabulary.map { normalized, evidence in
            PersonalVocabularyEntry(
                normalized: normalized,
                preferredCasing: preferredCasing(for: normalized),
                positiveEvidence: evidence.positive,
                reversionEvidence: evidence.reversions,
                acceptedCount: evidence.accepted,
                typedMatchCount: evidence.typedMatches,
                lastSeen: evidence.lastSeen
            )
        }
        .sorted {
            let lhsNet =
                $0.positiveEvidence - $0.reversionEvidence * 4
            let rhsNet =
                $1.positiveEvidence - $1.reversionEvidence * 4
            if lhsNet == rhsNet {
                if $0.lastSeen == $1.lastSeen {
                    return $0.normalized < $1.normalized
                }
                return $0.lastSeen > $1.lastSeen
            }
            return lhsNet > rhsNet
        }
        .prefix(limit)
        .map(\.self)
    }

    private mutating func updateVocabulary(
        normalized: String,
        display: String,
        signal: PersonalizationLearningSignal,
        at date: Date
    ) {
        guard Self.isWordToken(display) else { return }
        var evidence = vocabulary[normalized] ?? WordEvidence()
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

    private mutating func learnFieldChange(
        before: String,
        after: String,
        signal: PersonalizationLearningSignal,
        context: PersonalizationContext,
        at date: Date,
        includeBoundaryTouch: Bool? = nil,
        excludeUnterminatedTrailingWord: Bool = false,
        allowedNormalizedWords: Set<String>? = nil
    ) {
        let words = Self.wordOccurrences(in: after)
        guard
            !words.isEmpty,
            let changedRange = Self.changedRange(
                before: before,
                after: after
            )
        else {
            return
        }
        let trailingWordIsUnterminated =
            excludeUnterminatedTrailingWord
            && after.last.map(Self.isWordContinuation) == true
        let affectedIndices = words.indices.filter {
            let intersects = Self.intersects(
                words[$0].range,
                changedRange: changedRange,
                includeBoundaryTouch:
                    includeBoundaryTouch
                    ?? (signal == .directlyTyped)
            )
            let isUnterminatedTail =
                trailingWordIsUnterminated && $0 == words.count - 1
            let isAuthoritative =
                allowedNormalizedWords?.contains(
                    Self.normalize(words[$0].display)
                ) ?? true
            return intersects && !isUnterminatedTail && isAuthoritative
        }
        guard !affectedIndices.isEmpty else { return }
        let scopeKeys = Self.scopeKeys(for: context)

        for index in affectedIndices {
            let displayWord = words[index].display
            let normalized = Self.normalize(displayWord)
            updateVocabulary(
                normalized: normalized,
                display: displayWord,
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
                    words[contextStart..<index].map(\.display)
                )
                let leadingSeparator =
                    contextLength == 0
                    ? ""
                    : words[index].leadingSeparator
                updateTransition(
                    contextKey: key,
                    candidate: Self.transitionCandidateKey(
                        normalized: normalized,
                        leadingSeparator: leadingSeparator,
                        trailingSeparator: words[index].trailingSeparator
                    ),
                    signal: signal,
                    scopeKeys: scopeKeys,
                    at: date
                )
            }
        }
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
        contextWords: [String],
        fragment: String?,
        context: PersonalizationContext,
        at date: Date,
        allowUnigram: Bool,
        separatorPrefix: String?
    ) -> ScoredCandidate? {
        let normalizedFragment = fragment.map(Self.normalize)
        let maximumContext = min(
            maximumNGramLength - 1,
            contextWords.count
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
                    Array(contextWords.suffix(length))
                )
                let matching = (transitions[key] ?? [:]).filter {
                    guard
                        let candidate = Self.transitionCandidate(from: $0.key)
                    else {
                        return false
                    }
                    let fragmentMatches =
                        normalizedFragment.map {
                            candidate.normalized.hasPrefix($0)
                        } ?? true
                    let separatorMatches =
                        separatorPrefix.map {
                            candidate.leadingSeparator.hasPrefix($0)
                        } ?? true
                    return fragmentMatches && separatorMatches
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
                let key = Self.transitionCandidateKey(
                    normalized: token,
                    leadingSeparator: separatorPrefix ?? "",
                    trailingSeparator: ""
                )
                candidates[key] = CandidateEvidence(
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
                candidateKey: $0.key,
                evidence: $0.value,
                scopeKeys: scopeKeys,
                at: date
            )
        }.sorted {
            if $0.score == $1.score {
                if $0.normalized == $1.normalized {
                    if $0.leadingSeparator == $1.leadingSeparator {
                        return $0.trailingSeparator < $1.trailingSeparator
                    }
                    return $0.leadingSeparator < $1.leadingSeparator
                }
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
        candidateKey: String,
        evidence: CandidateEvidence,
        scopeKeys: [String],
        at date: Date
    ) -> ScoredCandidate? {
        guard
            let candidate = Self.transitionCandidate(from: candidateKey)
        else {
            return nil
        }
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
            normalized: candidate.normalized,
            display: preferredCasing(for: candidate.normalized),
            leadingSeparator: candidate.leadingSeparator,
            trailingSeparator: candidate.trailingSeparator,
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
        generatedWords: [ScoredCandidate],
        fragment: String?,
        existingSeparator: String
    ) -> String {
        var result = ""
        for (index, candidate) in generatedWords.enumerated() {
            let word = candidate.display
            if index == 0, let fragment {
                guard word.count >= fragment.count else { return "" }
                result += String(word.dropFirst(fragment.count))
                continue
            }
            if index == 0 {
                guard
                    candidate.leadingSeparator.hasPrefix(existingSeparator)
                else {
                    return ""
                }
                result += candidate.leadingSeparator
                    .dropFirst(existingSeparator.count)
                result += word
            } else {
                result += candidate.leadingSeparator + word
            }
        }
        result += generatedWords.last?.trailingSeparator ?? ""
        return result
    }

    private static func words(in text: String) -> [String] {
        wordOccurrences(in: text).map(\.display)
    }

    private static func wordOccurrences(
        in text: String
    ) -> [WordOccurrence] {
        var result: [WordOccurrence] = []
        var cursor = text.startIndex
        var separatorStart = text.startIndex

        while cursor < text.endIndex {
            while cursor < text.endIndex,
                  !isWordCharacter(text[cursor]) {
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex else { break }

            let wordStart = cursor
            while cursor < text.endIndex {
                if isWordCharacter(text[cursor]) {
                    cursor = text.index(after: cursor)
                    continue
                }
                guard isInternalWordPunctuation(at: cursor, in: text) else {
                    break
                }
                cursor = text.index(after: cursor)
            }
            let wordEnd = cursor

            result.append(
                WordOccurrence(
                    display: String(text[wordStart..<wordEnd]),
                    range: wordStart..<wordEnd,
                    leadingSeparator:
                        String(text[separatorStart..<wordStart]),
                    trailingSeparator: ""
                )
            )
            separatorStart = wordEnd
        }
        if let lastIndex = result.indices.last {
            result[lastIndex].trailingSeparator = String(
                text[result[lastIndex].range.upperBound...]
            )
        }
        return result
    }

    private static func changedRange(
        before: String,
        after: String
    ) -> Range<String.Index>? {
        guard before != after else { return nil }
        let beforeCharacters = Array(before)
        let afterCharacters = Array(after)
        var prefixCount = 0
        while prefixCount < beforeCharacters.count,
              prefixCount < afterCharacters.count,
              beforeCharacters[prefixCount] == afterCharacters[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < beforeCharacters.count - prefixCount,
              suffixCount < afterCharacters.count - prefixCount,
              beforeCharacters[beforeCharacters.count - suffixCount - 1]
                == afterCharacters[afterCharacters.count - suffixCount - 1] {
            suffixCount += 1
        }

        let start = after.index(
            after.startIndex,
            offsetBy: prefixCount
        )
        let end = after.index(
            after.endIndex,
            offsetBy: -suffixCount
        )
        return start..<end
    }

    private static func intersects(
        _ wordRange: Range<String.Index>,
        changedRange: Range<String.Index>,
        includeBoundaryTouch: Bool
    ) -> Bool {
        if changedRange.isEmpty {
            return includeBoundaryTouch
                && wordRange.lowerBound <= changedRange.lowerBound
                && changedRange.lowerBound <= wordRange.upperBound
        }
        return wordRange.overlaps(changedRange)
            || (
                includeBoundaryTouch
                && (
                    wordRange.upperBound == changedRange.lowerBound
                    || wordRange.lowerBound == changedRange.upperBound
                )
            )
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

    private static func transitionCandidateKey(
        normalized: String,
        leadingSeparator: String,
        trailingSeparator: String
    ) -> String {
        let encodedLeadingSeparator = Data(leadingSeparator.utf8)
            .base64EncodedString()
        let encodedTrailingSeparator = Data(trailingSeparator.utf8)
            .base64EncodedString()
        return encodedLeadingSeparator + "\u{1F}"
            + encodedTrailingSeparator + "\u{1F}" + normalized
    }

    private static func transitionCandidate(
        from key: String
    ) -> (
        normalized: String,
        leadingSeparator: String,
        trailingSeparator: String
    )? {
        let components = key.split(
            separator: "\u{1F}",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard
            components.count == 3,
            let leadingSeparatorData = Data(
                base64Encoded: String(components[0])
            ),
            let trailingSeparatorData = Data(
                base64Encoded: String(components[1])
            ),
            let leadingSeparator = String(
                data: leadingSeparatorData,
                encoding: .utf8
            ),
            let trailingSeparator = String(
                data: trailingSeparatorData,
                encoding: .utf8
            ),
            !components[2].isEmpty
        else {
            return nil
        }
        let normalized = String(components[2])
        guard
            !normalized.isEmpty,
            !normalized.contains("\u{1F}")
        else {
            return nil
        }
        return (normalized, leadingSeparator, trailingSeparator)
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

    private static func isInternalWordPunctuation(
        at index: String.Index,
        in text: String
    ) -> Bool {
        let character = text[index]
        guard
            character == "'" || character == "’" || character == "-",
            index > text.startIndex
        else {
            return false
        }
        let nextIndex = text.index(after: index)
        guard nextIndex < text.endIndex else { return false }
        return isWordCharacter(text[text.index(before: index)])
            && isWordCharacter(text[nextIndex])
    }

    private static func isWordContinuation(_ character: Character) -> Bool {
        isWordCharacter(character)
            || character == "'"
            || character == "’"
            || character == "-"
    }

    private static func trailingSeparator(in text: String) -> String {
        guard let lastWord = wordOccurrences(in: text).last else {
            return text
        }
        return String(text[lastWord.range.upperBound...])
    }

    private static func replacing(
        _ selection: UTF16Selection,
        in text: String,
        with insertion: String
    ) -> String? {
        guard selection.isValid(for: text) else { return nil }
        let utf16 = text.utf16
        let lowerBound = utf16.index(
            utf16.startIndex,
            offsetBy: selection.location
        )
        let upperBound = utf16.index(
            lowerBound,
            offsetBy: selection.length
        )
        return String(decoding: utf16[..<lowerBound], as: UTF16.self)
            + insertion
            + String(decoding: utf16[upperBound...], as: UTF16.self)
    }

    private static func authoritativeEditFields(
        in episode: WritingEpisodeCapture
    ) -> [(before: String, after: String)?] {
        var fields = Array<(before: String, after: String)?>(
            repeating: nil,
            count: episode.edits.count
        )
        var authoritativeAfter = episode.finalField.text
        for editIndex in episode.edits.indices.reversed() {
            let edit = episode.edits[editIndex]
            guard
                let authoritativeBefore = reversing(
                    edit,
                    from: authoritativeAfter
                )
            else {
                break
            }
            fields[editIndex] = (
                before: authoritativeBefore,
                after: authoritativeAfter
            )
            authoritativeAfter = authoritativeBefore
        }
        return fields
    }

    private static func reversing(
        _ edit: WritingEditCapture,
        from authoritativeAfter: String
    ) -> String? {
        let replacementLocation: Int
        let originalText: String
        if let deletedText = edit.deletedText, !deletedText.isEmpty {
            replacementLocation =
                edit.insertedText.isEmpty
                ? edit.selectionAfter.location
                : edit.selectionBefore.location
            originalText = deletedText
        } else {
            replacementLocation = edit.selectionBefore.location
            guard
                let fieldBefore = edit.fieldBefore,
                let selectedText = selectedText(
                    edit.selectionBefore,
                    in: fieldBefore.text
                )
            else {
                return nil
            }
            originalText = selectedText
        }
        guard
            let predictedAfter = resolvedFieldAfter(edit),
            let authoritativeRange = authoritativeRange(
                for: edit,
                replacementLocation: replacementLocation,
                predictedAfter: predictedAfter.text,
                authoritativeAfter: authoritativeAfter
            )
        else {
            return nil
        }
        return replacing(
            authoritativeRange,
            in: authoritativeAfter,
            with: originalText
        )
    }

    private static func authoritativeRange(
        for edit: WritingEditCapture,
        replacementLocation: Int,
        predictedAfter: String,
        authoritativeAfter: String
    ) -> UTF16Selection? {
        let insertedLength = edit.insertedText.utf16.count
        guard
            let predictedPrefix = utf16Substring(
                in: predictedAfter,
                selection: UTF16Selection(
                    location: 0,
                    length: replacementLocation
                )
            ),
            let predictedSuffix = utf16Substring(
                in: predictedAfter,
                selection: UTF16Selection(
                    location: replacementLocation + insertedLength,
                    length:
                        predictedAfter.utf16.count
                        - replacementLocation
                        - insertedLength
                )
            )
        else {
            return nil
        }

        let authoritativeCount = authoritativeAfter.utf16.count
        let mappedStart =
            predictedPrefix.isEmpty
            ? 0
            : (
                hasLiteralUTF16Prefix(
                    authoritativeAfter,
                    prefix: predictedPrefix
                )
                    ? predictedPrefix.utf16.count
                    : nil
            )
        let mappedEnd =
            predictedSuffix.isEmpty
            ? authoritativeCount
            : (
                hasLiteralUTF16Suffix(
                    authoritativeAfter,
                    suffix: predictedSuffix
                )
                    ? authoritativeCount - predictedSuffix.utf16.count
                    : nil
            )

        if
            let mappedStart,
            let mappedEnd,
            mappedStart <= mappedEnd
        {
            return UTF16Selection(
                location: mappedStart,
                length: mappedEnd - mappedStart
            )
        }
        if let mappedStart {
            let candidate = UTF16Selection(
                location: mappedStart,
                length: insertedLength
            )
            if
                utf16Substring(
                    in: authoritativeAfter,
                    selection: candidate
                ) == edit.insertedText
            {
                return candidate
            }
        }
        if
            let mappedEnd,
            mappedEnd >= insertedLength
        {
            let candidate = UTF16Selection(
                location: mappedEnd - insertedLength,
                length: insertedLength
            )
            if
                utf16Substring(
                    in: authoritativeAfter,
                    selection: candidate
                ) == edit.insertedText
            {
                return candidate
            }
        }
        let anchoredStart =
            mappedStart
            ?? boundaryAfterSuffixAnchor(
                predictedPrefix,
                in: authoritativeAfter,
                beforeUTF16Offset: mappedEnd ?? authoritativeCount
            )
        let anchoredEnd =
            mappedEnd
            ?? boundaryBeforePrefixAnchor(
                predictedSuffix,
                in: authoritativeAfter,
                afterUTF16Offset: anchoredStart ?? 0
            )
        if
            let anchoredStart,
            let anchoredEnd,
            anchoredStart <= anchoredEnd
        {
            let candidate = UTF16Selection(
                location: anchoredStart,
                length: anchoredEnd - anchoredStart
            )
            if
                candidate.isValid(for: authoritativeAfter),
                let candidateText = utf16Substring(
                    in: authoritativeAfter,
                    selection: candidate
                ),
                isPlausibleAuthoritativeCorrection(
                    candidateText,
                    for: edit.insertedText
                )
            {
                return candidate
            }
        }
        return nil
    }

    private static func boundaryAfterSuffixAnchor(
        _ predictedPrefix: String,
        in authoritativeText: String,
        beforeUTF16Offset upperOffset: Int
    ) -> Int? {
        let minimumAnchorLength = 6
        let predictedUnits = Array(predictedPrefix.utf16)
        let authoritativeUnits = Array(authoritativeText.utf16)
        let maximumLength = min(predictedUnits.count, 128)
        guard maximumLength >= minimumAnchorLength else { return nil }
        for length in stride(
            from: maximumLength,
            through: minimumAnchorLength,
            by: -1
        ) {
            let predictedSelection = UTF16Selection(
                location: predictedUnits.count - length,
                length: length
            )
            guard predictedSelection.isValid(for: predictedPrefix) else {
                continue
            }
            let anchor = predictedUnits.suffix(length)
            guard upperOffset >= length else { continue }
            for start in stride(
                from: upperOffset - length,
                through: 0,
                by: -1
            ) {
                let boundary = start + length
                if
                    authoritativeUnits[start..<boundary]
                        .elementsEqual(anchor),
                    UTF16Selection(location: boundary, length: 0)
                        .isValid(for: authoritativeText)
                {
                    return boundary
                }
            }
        }
        return nil
    }

    private static func boundaryBeforePrefixAnchor(
        _ predictedSuffix: String,
        in authoritativeText: String,
        afterUTF16Offset lowerOffset: Int
    ) -> Int? {
        let minimumAnchorLength = 6
        let predictedUnits = Array(predictedSuffix.utf16)
        let authoritativeUnits = Array(authoritativeText.utf16)
        let maximumLength = min(predictedUnits.count, 128)
        guard maximumLength >= minimumAnchorLength else { return nil }
        for length in stride(
            from: maximumLength,
            through: minimumAnchorLength,
            by: -1
        ) {
            let predictedSelection = UTF16Selection(
                location: 0,
                length: length
            )
            guard predictedSelection.isValid(for: predictedSuffix) else {
                continue
            }
            let anchor = predictedUnits.prefix(length)
            guard
                lowerOffset <= authoritativeUnits.count - length
            else {
                continue
            }
            for start in lowerOffset...(
                authoritativeUnits.count - length
            ) {
                if
                    authoritativeUnits[start..<(start + length)]
                        .elementsEqual(anchor),
                    UTF16Selection(location: start, length: 0)
                        .isValid(for: authoritativeText)
                {
                    return start
                }
            }
        }
        return nil
    }

    private static func hasLiteralUTF16Prefix(
        _ text: String,
        prefix: String
    ) -> Bool {
        let textUnits = text.utf16
        let prefixUnits = prefix.utf16
        guard prefixUnits.count <= textUnits.count else { return false }
        return textUnits.prefix(prefixUnits.count).elementsEqual(prefixUnits)
    }

    private static func hasLiteralUTF16Suffix(
        _ text: String,
        suffix: String
    ) -> Bool {
        let textUnits = text.utf16
        let suffixUnits = suffix.utf16
        guard suffixUnits.count <= textUnits.count else { return false }
        return textUnits.suffix(suffixUnits.count).elementsEqual(suffixUnits)
    }

    private static func isPlausibleAuthoritativeCorrection(
        _ candidate: String,
        for insertedText: String
    ) -> Bool {
        if candidate == insertedText {
            return true
        }
        let original = Array(insertedText)
        let corrected = Array(candidate)
        guard !original.isEmpty else { return corrected.isEmpty }
        let maximumDistance = 2
        guard
            abs(original.count - corrected.count) <= maximumDistance
        else {
            return false
        }
        var previous = Array(0...corrected.count)
        for (originalIndex, originalCharacter) in original.enumerated() {
            var current = Array(
                repeating: 0,
                count: corrected.count + 1
            )
            current[0] = originalIndex + 1
            for (correctedIndex, correctedCharacter) in
                corrected.enumerated()
            {
                current[correctedIndex + 1] = min(
                    current[correctedIndex] + 1,
                    previous[correctedIndex + 1] + 1,
                    previous[correctedIndex]
                        + (originalCharacter == correctedCharacter ? 0 : 1)
                )
            }
            if current.min() ?? 0 > maximumDistance {
                return false
            }
            previous = current
        }
        return previous[corrected.count] <= maximumDistance
    }

    private static func resolvedFieldAfter(
        _ edit: WritingEditCapture
    ) -> CapturedFieldState? {
        if let fieldAfter = edit.fieldAfter {
            return fieldAfter
        }
        guard let fieldBefore = edit.fieldBefore else { return nil }
        let replacementSelection: UTF16Selection
        if let deletedText = edit.deletedText, !deletedText.isEmpty {
            replacementSelection = UTF16Selection(
                location:
                    edit.insertedText.isEmpty
                    ? edit.selectionAfter.location
                    : edit.selectionBefore.location,
                length: deletedText.utf16.count
            )
        } else {
            replacementSelection = edit.selectionBefore
        }
        guard
            let text = replacing(
                replacementSelection,
                in: fieldBefore.text,
                with: edit.insertedText
            )
        else {
            return nil
        }
        return CapturedFieldState(
            text: text,
            selection: edit.selectionAfter
        )
    }

    private static func selectedText(
        _ selection: UTF16Selection,
        in text: String
    ) -> String? {
        utf16Substring(in: text, selection: selection)
    }

    private static func utf16Substring(
        in text: String,
        selection: UTF16Selection
    ) -> String? {
        guard selection.isValid(for: text) else { return nil }
        let utf16 = text.utf16
        let lowerBound = utf16.index(
            utf16.startIndex,
            offsetBy: selection.location
        )
        let upperBound = utf16.index(
            lowerBound,
            offsetBy: selection.length
        )
        guard
            let lowerStringIndex = String.Index(
                lowerBound,
                within: text
            ),
            let upperStringIndex = String.Index(
                upperBound,
                within: text
            )
        else {
            return nil
        }
        return String(text[lowerStringIndex..<upperStringIndex])
    }
}
