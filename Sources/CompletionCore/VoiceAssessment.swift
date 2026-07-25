import Foundation
import NaturalLanguage

public struct VoiceAssessment: Codable, Sendable, Equatable {
    public let summary: String
    public let sampleCount: Int
    public let sourceEventCount: Int
    public let generatedAt: Date
    public let analyzerVersion: Int?

    public init(
        summary: String,
        sampleCount: Int,
        sourceEventCount: Int,
        generatedAt: Date,
        analyzerVersion: Int? = VoiceAssessmentAnalyzer.currentVersion
    ) {
        self.summary = summary
        self.sampleCount = sampleCount
        self.sourceEventCount = sourceEventCount
        self.generatedAt = generatedAt
        self.analyzerVersion = analyzerVersion
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
        guard
            existing.analyzerVersion == VoiceAssessmentAnalyzer.currentVersion
        else {
            return true
        }
        let newEvents = sourceEventCount - existing.sourceEventCount
        if newEvents >= 25 {
            return true
        }
        return newEvents >= 5
            && date.timeIntervalSince(existing.generatedAt) >= 24 * 60 * 60
    }
}

public enum VoiceAssessmentAnalyzer {
    public static let currentVersion = 2

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
        let languageTrait = languageTrait(in: samples)
        let englishVariety = englishVariety(in: samples)

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
        if let languageTrait {
            traits.append(languageTrait)
        }
        switch englishVariety {
        case .british:
            traits.append(
                "I usually write in British English and prefer British "
                    + "spellings."
            )
        case .american:
            traits.append(
                "I usually write in American English and prefer American "
                    + "spellings."
            )
        case .mixed:
            traits.append(
                "I mix British and American English spellings."
            )
        case .undetermined:
            break
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

    private static func languageTrait(in samples: [String]) -> String? {
        var counts: [NLLanguage: Int] = [:]

        for sample in samples {
            guard
                let hypothesis = languageHypothesis(for: sample),
                hypothesis.confidence >= 0.75
            else {
                continue
            }
            counts[hypothesis.language, default: 0] += 1
        }

        let recognizedCount = counts.values.reduce(0, +)
        guard recognizedCount >= 4 else { return nil }
        let supported = counts
            .filter {
                $0.value >= 3
                    && Double($0.value) / Double(recognizedCount) >= 0.25
            }
            .sorted { lhs, rhs in
                if lhs.key == .english { return true }
                if rhs.key == .english { return false }
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.rawValue < rhs.key.rawValue
            }

        if supported.count >= 2 {
            let names = supported.prefix(2).compactMap {
                languageName(for: $0.key)
            }
            guard names.count == 2 else { return nil }
            return "I switch between \(names[0]) and \(names[1])."
        }

        guard
            let dominant = supported.first,
            dominant.key != .english,
            Double(dominant.value) / Double(recognizedCount) >= 0.6,
            let name = languageName(for: dominant.key)
        else {
            return nil
        }
        return "I usually write in \(name)."
    }

    private static func languageName(for language: NLLanguage) -> String? {
        Locale(identifier: "en").localizedString(
            forLanguageCode: language.rawValue
        )
    }

    private static func languageHypothesis(
        for sample: String
    ) -> (language: NLLanguage, confidence: Double)? {
        guard sample.filter(\.isLetter).count >= 20 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard
            let hypothesis = recognizer
                .languageHypotheses(withMaximum: 1)
                .max(by: { $0.value < $1.value }),
            hypothesis.key != .undetermined
        else {
            return nil
        }
        return (hypothesis.key, hypothesis.value)
    }

    private enum EnglishVariety {
        case american
        case british
        case mixed
        case undetermined
    }

    private static func englishVariety(in samples: [String]) -> EnglishVariety {
        let britishMarkers: Set<String> = [
            "behaviour", "cancelled", "centre", "colour", "defence",
            "favourite", "honour", "labelled", "licence", "modelling",
            "organise", "organised", "organising", "practise", "programme",
            "realise", "realised", "realising", "theatre", "travelled",
            "travelling"
        ]
        let americanMarkers: Set<String> = [
            "behavior", "canceled", "center", "color", "defense", "favorite",
            "honor", "labeled", "modeling", "organize", "organized",
            "organizing", "realize", "realized", "realizing", "theater",
            "traveled", "traveling"
        ]
        var britishWords: Set<String> = []
        var britishSamples = 0
        var americanWords: Set<String> = []
        var americanSamples = 0

        for sample in samples {
            if
                let language = languageHypothesis(for: sample),
                language.confidence >= 0.75,
                language.language != .english
            {
                continue
            }
            let words = normalizedWords(in: sample)
            let britishMatches = words.intersection(britishMarkers)
            if !britishMatches.isEmpty {
                britishWords.formUnion(britishMatches)
                britishSamples += 1
            }
            let americanMatches = words.intersection(americanMarkers)
            if !americanMatches.isEmpty {
                americanWords.formUnion(americanMatches)
                americanSamples += 1
            }
        }

        let hasBritishEvidence =
            britishWords.count >= 3 && britishSamples >= 3
        let hasAmericanEvidence =
            americanWords.count >= 3 && americanSamples >= 3

        if hasBritishEvidence, hasAmericanEvidence {
            return .mixed
        }
        if hasBritishEvidence {
            return .british
        }
        if hasAmericanEvidence {
            return .american
        }
        return .undetermined
    }

    private static func normalizedWords(in text: String) -> Set<String> {
        Set(
            text.split(whereSeparator: \.isWhitespace).compactMap { part in
                let word = part
                    .lowercased()
                    .trimmingCharacters(
                        in: CharacterSet.alphanumerics.inverted
                    )
                return word.isEmpty ? nil : word
            }
        )
    }
}
