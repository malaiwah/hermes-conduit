import XCTest
@testable import Conduit

/// One sentence for a finished run of steps (ChatStepSummaries): which run
/// is described, what the answer becomes, and how sentences are kept.
extension ChatTypographyTests {
    private func summaryStep(_ id: String, _ name: String = "terminal", running: Bool = false) -> ChatMessage {
        ChatMessage(
            id: "row-\(id)", role: .tool, content: "", timestamp: "2026-10-24T09:00:00Z",
            tool: ToolActivity(id: id, name: name, input: nil, output: nil, status: running ? .running : .complete)
        )
    }

    func testTheLastRunAfterTheUsersMessageIsDescribed() {
        let user = ChatMessage(id: "u", role: .user, content: "Find dinner", timestamp: "2026-10-24T09:00:00Z")
        let reply = ChatMessage(id: "a", role: .assistant, content: "Here you go", timestamp: "2026-10-24T09:01:00Z")
        let earlier = [summaryStep("e1"), summaryStep("e2"), summaryStep("e3")]
        let note = ChatMessage(id: "mid", role: .assistant, content: "Looking further", timestamp: "2026-10-24T09:00:30Z")
        let last = [summaryStep("c1", "web_search"), summaryStep("c2"), summaryStep("c3")]

        let run = ChatStepSummaries.lastRun(in: [user] + earlier + [note] + last + [reply])
        XCTAssertEqual(run?.map(\.id), last.map(\.id))
        // Any run that folds (two steps) with a tool call in it; one step,
        // or thinking alone, isn't described. Steps before the user's
        // message belong to an earlier turn.
        XCTAssertEqual(ChatStepSummaries.lastRun(in: [user, summaryStep("x1"), summaryStep("x2"), reply])?.count, 2)
        XCTAssertNil(ChatStepSummaries.lastRun(in: [user, summaryStep("x1"), reply]))
        let thinking = ChatMessage(id: "t", role: .reasoning, content: "Hmm", timestamp: "2026-10-24T09:00:10Z")
        XCTAssertNil(ChatStepSummaries.lastRun(in: [user, thinking, thinking, reply]))
        XCTAssertEqual(ChatStepSummaries.lastRun(in: [user, thinking, summaryStep("x1"), reply])?.count, 2)
        XCTAssertNil(ChatStepSummaries.lastRun(in: earlier + [user, reply]))
        // A step still running: the turn hasn't settled.
        XCTAssertNil(ChatStepSummaries.lastRun(in: [user, summaryStep("r1"), summaryStep("r2"), summaryStep("r3", running: true)]))
    }

    func testARunIsKeyedOnlyByAnIdOfItsOwn() {
        XCTAssertEqual(ChatStepSummaries.key(toolIDs: [nil, " ", "call_8fK2mQx9LpZ"]), "call_8fK2mQx9LpZ")
        XCTAssertEqual(ChatStepSummaries.key(toolIDs: ["toolu_01AbCdEfGhIj"]), "toolu_01AbCdEfGhIj")
        // Numbered per turn, or too short: they come back in other turns.
        XCTAssertNil(ChatStepSummaries.key(toolIDs: ["functions.web_search:0", "call_8fK2mQx9LpZ"]))
        XCTAssertNil(ChatStepSummaries.key(toolIDs: ["c1"]))
        XCTAssertNil(ChatStepSummaries.key(toolIDs: []))
    }

    func testTheAnswerBecomesOneParagraph() {
        XCTAssertEqual(ChatStepSummaries.cleaned("  \"I compared three menus and picked two.\"\n"), "I compared three menus and picked two.")
        XCTAssertEqual(
            ChatStepSummaries.cleaned("\n- I checked the **sandbox** first: 16 GB of RAM.\n\n2. Then I found the changelog entry."),
            "I checked the sandbox first: 16 GB of RAM. Then I found the changelog entry."
        )
        XCTAssertNil(ChatStepSummaries.cleaned(String(repeating: "word ", count: 400)))
        XCTAssertNil(ChatStepSummaries.cleaned("error: backend is retiring"))
        XCTAssertNil(ChatStepSummaries.cleaned("   "))
    }

    func testTheQuestionAsksForATrainOfThoughtAndIsRecognizable() {
        let question = ChatStepSummaries.question(language: "French", words: 27)
        XCTAssertTrue(question.hasPrefix(ChatStepSummaries.questionHead))
        XCTAssertTrue(question.contains("In French, tell the user, looking back, the train of thought"))
        XCTAssertTrue(question.contains("not a report of outcomes"))
        XCTAssertTrue(question.contains("Only the calls since the user's last message"))
        XCTAssertTrue(question.contains("at most 27 words"))
        XCTAssertTrue(question.contains("never the tool names"))
        // About one line on the phone per tool call.
        // About half a line on the phone per tool call, two lines to four.
        XCTAssertEqual(ChatStepSummaries.words(toolCount: 1), 18)
        XCTAssertEqual(ChatStepSummaries.words(toolCount: 5), 23)
        XCTAssertEqual(ChatStepSummaries.words(toolCount: 8), 36)
        XCTAssertEqual(ChatStepSummaries.words(toolCount: 40), 36)
        // Any language's and any budget's question is the summary's, never
        // the user's /btw.
        XCTAssertTrue(ChatStepSummaries.isQuestion(question))
        XCTAssertTrue(ChatStepSummaries.isQuestion(ChatStepSummaries.question(language: "Japanese", words: 72)))
        XCTAssertFalse(ChatStepSummaries.isQuestion("Look back at the tool calls you made just before your last reply"))
        // The whole question, not its first and last words.
        let edited = question.replacingOccurrences(of: "first person", with: "third person")
        XCTAssertFalse(ChatStepSummaries.isQuestion(edited))
        XCTAssertFalse(ChatStepSummaries.isQuestion(nil))
        // An earlier Conduit's one-sentence question is still kept out of the chat.
        let earlier = "Describe in one short sentence (at most 15 words) what you did in the tool calls just before your last reply. "
            + "It labels those steps, folded, in the user's chat app. "
            + "Write it in German, in the past tense, like \"Searched three sites and compared their prices\". "
            + "Reply with the sentence only."
        XCTAssertTrue(ChatStepSummaries.isQuestion(earlier))
        XCTAssertFalse(ChatStepSummaries.isQuestion("Describe in one short sentence what you just did"))
    }

    func testAnExplanationCarriesTheRunsCallsAndIsRecognizable() {
        let steps = [
            ToolActivity(id: "call_a1b2c3d4e5f6", name: "terminal", input: "{\"command\": \"free -h\"}",
                         output: "Mem:  16Gi\n  used 2Gi", status: .complete),
            ToolActivity(id: "call_b1b2c3d4e5f6", name: "web_search", input: String(repeating: "q", count: 500),
                         output: nil, status: .complete),
        ]
        let question = ChatStepSummaries.explainQuestion(language: "French", words: 36, steps: steps)
        XCTAssertTrue(question.hasPrefix(ChatStepSummaries.explainHead + ":\n1. terminal {\"command\": \"free -h\"}\n   → Mem: 16Gi used 2Gi\n2. web_search "))
        // Each call's arguments and result are trimmed to a line.
        XCTAssertTrue(question.contains(String(repeating: "q", count: 300) + "…\n"))
        XCTAssertFalse(question.contains(String(repeating: "q", count: 301)))
        XCTAssertTrue(question.contains("\nTell only these listed calls, nothing that came before or after. In French, tell the user, looking back"))
        XCTAssertTrue(ChatStepSummaries.isQuestion(question))
        XCTAssertFalse(ChatStepSummaries.isQuestion(question.replacingOccurrences(of: "first person", with: "third person")))
        XCTAssertFalse(ChatStepSummaries.isQuestion(ChatStepSummaries.explainHead + ": what did you do?"))
        // Longer than the folded summary, a few lines at least.
        XCTAssertEqual(ChatStepSummaries.explainWords(toolCount: 1), 36)
        XCTAssertEqual(ChatStepSummaries.explainWords(toolCount: 12), 54)
    }

    func testSentencesAreKeptPerProfileAndTheOldestGoFirst() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "StepSummaryTests-\(UUID().uuidString)"))
        XCTAssertFalse(ChatStepSummaries.isEnabled(defaults))
        // Longer runs keep their count unless asked; the limit stays in range.
        XCTAssertEqual(ChatStepSummaries.maxSteps(defaults), 20)
        defaults.set(500, forKey: ChatStepSummaries.maxStepsKey)
        XCTAssertEqual(ChatStepSummaries.maxSteps(defaults), 100)
        let home = "dash.default"
        for index in 0...ChatStepSummaries.savedLimit {
            ChatStepSummaries.save("Step \(index)", for: .init(scope: home, toolID: "k\(index)"), defaults: defaults)
        }
        let saved = try XCTUnwrap(ChatStepSummaries.saved(defaults)[home])
        XCTAssertEqual(saved.count, ChatStepSummaries.savedLimit)
        XCTAssertNil(saved["k0"])
        XCTAssertEqual(saved["k\(ChatStepSummaries.savedLimit)"], "Step \(ChatStepSummaries.savedLimit)")

        // The same tool call id on another profile is another run.
        ChatStepSummaries.save("Elsewhere", for: .init(scope: "dash.work", toolID: "k1"), defaults: defaults)
        ChatStepSummaries.save("Again", for: .init(scope: home, toolID: "k1"), defaults: defaults)
        let both = ChatStepSummaries.saved(defaults)
        XCTAssertEqual(both[home]?["k1"], "Again")
        XCTAssertEqual(both["dash.work"]?["k1"], "Elsewhere")

        // Signing a dashboard out forgets its profiles' sentences only.
        ChatStepSummaries.save("Other server", for: .init(scope: "dashboard2.default", toolID: "k1"), defaults: defaults)
        ChatStepSummaries.remove(scopePrefix: "dash.", defaults: defaults)
        XCTAssertEqual(ChatStepSummaries.saved(defaults), ["dashboard2.default": ["k1": "Other server"]])
        ChatStepSummaries.remove(scopePrefix: nil, defaults: defaults)
        XCTAssertTrue(ChatStepSummaries.saved(defaults).isEmpty)
    }
}
