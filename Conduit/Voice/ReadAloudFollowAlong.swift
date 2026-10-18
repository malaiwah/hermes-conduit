//
//  ReadAloudFollowAlong.swift
//  Conduit
//
//  The reply Read Aloud is playing, split into the sentences its reading
//  view highlights (#759).
//
//  Hermes' speech stream sends audio only: no word or sentence timings
//  reach the phone. The sentence being spoken is therefore estimated. Each
//  sentence gets a weight for roughly how long it takes to say (letters,
//  digits, a pause at its end), and the share of the reply's audio heard so
//  far picks the sentence at the same share of the total weight. Until the
//  stream has delivered all its audio the total length is unknown, so a
//  typical speaking pace stands in for it.
//

import Foundation
import NaturalLanguage

struct ReadAloudScript: Equatable {
    enum Kind: Equatable {
        case sentence
        /// A fenced code block: shown, but counted as unspoken.
        case code
    }

    struct Segment: Equatable, Identifiable {
        let id: Int
        let text: String
        /// Sentences of one paragraph share it, so the view can lay them
        /// out as running text.
        let paragraph: Int
        let kind: Kind
        /// Roughly how long the segment takes to say, in weight units.
        let weight: Double
    }

    let segments: [Segment]
    let totalWeight: Double

    /// Weight units a voice says per second of source audio, at 1x. Only
    /// used until the stream has delivered all of its audio.
    static let typicalWeightPerSecond = 13.0
    /// The breath at the end of a sentence, and the longer one between
    /// paragraphs, in weight units.
    static let sentencePause = 4.0
    static let paragraphPause = 3.0

    init(segments: [Segment]) {
        self.segments = segments
        totalWeight = segments.reduce(0) { $0 + $1.weight }
    }

    /// The segment being spoken, or nil when nothing in the reply is
    /// counted as spoken. `isComplete` says every second of the reply's
    /// audio has arrived, so `receivedSeconds` is its full length.
    func segmentIndex(playedSeconds: TimeInterval, receivedSeconds: TimeInterval, isComplete: Bool) -> Int? {
        guard totalWeight > 0 else { return nil }
        let played = max(0, playedSeconds)
        let target: Double
        if isComplete, receivedSeconds > 0 {
            target = min(1, played / receivedSeconds) * totalWeight
        } else {
            target = played * Self.typicalWeightPerSecond
        }
        var end = 0.0
        var lastSpoken: Int?
        for (index, segment) in segments.enumerated() where segment.weight > 0 {
            end += segment.weight
            lastSpoken = index
            if target < end { return index }
        }
        return lastSpoken
    }

    // MARK: - Building

    static func make(from readable: String) -> ReadAloudScript {
        var segments: [Segment] = []
        var paragraph = 0
        for block in blocks(in: readable) {
            switch block {
            case .code(let code):
                segments.append(Segment(id: segments.count, text: code, paragraph: paragraph, kind: .code, weight: 0))
            case .prose(let text):
                let sentences = Self.sentences(in: text)
                // Nothing to show: the next block takes this paragraph id.
                guard !sentences.isEmpty else { continue }
                for (offset, sentence) in sentences.enumerated() {
                    var weight = spokenWeight(of: sentence)
                    if weight > 0 {
                        weight += sentencePause
                        if offset == 0, paragraph > 0 { weight += paragraphPause }
                    }
                    segments.append(Segment(id: segments.count, text: sentence, paragraph: paragraph, kind: .sentence, weight: weight))
                }
            }
            paragraph += 1
        }
        return ReadAloudScript(segments: segments)
    }

    enum Block: Equatable {
        case prose(String)
        case code(String)
    }

    /// Paragraphs and fenced code blocks, with Markdown markup taken out of
    /// the prose. A heading, list item, quote or table row is a paragraph
    /// of its own.
    static func blocks(in text: String) -> [Block] {
        var blocks: [Block] = []
        var prose: [String] = []
        var code: [String]?
        var fence = ""

        func flushProse() {
            let joined = prose.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.prose(joined)) }
            prose = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if line.hasPrefix(fence) {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(rawLine)
                    code = lines
                }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushProse()
                fence = String(line.prefix(3))
                code = []
                continue
            }
            if line.isEmpty || isTableRule(line) {
                flushProse()
                continue
            }
            let (cleaned, standsAlone) = cleanedLine(line)
            if standsAlone { flushProse() }
            if !cleaned.isEmpty { prose.append(cleaned) }
            if standsAlone { flushProse() }
        }
        // An unclosed fence still shows what it held.
        if let code, !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
        flushProse()
        return blocks
    }

    /// The line without its block marker, and whether that marker makes it
    /// a paragraph of its own.
    private static func cleanedLine(_ line: String) -> (String, Bool) {
        var text = Substring(line)
        var standsAlone = false
        if text.hasPrefix("#") {
            text = text.drop(while: { $0 == "#" })
            standsAlone = true
        } else if text.hasPrefix(">") {
            text = text.drop(while: { $0 == ">" })
            standsAlone = true
        } else if text.hasPrefix("|") {
            text = Substring(text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: ", "))
            standsAlone = true
        } else if let marker = listMarkerLength(text) {
            text = text.dropFirst(marker)
            standsAlone = true
        }
        return (inlineCleaned(String(text)).trimmingCharacters(in: .whitespaces), standsAlone)
    }

    /// "- ", "* ", "+ " or "12. " / "12) ".
    private static func listMarkerLength(_ text: Substring) -> Int? {
        if let first = text.first, "-*+•".contains(first), text.dropFirst().first == " " { return 2 }
        let digits = text.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = text.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return digits.count + 2
    }

    /// A table's `|---|---|` row, or a `---` rule: both only separate, so
    /// they end the paragraph and show nothing.
    private static func isTableRule(_ line: String) -> Bool {
        line.contains("-") && line.allSatisfy { "|-: ".contains($0) }
    }

    private static let inlineRules: [(NSRegularExpression, String)] = ([
        (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
        (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
        (#"`([^`]*)`"#, "$1"),
        (#"(\*\*|__|~~)(.+?)\1"#, "$2"),
        (#"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#, "$1"),
        (#"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#, "$1"),
    ] as [(String, String)]).compactMap { pattern, template in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
    }

    /// Links show their words, and emphasis and code markers go.
    static func inlineCleaned(_ text: String) -> String {
        inlineRules.reduce(text) { text, rule in
            rule.0.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: rule.1
            )
        }
    }

    static func sentences(in paragraph: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = paragraph
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
            let sentence = paragraph[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences
    }

    private static let urlPattern = try? NSRegularExpression(pattern: #"https?://\S+"#)

    /// Roughly how long a sentence takes to say: what a reader would hear,
    /// so narrated actions and emoji (SpokenTextFilter) and bare links weigh
    /// nothing, and digits weigh more than letters ("2026" is said as four
    /// syllables).
    static func spokenWeight(of sentence: String) -> Double {
        var spoken = SpokenTextFilter.filter(sentence)
        if let urlPattern {
            spoken = urlPattern.stringByReplacingMatches(
                in: spoken,
                range: NSRange(spoken.startIndex..., in: spoken),
                withTemplate: " "
            )
        }
        var weight = 0.0
        var spokenSomething = false
        for character in spoken {
            if character.isNumber {
                weight += 2
                spokenSomething = true
            } else if character.isLetter {
                // Ideographs carry a syllable each, more than a Latin letter.
                weight += character.unicodeScalars.first.map(isIdeograph) == true ? 3 : 1
                spokenSomething = true
            } else if character.isWhitespace {
                weight += 0.3
            }
        }
        return spokenSomething ? weight : 0
    }

    private static func isIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}
