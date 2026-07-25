import Foundation

public struct VoiceAssessment: Codable, Sendable, Equatable {
    public let summary: String
    public let sampleCount: Int
    public let sourceEventCount: Int
    public let generatedAt: Date

    public init(
        summary: String,
        sampleCount: Int,
        sourceEventCount: Int,
        generatedAt: Date
    ) {
        self.summary = summary
        self.sampleCount = sampleCount
        self.sourceEventCount = sourceEventCount
        self.generatedAt = generatedAt
    }
}

public enum VoiceAssessmentSchedule {
    public static func shouldAssess(
        existing: VoiceAssessment?,
        sourceEventCount: Int,
        at date: Date = Date()
    ) -> Bool {
        guard sourceEventCount >= 10 else { return false }
        guard let existing else { return true }
        let newEvents = sourceEventCount - existing.sourceEventCount
        if newEvents >= 25 {
            return true
        }
        return newEvents >= 5
            && date.timeIntervalSince(existing.generatedAt) >= 24 * 60 * 60
    }
}

public enum VoiceAssessmentAnalyzer {
    public static func assess(
        texts: [String],
        sourceEventCount: Int,
        at date: Date = Date()
    ) -> VoiceAssessment? {
        let samples = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !samples.isEmpty else { return nil }

        let words = samples.flatMap {
            $0.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        guard !words.isEmpty else { return nil }

        let averageWords = Double(words.count) / Double(samples.count)
        let lowercaseStarts = samples.filter {
            firstLetter(in: $0)?.isLowercase == true
        }.count
        let contractions = words.filter {
            $0.contains("'") || $0.contains("’")
        }.count
        let questions = samples.filter { $0.hasSuffix("?") }.count
        let exclamations = samples.filter { $0.hasSuffix("!") }.count
        let terminalPunctuation = samples.filter {
            guard let last = $0.last else { return false }
            return ".!?".contains(last)
        }.count
        let emojiSamples = samples.filter { text in
            text.unicodeScalars.contains {
                $0.properties.isEmojiPresentation
            }
        }.count
        let technicalWords = words.filter(isTechnicalWord).count

        var traits: [String] = []
        switch averageWords {
        case ..<9:
            traits.append("I usually write short, direct messages.")
        case ..<19:
            traits.append("I usually write concise, medium-length text.")
        default:
            traits.append("I often write longer, detailed passages.")
        }

        let sampleTotal = Double(samples.count)
        if Double(lowercaseStarts) / sampleTotal >= 0.4 {
            traits.append("I often start casual writing in lowercase.")
        }
        if Double(contractions) / Double(words.count) >= 0.08 {
            traits.append("I use contractions frequently.")
        }
        if Double(questions) / sampleTotal >= 0.2 {
            traits.append("I often ask direct questions.")
        }
        if Double(exclamations) / sampleTotal >= 0.15 {
            traits.append("I sometimes use exclamation marks for emphasis.")
        }
        if Double(terminalPunctuation) / sampleTotal < 0.4 {
            traits.append(
                "I often omit terminal punctuation in casual messages."
            )
        }
        if Double(emojiSamples) / sampleTotal >= 0.1 {
            traits.append("I sometimes use emoji.")
        }
        if Double(technicalWords) / Double(words.count) >= 0.03 {
            traits.append(
                "I use technical terms and identifier-style casing when "
                    + "they are relevant."
            )
        }

        return VoiceAssessment(
            summary: traits.joined(separator: " "),
            sampleCount: samples.count,
            sourceEventCount: sourceEventCount,
            generatedAt: date
        )
    }

    private static func firstLetter(in text: String) -> Character? {
        text.first(where: \.isLetter)
    }

    private static func isTechnicalWord(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 3 else { return false }
        let uppercaseAfterFirst = letters.dropFirst().contains(
            where: \.isUppercase
        )
        return uppercaseAfterFirst
            || word.contains("_")
            || word.contains("::")
            || word.contains("/")
    }
}
