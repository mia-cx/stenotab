public enum CompletionSanitizer {
    public static func sanitize(
        _ rawCompletion: String,
        after prefix: String,
        maximumWords: Int
    ) -> String {
        guard maximumWords > 0 else { return "" }

        var candidate = rawCompletion
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

        guard
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
