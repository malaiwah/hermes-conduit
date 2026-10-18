import XCTest
@testable import Conduit

/// Archiving or deleting the open chat leaves an empty canvas with a live
/// composer. A message sent there starts a new chat and goes into it; it
/// used to be dropped without a word.
@MainActor
final class ArchiveThenSendTests: XCTestCase {
    func testAMessageSentAfterArchivingTheOpenChatStartsANewChat() async {
        var prompts: [(sessionID: String, text: String)] = []
        let appState = makeConnectedAppState { sessionID, text in prompts.append((sessionID, text)) }
        let session = makeSession(profile: appState.activeProfile)
        appState.sessions = [session]
        appState.activeSessionId = session.id

        let archived = await appState.archiveSession(session)

        XCTAssertTrue(archived)
        XCTAssertNil(appState.activeSessionId)
        XCTAssertEqual(appState.composerChatOnScreen, .none)
        XCTAssertEqual(appState.composerAction(hasText: true, hasAttachments: false), .send)

        let sent = await appState.submitComposer(text: "hi")

        XCTAssertTrue(sent, "The message goes into a new chat")
        XCTAssertEqual(appState.activeSessionId, "created-runtime")
        XCTAssertEqual(prompts.map(\.sessionID), ["created-runtime"])
        XCTAssertEqual(prompts.map(\.text), ["hi"])
        XCTAssertTrue(appState.messages.contains { $0.role == .user && $0.content == "hi" })
        XCTAssertNil(appState.errorMessage)
    }

    func testASlashCommandOnTheEmptyCanvasStartsNoChat() async {
        var created = 0
        let appState = makeConnectedAppState { _, _ in }
        appState.widgetSessionCreatorOverride = { _, _ in
            created += 1
            return ("created-runtime", "created-stored", "default")
        }
        XCTAssertNil(appState.activeSessionId)

        _ = await appState.submitComposer(text: "/help")

        XCTAssertEqual(created, 0, "A slash command runs as before, without a chat")
    }

    func testAMessageThatCantStartAChatSaysWhyAndIsKept() async {
        struct CreateRefused: Error {}
        var prompts = 0
        let appState = makeConnectedAppState { _, _ in prompts += 1 }
        appState.widgetSessionCreatorOverride = { _, _ in throw CreateRefused() }
        XCTAssertNil(appState.activeSessionId)

        let sent = await appState.submitComposer(text: "hi")

        // False: the composer puts the text back (ComposerBar).
        XCTAssertFalse(sent)
        XCTAssertNil(appState.activeSessionId)
        XCTAssertEqual(prompts, 0)
        XCTAssertNotNil(appState.errorMessage, "A send that goes nowhere says why")
    }

    // MARK: Helpers

    private func makeConnectedAppState(
        onPrompt: @escaping @MainActor (String, String) -> Void
    ) -> AppState {
        let suite = "ArchiveThenSendTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, sessionID, text in
                    onPrompt(sessionID, text)
                    return .accepted
                }
            ),
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        appState.widgetSessionMutationRequestOverride = { _, method, _ in
            method == "GET" ? ["runtime_revision": 3, "runtime_generation": 1] : ["ok": true]
        }
        appState.widgetSessionCreatorOverride = { _, _ in ("created-runtime", "created-stored", "default") }
        return appState
    }

    private func makeSession(profile: String?) -> SessionSummary {
        SessionSummary(
            id: "stored-id",
            alternateIds: ["runtime-id"],
            title: "Original",
            model: "test-model",
            updatedLabel: "now",
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false
        )
    }
}
