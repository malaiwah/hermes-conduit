//
//  ClarifyHistoryRecord.swift
//  Conduit
//
//  A finished clarify call read back from persisted history (#394).
//

import Foundation

extension ClarifyActivity {
    /// The read-only card for a finished `clarify` tool row from persisted
    /// history. The live card is its own `.clarify` row, and a transcript
    /// reload only brings pending cards back, so without this an answered
    /// question came back as the bare tool call: its Input JSON and a green
    /// check (#394).
    ///
    /// Reads every result shape Hermes has written: the current
    /// `{"responses": [{question, choices_offered, status, user_response}],
    /// "outcome"}`, the older batch `{"responses": [...]}` (also what the
    /// notifier returns for a push answer) and the single-question
    /// `{question, choices_offered, user_response}`. Nil for anything else
    /// (a running call, an error, a compact resume row without its result),
    /// which keeps the ordinary tool card.
    static func historyRecord(for tool: ToolActivity, rowID: String) -> ClarifyActivity? {
        guard tool.name.lowercased() == "clarify",
              tool.status == .complete,
              let result = jsonObject(tool.output),
              result["error"] == nil || result["error"] is NSNull else { return nil }
        let rows: [[String: Any]]
        if let responses = result["responses"] as? [[String: Any]] {
            rows = responses
        } else if result["question"] != nil {
            rows = [result]
        } else {
            return nil
        }
        // The call's arguments fill in what an older result row leaves out
        // (multi-select, choices). A compact resume row carries only a text
        // preview here, which simply contributes nothing.
        let asked = askedQuestions(in: jsonObject(tool.input))
        var questions: [ClarifyQuestion] = []
        for (index, row) in rows.enumerated() {
            let call = index < asked.count ? asked[index] : [:]
            // A row status this build doesn't know keeps the tool card
            // rather than guessing at what happened.
            let status = row["status"] as? String
            let knownStatuses: [String?] = [nil, "answered", "skipped", "unanswered"]
            guard knownStatuses.contains(status) else { return nil }
            guard let text = nonEmptyText(row["question"]) ?? nonEmptyText(call["question"]) else { continue }
            let offered = textList(row["choices_offered"]) ?? textList(call["choices"]) ?? []
            var question = ClarifyQuestion(
                id: "q\(index)",
                question: text,
                choices: offered.map { ClarifyChoice(label: $0, value: $0) },
                multiSelect: (call["multi_select"] as? Bool) == true,
                status: .expired,
                isSyntheticID: true
            )
            // A multi-select answer is a JSON array, or the same array in
            // its wire string form.
            let values = textList(row["user_response"]) ?? jsonTextList(row["user_response"])
            if status == "skipped" {
                question.status = .answered
                question.answer = AppLocalization.string("Skipped")
            } else if let values, !values.isEmpty {
                question.status = .answered
                question.multiSelect = true
                question.answer = ClarifyQuestion.multiSelectAnswer(values)
            } else if let answer = nonEmptyText(row["user_response"]) {
                question.status = .answered
                question.answer = answer
            } else if status == "answered" {
                return nil
            }
            questions.append(question)
        }
        guard !questions.isEmpty else { return nil }
        var record = ClarifyActivity(requestId: "history-\(tool.id ?? rowID)", questions: questions)
        if questions.contains(where: { $0.status == .expired }) {
            record.isExpired = true
            // The same notice the live card shows once Hermes stops waiting.
            let timedOut = (result["outcome"] as? String) == "timed_out"
            switch (timedOut, questions.count > 1) {
            case (true, true):
                record.error = AppLocalization.string("These questions are no longer active — Hermes timed them out and continued.")
            case (true, false):
                record.error = AppLocalization.string("This question is no longer active — Hermes timed it out and continued.")
            case (false, true):
                record.error = AppLocalization.string("These questions are no longer active.")
            case (false, false):
                record.error = AppLocalization.string("This question is no longer active.")
            }
        }
        return record
    }

    fileprivate static func jsonObject(_ text: String?) -> [String: Any]? {
        guard let data = text?.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The call's questions: current `questions[]`, or one legacy scalar
    /// `{question, choices}`.
    fileprivate static func askedQuestions(in arguments: [String: Any]?) -> [[String: Any]] {
        guard let arguments else { return [] }
        if let questions = arguments["questions"] as? [[String: Any]] { return questions }
        return arguments["question"] != nil ? [arguments] : []
    }

    fileprivate static func nonEmptyText(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    fileprivate static func textList(_ value: Any?) -> [String]? {
        guard let items = value as? [Any] else { return nil }
        return items.compactMap { nonEmptyText($0) }
    }

    /// A list sent as JSON text, such as `["lint","unit"]`.
    private static func jsonTextList(_ value: Any?) -> [String]? {
        guard let text = nonEmptyText(value), text.hasPrefix("["),
              let data = text.data(using: .utf8),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        return items.compactMap { nonEmptyText($0) }
    }
}

/// A clarify call Conduit can't answer: its question never reached this
/// device as an answerable card (another surface is driving the chat, or
/// the request went out while Conduit was away), or the call ended without
/// an answer Conduit can read. Shown as a read-only card with the question
/// and its choices instead of the call's raw arguments.
struct ClarifyToolCallPreview: Equatable {
    struct Question: Equatable {
        var text: String
        var choices: [String]
    }

    enum State: Equatable {
        /// The call is still running: Hermes may be waiting on an answer.
        case waiting
        /// The call failed or was refused.
        case notAnswered
        /// The call finished, but its result isn't one Conduit can read (a
        /// compact resume row carries none): what was answered is unknown.
        case finished
    }

    /// Empty when only Hermes' "Asking" label reached Conduit.
    var questions: [Question]
    var state: State
    /// The tool's own error, when it refused or failed the call.
    var error: String?

    /// The preview for a clarify row that `ClarifyActivity.historyRecord`
    /// doesn't turn into an answered card: a call still running, one that
    /// finished with no result Conduit has, or one the tool refused. Nil for
    /// any other tool, and for a result Conduit doesn't recognize, which
    /// keeps the ordinary tool card so the result stays readable.
    static func make(for tool: ToolActivity) -> ClarifyToolCallPreview? {
        guard tool.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "clarify" else { return nil }
        let output = tool.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state: State
        var error: String?
        if tool.status == .running {
            state = .waiting
        } else if output.isEmpty {
            state = .finished
        } else if let refusal = ClarifyActivity.jsonObject(output).flatMap({ ClarifyActivity.nonEmptyText($0["error"]) }) {
            state = .notAnswered
            error = refusal
        } else {
            return nil
        }

        var questions: [Question] = []
        if let arguments = ClarifyActivity.jsonObject(tool.input) {
            questions = ClarifyActivity.askedQuestions(in: arguments).compactMap { call in
                guard let text = ClarifyActivity.nonEmptyText(call["question"]) else { return nil }
                return Question(text: text, choices: ClarifyActivity.textList(call["choices"]) ?? [])
            }
        } else if let label = ClarifyActivity.nonEmptyText(tool.input),
                  !label.hasPrefix("{"), !label.hasPrefix("[") {
            // Hermes' tool label ("Asking <question>"), or a compact resume
            // row's argument preview. Arguments cut short in a saved chat
            // aren't JSON any more and are never shown as the question.
            let question = label.hasPrefix(Self.liveLabelVerb + " ")
                ? String(label.dropFirst(Self.liveLabelVerb.count + 1))
                : (label == Self.liveLabelVerb ? "" : label)
            if let text = ClarifyActivity.nonEmptyText(question) {
                questions = [Question(text: text, choices: [])]
            }
        }
        return ClarifyToolCallPreview(questions: questions, state: state, error: error)
    }

    /// The verb Hermes' tool label puts before a clarify question
    /// (`agent/display.py` `_TOOL_VERBS`).
    static let liveLabelVerb = "Asking"
}

extension ChatMessage {
    /// This row presented with `clarify` attached, for a view that renders
    /// it as a clarify card. The stored transcript row is unchanged.
    func presenting(_ clarify: ClarifyActivity) -> ChatMessage {
        var copy = self
        copy.clarify = clarify
        return copy
    }
}
