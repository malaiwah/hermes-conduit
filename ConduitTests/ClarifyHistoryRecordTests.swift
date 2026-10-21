//
//  ClarifyHistoryRecordTests.swift
//  Conduit
//
//  A finished clarify tool row from persisted history reads back as its
//  answered card instead of the raw tool call (#394).
//

import XCTest
@testable import Conduit

extension ClarifyBatchStateTests {

    private func clarifyHistoryRow(input: String?, output: String?, status: ToolActivity.Status = .complete) -> ToolActivity {
        ToolActivity(id: "call_1", name: "clarify", input: input, output: output, status: status)
    }

    func testHistoryClarifyRowReadsBackAsAnsweredCard() throws {
        // The exact row from #394: current Hermes result shape.
        let tool = clarifyHistoryRow(
            input: #"{"questions": [{"question": "Which do you like better: Reddit or X?", "choices": ["Reddit", "X"]}]}"#,
            output: #"{"responses": [{"question": "Which do you like better: Reddit or X?", "choices_offered": ["Reddit", "X"], "status": "answered", "user_response": "Reddit"}], "outcome": "submitted"}"#
        )

        let record = try XCTUnwrap(ClarifyActivity.historyRecord(for: tool, rowID: "row-1"))

        XCTAssertEqual(record.requestId, "history-call_1")
        XCTAssertEqual(record.status, .answered)
        XCTAssertNil(record.error)
        XCTAssertEqual(record.questions.count, 1)
        XCTAssertEqual(record.questions[0].question, "Which do you like better: Reddit or X?")
        XCTAssertEqual(record.questions[0].choices.map(\.value), ["Reddit", "X"])
        XCTAssertEqual(record.questions[0].resolvedAnswer, "Reddit")
    }

    func testHistoryClarifyRowReadsTheSingleQuestionResultShape() throws {
        let tool = ToolActivity(
            id: nil,
            name: "clarify",
            input: #"{"question": "Which environment?", "choices": ["staging", "prod"]}"#,
            output: #"{"question": "Which environment?", "choices_offered": ["staging", "prod"], "user_response": "prod"}"#,
            status: .complete
        )

        let record = try XCTUnwrap(ClarifyActivity.historyRecord(for: tool, rowID: "row-7"))

        XCTAssertEqual(record.requestId, "history-row-7")
        XCTAssertEqual(record.status, .answered)
        XCTAssertEqual(record.questions[0].resolvedAnswer, "prod")
    }

    func testHistoryClarifyRowShowsMultiSelectAnswersInChoiceOrder() throws {
        let tool = clarifyHistoryRow(
            input: #"{"questions": [{"question": "Which tests should run?", "choices": ["unit", "ui", "lint"], "multi_select": true}]}"#,
            output: #"{"responses": [{"question": "Which tests should run?", "choices_offered": ["unit", "ui", "lint"], "status": "answered", "user_response": ["lint", "unit"]}], "outcome": "submitted"}"#
        )

        let record = try XCTUnwrap(ClarifyActivity.historyRecord(for: tool, rowID: "row-1"))

        XCTAssertTrue(record.questions[0].multiSelect)
        XCTAssertEqual(record.questions[0].resolvedAnswer, "unit, lint")
    }

    func testHistoryClarifyRowThatTimedOutReadsAsExpired() throws {
        let tool = clarifyHistoryRow(
            input: #"{"questions": [{"question": "Ship it?", "choices": ["Yes", "No"]}]}"#,
            output: #"{"responses": [{"question": "Ship it?", "choices_offered": ["Yes", "No"], "status": "unanswered", "user_response": null}], "outcome": "timed_out"}"#
        )

        let record = try XCTUnwrap(ClarifyActivity.historyRecord(for: tool, rowID: "row-1"))

        XCTAssertEqual(record.status, .expired)
        XCTAssertTrue(record.isExpired)
        XCTAssertNil(record.questions[0].answer)
        XCTAssertEqual(
            record.error,
            AppLocalization.string("This question is no longer active — Hermes timed it out and continued.")
        )
    }

    func testHistoryClarifyBatchKeepsEachQuestionsOwnState() throws {
        let tool = clarifyHistoryRow(
            input: #"{"questions": [{"question": "Which environment?", "choices": ["staging", "prod"]}, {"question": "Any notes?"}, {"question": "Notify the team?", "choices": ["Yes", "No"]}]}"#,
            output: #"{"responses": [{"question": "Which environment?", "choices_offered": ["staging", "prod"], "status": "answered", "user_response": "staging"}, {"question": "Any notes?", "choices_offered": null, "status": "skipped", "user_response": null}, {"question": "Notify the team?", "choices_offered": ["Yes", "No"], "status": "unanswered", "user_response": null}], "outcome": "cancelled"}"#
        )

        let record = try XCTUnwrap(ClarifyActivity.historyRecord(for: tool, rowID: "row-1"))

        XCTAssertEqual(record.questions.map(\.status), [.answered, .answered, .expired])
        XCTAssertEqual(record.questions[0].resolvedAnswer, "staging")
        XCTAssertEqual(record.questions[1].resolvedAnswer, AppLocalization.string("Skipped"))
        XCTAssertEqual(record.status, .expired)
        XCTAssertEqual(record.error, AppLocalization.string("These questions are no longer active."))
    }

    func testHistoryClarifyRowReadsTheNotifierPushAnswerShape() throws {
        // The notifier's push answer has no status or outcome fields.
        let tool = clarifyHistoryRow(
            input: #"{"questions": [{"question": "Pick one", "choices": ["a", "b"]}]}"#,
            output: #"{"responses": [{"question": "Pick one", "choices_offered": ["a", "b"], "user_response": "b"}]}"#
        )

        let record = try XCTUnwrap(ClarifyActivity.historyRecord(for: tool, rowID: "row-1"))

        XCTAssertEqual(record.status, .answered)
        XCTAssertEqual(record.questions[0].resolvedAnswer, "b")
    }

    func testHistoryClarifyRowReadsAMultiSelectAnswerInItsWireStringForm() throws {
        let tool = clarifyHistoryRow(
            input: #"{"questions": [{"question": "Which tests should run?", "choices": ["unit", "ui", "lint"], "multi_select": true}]}"#,
            output: #"{"responses": [{"question": "Which tests should run?", "choices_offered": ["unit", "ui", "lint"], "status": "answered", "user_response": "[\"lint\", \"unit\"]"}], "outcome": "submitted"}"#
        )

        let record = try XCTUnwrap(ClarifyActivity.historyRecord(for: tool, rowID: "row-1"))

        XCTAssertEqual(record.questions[0].resolvedAnswer, "unit, lint")
    }

    func testHistoryClarifyRowWithAnUnfamiliarResultKeepsTheToolCard() {
        let question = #"{"questions": [{"question": "Ship it?", "choices": ["Yes", "No"]}]}"#
        // A row status this build doesn't know.
        XCTAssertNil(ClarifyActivity.historyRecord(
            for: clarifyHistoryRow(
                input: question,
                output: #"{"responses": [{"question": "Ship it?", "choices_offered": ["Yes", "No"], "status": "deferred", "user_response": null}], "outcome": "submitted"}"#
            ),
            rowID: "row-1"
        ))
        // Answered, but with no answer to show.
        XCTAssertNil(ClarifyActivity.historyRecord(
            for: clarifyHistoryRow(
                input: question,
                output: #"{"responses": [{"question": "Ship it?", "choices_offered": ["Yes", "No"], "status": "answered", "user_response": null}], "outcome": "submitted"}"#
            ),
            rowID: "row-1"
        ))
    }

    func testClarifyRowsWithoutAReadableResultKeepTheToolCard() {
        let question = #"{"questions": [{"question": "Ship it?", "choices": ["Yes", "No"]}]}"#
        // Still waiting on the user.
        XCTAssertNil(ClarifyActivity.historyRecord(
            for: clarifyHistoryRow(input: question, output: nil, status: .running), rowID: "row-1"))
        // A compact resume row: an argument preview and no result.
        XCTAssertNil(ClarifyActivity.historyRecord(
            for: clarifyHistoryRow(input: "Ship it?", output: nil), rowID: "row-1"))
        // The tool refused the call.
        XCTAssertNil(ClarifyActivity.historyRecord(
            for: clarifyHistoryRow(input: question, output: #"{"error": "questions must be a non-empty array"}"#), rowID: "row-1"))
        // Not JSON.
        XCTAssertNil(ClarifyActivity.historyRecord(
            for: clarifyHistoryRow(input: question, output: "done"), rowID: "row-1"))
        // Another tool with a clarify-like result.
        XCTAssertNil(ClarifyActivity.historyRecord(
            for: ToolActivity(id: "call_2", name: "terminal", input: nil,
                              output: #"{"question": "Ship it?", "user_response": "Yes"}"#, status: .complete),
            rowID: "row-2"))
    }

    // MARK: - A clarify call Conduit can't answer (#14)

    func testAWaitingClarifyCallShowsItsQuestionNotItsArguments() throws {
        let tool = clarifyHistoryRow(
            input: #"{"questions": [{"question": "Ship it?", "choices": ["Yes", "No"]}, {"question": "Which branch?"}]}"#,
            output: nil,
            status: .running
        )
        XCTAssertNil(ClarifyActivity.historyRecord(for: tool, rowID: "row-1"))
        let preview = try XCTUnwrap(ClarifyToolCallPreview.make(for: tool))
        XCTAssertEqual(preview.state, .waiting)
        XCTAssertEqual(preview.questions, [
            .init(text: "Ship it?", choices: ["Yes", "No"]),
            .init(text: "Which branch?", choices: [])
        ])
        XCTAssertNil(preview.error)
    }

    func testALiveClarifyLabelReadsAsItsQuestion() throws {
        // Hermes' live tool.start carries only its label.
        let labelled = try XCTUnwrap(ClarifyToolCallPreview.make(
            for: clarifyHistoryRow(input: "Asking Which environment?", output: nil, status: .running)))
        XCTAssertEqual(labelled.questions, [.init(text: "Which environment?", choices: [])])

        let bare = try XCTUnwrap(ClarifyToolCallPreview.make(
            for: clarifyHistoryRow(input: "Asking", output: nil, status: .running)))
        XCTAssertEqual(bare.questions, [], "a bare verb isn't a question")

        let none = try XCTUnwrap(ClarifyToolCallPreview.make(
            for: clarifyHistoryRow(input: nil, output: nil, status: .running)))
        XCTAssertEqual(none.questions, [])
    }

    func testAFinishedClarifyCallConduitCantReadSaysWhatItKnows() throws {
        let question = #"{"question": "Ship it?", "choices": ["Yes", "No"]}"#
        let refused = try XCTUnwrap(ClarifyToolCallPreview.make(
            for: clarifyHistoryRow(input: question, output: #"{"error": "questions must be a non-empty array"}"#)))
        XCTAssertEqual(refused.state, .notAnswered)
        XCTAssertEqual(refused.error, "questions must be a non-empty array")

        // A compact resume row carries no result: whether it was answered
        // is unknown, so it isn't called unanswered.
        let compact = try XCTUnwrap(ClarifyToolCallPreview.make(
            for: clarifyHistoryRow(input: "Ship it?", output: nil)))
        XCTAssertEqual(compact.state, .finished)
        XCTAssertEqual(compact.questions, [.init(text: "Ship it?", choices: [])])

        XCTAssertNil(ClarifyToolCallPreview.make(
            for: ToolActivity(id: "call_2", name: "terminal", input: question, output: nil, status: .running)))
    }

    func testAClarifyResultConduitDoesntRecognizeKeepsTheToolCard() {
        let question = #"{"questions": [{"question": "Ship it?", "choices": ["Yes", "No"]}]}"#
        for output in [
            #"{"responses": [{"question": "Ship it?", "status": "deferred", "user_response": null}], "outcome": "submitted"}"#,
            #"{"responses": [{"question": "Ship it?", "status": "answered", "user_response": null}], "outcome": "submitted"}"#,
            "done"
        ] {
            let tool = clarifyHistoryRow(input: question, output: output)
            XCTAssertNil(ClarifyActivity.historyRecord(for: tool, rowID: "row-1"))
            XCTAssertNil(ClarifyToolCallPreview.make(for: tool), "\(output) stays readable on the tool card")
        }
    }

    func testClarifyArgumentsCutShortInASavedChatAreNeverShownAsTheQuestion() throws {
        // A saved chat keeps the first 600 characters of a call's input.
        let cut = String(#"{"questions": [{"question": "Which of these "# + String(repeating: "x", count: 700)).prefix(600)
        let preview = try XCTUnwrap(ClarifyToolCallPreview.make(
            for: clarifyHistoryRow(input: String(cut), output: nil, status: .running)))
        XCTAssertEqual(preview.questions, [])
    }

    func testAClarifyResultWithANullErrorReadsBack() throws {
        let tool = clarifyHistoryRow(
            input: #"{"question": "Ship it?", "choices": ["Yes", "No"]}"#,
            output: #"{"question": "Ship it?", "choices_offered": ["Yes", "No"], "user_response": "Yes", "error": null}"#
        )
        XCTAssertEqual(try XCTUnwrap(ClarifyActivity.historyRecord(for: tool, rowID: "row-1")).questions.first?.resolvedAnswer, "Yes")
    }
}
