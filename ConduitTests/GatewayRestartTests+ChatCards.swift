import XCTest
@testable import Conduit

/// The chat's plan card (AgentPlan.swift, ChatCardsModel.swift;
/// docs/PLAN_CARD.md). An extension, so no new class to plan.
@MainActor
extension GatewayRestartTests {
    private static let longAgo = "2020-01-01T10:00:00Z"

    private func nowStamp(_ offset: TimeInterval = 0) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset))
    }

    private func todoRow(_ id: String, input: String? = nil, output: String? = nil,
                         at timestamp: String = GatewayRestartTests.longAgo) -> ChatMessage {
        ChatMessage(
            id: id, role: .tool, content: "", timestamp: timestamp,
            tool: ToolActivity(id: "call-\(id)", name: "todo", input: input, output: output,
                               status: output == nil ? .running : .complete)
        )
    }

    private func reply(_ id: String, _ text: String, at timestamp: String = GatewayRestartTests.longAgo) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, content: text, timestamp: timestamp)
    }

    /// A Hermes 0.21 `todo` result.
    private func result(_ items: [(String, String, String)], revision: Int = 1) -> String {
        let todos = items.map { #"{"id":"\#($0.0)","content":"\#($0.1)","status":"\#($0.2)"}"# }
        return #"{"todos":[\#(todos.joined(separator: ","))],"revision":\#(revision),"summary":{"total":\#(items.count)}}"#
    }

    private var cardsChat: ChatCardsChat { ChatCardsChat(profile: "default", ids: ["s1"])! }

    private func freshDefaults() -> UserDefaults {
        let name = "chat-cards-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Reading the plan

    func testPlanReadsHermesTodoResult() {
        let plan = AgentPlan(snapshotJSON: result([("1", "Read the logs", "completed"), ("2", "Fix it", "in_progress"),
                                                   ("3", "Ship", "pending")], revision: 4))
        XCTAssertEqual(plan?.items.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(plan?.revision, 4)
        XCTAssertEqual(plan?.completedCount, 1)
        XCTAssertEqual(plan?.current?.content, "Fix it")
        XCTAssertEqual(plan?.isFinished, false)
        XCTAssertNil(AgentPlan(snapshotJSON: #"{"error":"todos must be a list"}"#))
        XCTAssertNil(AgentPlan(snapshotJSON: "Updated the plan"))
    }

    func testPlanKeepsUnknownStatusPendingAndDropsDanglingParents() {
        let plan = AgentPlan(snapshot: ["todos": [
            ["id": "a", "content": "Phase", "status": "weird"],
            ["id": "b", "content": "Sub", "status": "pending", "parent": "a"],
            ["id": "c", "content": "Orphan", "status": "pending", "parent": "zz"],
            ["id": "a", "content": "Phase again", "status": "completed"],
        ]])!
        XCTAssertEqual(plan.items.map(\.id), ["b", "c", "a"], "the last row for an id wins, in its own place")
        XCTAssertEqual(plan.items[0].parent, "a")
        XCTAssertNil(plan.items[1].parent)
        XCTAssertEqual(plan.depth(of: plan.items[0]), 1)
    }

    func testTranscriptPlanIsTheNewestFullResult() {
        let messages = [
            todoRow("t1", output: result([("1", "Old plan", "pending")])),
            reply("r1", "Working"),
            todoRow("t2", output: result([("1", "Old plan", "completed"), ("2", "Next", "in_progress")], revision: 2)),
            // A read and an error say nothing new.
            todoRow("t3", input: "{}", output: #"{"error":"store missing"}"#),
        ]
        let latest = AgentPlanTranscript.latest(in: messages)
        XCTAssertEqual(latest?.messageID, "t2")
        XCTAssertEqual(latest?.plan.items.map(\.status), [.completed, .inProgress])
    }

    func testTranscriptReplaysMergesOverTheLastFullPlan() {
        let messages = [
            todoRow("t1", output: result([("1", "Plan", "in_progress"), ("2", "Build", "pending")])),
            // Compact rows without results: their arguments.
            todoRow("t2", input: #"{"todos":[{"id":"1","status":"completed"},{"id":"3","content":"Test","status":"pending"}],"merge":true}"#),
            todoRow("t3", input: #"{"todos":[{"id":"2","status":"in_progress"}],"merge":true}"#),
        ]
        let latest = AgentPlanTranscript.latest(in: messages)
        XCTAssertEqual(latest?.messageID, "t3")
        XCTAssertEqual(latest?.plan.items.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(latest?.plan.items.map(\.status), [.completed, .inProgress, .pending])
        XCTAssertEqual(latest?.plan.items[0].content, "Plan", "a merge keeps the text it didn't send")
    }

    func testTranscriptReplaceArgumentsAreAFullPlan() {
        let messages = [
            todoRow("t1", output: result([("1", "Old", "pending")])),
            todoRow("t2", input: #"{"todos":"[{\"id\":\"x\",\"content\":\"New\",\"status\":\"pending\"}]"}"#),
        ]
        XCTAssertEqual(AgentPlanTranscript.latest(in: messages)?.plan.items.map(\.content), ["New"])
        XCTAssertNil(AgentPlanTranscript.latest(in: [reply("r", "No plan here")]))
    }

    func testNewPlanIsOneThatKeepsFewerThanHalfOfTheItems() {
        let first = AgentPlan(snapshotJSON: result([("1", "A", "pending"), ("2", "B", "pending")]))!
        let update = AgentPlan(snapshotJSON: result([("1", "A", "completed"), ("2", "B", "in_progress"), ("3", "C", "pending")]))!
        let other = AgentPlan(snapshotJSON: result([("1", "X", "pending"), ("2", "Y", "pending")]))!
        XCTAssertTrue(first.isNewPlan(comparedTo: nil))
        XCTAssertFalse(update.isNewPlan(comparedTo: first))
        XCTAssertTrue(other.isNewPlan(comparedTo: first), "ids reused with new text are a new plan")
    }

    func testLongPlanShowsTheRowsAroundTheCurrentItem() {
        let items = (1...12).map { index -> (String, String, String) in
            ("\(index)", "Step \(index)", index < 6 ? "completed" : index == 6 ? "in_progress" : "pending")
        }
        let window = AgentPlanWindow(plan: AgentPlan(snapshotJSON: result(items))!)
        XCTAssertEqual(window.rows.map(\.id), ["5", "6", "7", "8", "9"])
        XCTAssertEqual(window.before, 4)
        XCTAssertTrue(window.beforeAreDone)
        XCTAssertEqual(window.after, 3)

        let finished = AgentPlanWindow(plan: AgentPlan(snapshotJSON: result(items.map { ($0.0, $0.1, "completed") }))!)
        XCTAssertEqual(finished.rows.map(\.id), ["8", "9", "10", "11", "12"])
        XCTAssertEqual(finished.after, 0)

        let short = AgentPlanWindow(plan: AgentPlan(snapshotJSON: result(Array(items.prefix(3))))!)
        XCTAssertEqual(short.rows.count, 3)
        XCTAssertEqual(short.before + short.after, 0)
    }

    func testResumeSnapshotCarriesTodoState() {
        let snapshot = SessionRuntimeSnapshot(object: [
            "todo_state": AnyCodable.from(["todos": [["id": "1", "content": "A", "status": "in_progress"]], "revision": 3]),
        ])
        XCTAssertEqual(snapshot.todoState?.items.first?.status, .inProgress)
        XCTAssertEqual(snapshot.todoState?.revision, 3)
        XCTAssertNil(SessionRuntimeSnapshot(object: [:]).todoState)
    }

    // MARK: - When the cards show

    func testOpeningAChatShowsAnUnfinishedPlanAndFoldsAFinishedOne() {
        let cards = ChatCardsModel(defaults: freshDefaults())
        cards.transcriptChanged([todoRow("t1", output: result([("1", "A", "completed"), ("2", "B", "pending")]))], for: cardsChat)
        XCTAssertNotNil(cards.plan)
        XCTAssertTrue(cards.planExpanded)

        let other = ChatCardsChat(profile: "default", ids: ["s2"])
        cards.transcriptChanged([todoRow("t9", output: result([("1", "A", "completed")]))], for: other)
        XCTAssertEqual(cards.plan?.isFinished, true)
        XCTAssertFalse(cards.planExpanded, "a finished plan opens folded")

        cards.transcriptChanged([reply("r", "hi")], for: ChatCardsChat(profile: "default", ids: ["s3"]))
        XCTAssertNil(cards.plan, "a chat without a plan has no card")
    }

    func testServerPlanStandsUntilTheTranscriptShowsOne() {
        let cards = ChatCardsModel(defaults: freshDefaults())
        let server = AgentPlan(snapshotJSON: result([("1", "From the server", "in_progress")]))
        cards.applyServerPlan(server, for: cardsChat)
        cards.transcriptChanged([reply("r", "Older page, no todo rows")], for: cardsChat)
        XCTAssertEqual(cards.plan?.items.first?.content, "From the server")
        cards.transcriptChanged([todoRow("t1", output: result([("1", "From the server", "completed")], revision: 2), at: nowStamp())],
                                for: cardsChat)
        XCTAssertEqual(cards.plan?.items.first?.status, .completed)
    }

    func testLivePlanPopsUpAndFoldsAfterItFinishes() async throws {
        let cards = ChatCardsModel(defaults: freshDefaults(), finishedPlanDelay: .milliseconds(50))
        cards.transcriptChanged([reply("r", "hi")], for: cardsChat)
        cards.transcriptChanged([reply("r", "hi"),
                                 todoRow("t1", output: result([("1", "A", "in_progress")]), at: nowStamp())], for: cardsChat)
        XCTAssertTrue(cards.planExpanded, "a new plan pops up")

        cards.setPlanExpanded(false)
        cards.transcriptChanged([reply("r", "hi"),
                                 todoRow("t1", output: result([("1", "A", "in_progress"), ("2", "B", "pending")]), at: nowStamp())],
                                for: cardsChat)
        XCTAssertFalse(cards.planExpanded, "an update leaves a plan the user folded folded")

        cards.setPlanExpanded(true)
        cards.transcriptChanged([reply("r", "hi"),
                                 todoRow("t2", output: result([("1", "A", "completed"), ("2", "B", "completed")]), at: nowStamp())],
                                for: cardsChat)
        XCTAssertTrue(cards.planExpanded, "a plan that just finished stays open a while")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(cards.planExpanded)
        XCTAssertNotNil(cards.plan, "it folds to its chip, not away")
    }

    func testPinnedPlanStaysOpenWhenFinished() async throws {
        let cards = ChatCardsModel(defaults: freshDefaults(), finishedPlanDelay: .milliseconds(30))
        cards.setPinsPlan(true)
        cards.transcriptChanged([todoRow("t1", output: result([("1", "A", "completed")]), at: Self.longAgo)], for: cardsChat)
        XCTAssertTrue(cards.planExpanded, "pinned: even a finished plan shows when the chat opens")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(cards.planExpanded)
        cards.setPlanExpanded(false)
        XCTAssertFalse(cards.pinsPlan, "folding a pinned card unpins it")
    }

    func testAnotherIDForTheSameChatKeepsItsCards() {
        let cards = ChatCardsModel(defaults: freshDefaults())
        cards.transcriptChanged([todoRow("t1", output: result([("1", "A", "pending")]))], for: cardsChat)
        cards.setPlanExpanded(false)
        let rotated = ChatCardsChat(profile: "default", ids: ["s1", "runtime-2"])
        cards.transcriptChanged([todoRow("t1", output: result([("1", "A", "pending")]))], for: rotated)
        XCTAssertFalse(cards.planExpanded, "the user's fold holds across a runtime id change")
    }
}
