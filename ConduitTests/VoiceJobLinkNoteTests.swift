//
//  VoiceJobLinkNoteTests.swift
//  Conduit
//
//  A saved call's job and chat lines, read back to draw as cards. Written
//  as an extension of an existing Voice suite, like VoiceHistoryTests.
//

import XCTest
@testable import Conduit

extension HermesVoiceGatewayTimeoutTests {
    func testJobNoteReadsBackAsAJobCard() {
        let text = AppState.voiceJobStartedNote(title: "Find a dinner recipe", sessionID: "stored-1")
        XCTAssertEqual(
            VoiceJobLinkNote(text: text),
            VoiceJobLinkNote(kind: .job, title: "Find a dinner recipe", link: .session(id: "stored-1"))
        )
    }

    func testChatNoteReadsBackAsAChatCard() {
        let text = "Asked the chat: Book the table. " + ConduitAppLink.bot(profile: "chef").markdown(label: "Open chat")
        XCTAssertEqual(
            VoiceJobLinkNote(text: text),
            VoiceJobLinkNote(kind: .chat, title: "Book the table", link: .bot(profile: "chef"))
        )
    }

    func testJobNoteKeepsATitleWithBracketsAndColons() {
        let text = AppState.voiceJobStartedNote(title: "Fix [CI]: the build.", sessionID: "s1")
        XCTAssertEqual(VoiceJobLinkNote(text: text)?.title, "Fix [CI]: the build.")
    }

    func testLinesThatAreNotAJobNoteStayText() {
        // No link: a job on another profile, or no chat yet.
        XCTAssertNil(VoiceJobLinkNote(text: AppState.voiceJobStartedNote(title: "Late one", sessionID: nil)))
        // A reply that only happens to end in an app link.
        XCTAssertNil(VoiceJobLinkNote(text: "Here it is: [Open job](conduit://session/s1)"))
        XCTAssertNil(VoiceJobLinkNote(text: "Started a background job: x. [Read more](conduit://session/s1)"))
        // A Settings link is never a job.
        XCTAssertNil(VoiceJobLinkNote(text: "Started a background job: x. [Open job](conduit://settings/voice)"))
        // More than the one line.
        XCTAssertNil(VoiceJobLinkNote(text: "Done.\nStarted a background job: x. [Open job](conduit://session/s1)"))
        // Text after the link.
        XCTAssertNil(VoiceJobLinkNote(text: "Started a background job: x. [Open job](conduit://session/s1) and more"))
    }
}
