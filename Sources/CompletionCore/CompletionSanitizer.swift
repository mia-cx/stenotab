public enum CompletionSanitizer {
    public static func sanitize(
        _ rawCompletion: String,
        after prefix: String,
        maximumWords: Int,
        inferLeadingSpace: Bool = true
    ) -> String {
        guard maximumWords > 0 else { return "" }

        var candidate = rawCompletion
        while candidate.first == "\n" || candidate.first == "\r" {
            candidate.removeFirst()
        }
        let visibleStart = candidate.drop(while: \.isWhitespace)
            .lowercased()
        if visibleStart.hasPrefix("[")
            || [
                "completion instructions:",
                "context:",
                "ocr content from snapshot:",
                "clipboard content:",
                "relevant input history:",
                "user voice assessment:",
                "custom voice:",
                "text before cursor:",
                "text after cursor:",
                "current application:",
                "current website:",
                "application:",
                "kind of input:",
                "text to continue:",
                "task:",
                "text:",
                "insertion:",
            ].contains(where: visibleStart.hasPrefix) {
            return ""
        }
        if visibleStart.hasPrefix("<")
            || visibleStart.hasPrefix("```") {
            return ""
        }
        for marker in [
            "\n",
            "<end_of_turn>",
            "<eos>",
            "<|end|>",
            "<|eot_id|>",
        ] {
            if let range = candidate.range(of: marker) {
                candidate = String(candidate[..<range.lowerBound])
            }
        }

        var limited = ""
        var wordCount = 0
        var insideWord = false
        for character in candidate {
            if character.isWhitespace {
                limited.append(character)
                insideWord = false
                continue
            }
            if !insideWord {
                wordCount += 1
                guard wordCount <= maximumWords else { break }
                insideWord = true
            }
            limited.append(character)
        }
        while limited.last?.isWhitespace == true {
            limited.removeLast()
        }

        if prefix.last?.isWhitespace == true {
            while limited.first?.isWhitespace == true {
                limited.removeFirst()
            }
            return limited
        }

        guard
            inferLeadingSpace,
            let previous = prefix.last,
            let first = limited.first,
            !first.isWhitespace,
            isWordCharacter(previous),
            isWordCharacter(first)
        else {
            return limited
        }
        return " " + limited
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
