import XCTest
@testable import Conduit

/// Read Aloud's follow-along estimate (#759): the reply split into
/// sentences, and how much of the audio has been heard.
final class ReadAloudFollowAlongTests: XCTestCase {
    // MARK: - Script

    func testParagraphsSplitIntoSentencesAndMarkdownIsTakenOut() {
        let script = ReadAloudScript.make(from: """
        # Plan

        First we **check** the [logs](https://example.com). Then we fix it.

        - Restart the `gateway`
        - Wait a minute
        """)

        XCTAssertEqual(script.segments.map(\.text), [
            "Plan",
            "First we check the logs.",
            "Then we fix it.",
            "Restart the gateway",
            "Wait a minute",
        ])
        XCTAssertEqual(script.segments.map(\.paragraph), [0, 1, 1, 2, 3])
        XCTAssertTrue(script.segments.allSatisfy { $0.kind == .sentence && $0.weight > 0 })
    }

    func testCodeBlocksAreShownButWeighNothing() {
        let script = ReadAloudScript.make(from: """
        Run this:
        ```swift
        print("hi")
        ```
        Done.
        """)

        XCTAssertEqual(script.segments.map(\.kind), [.sentence, .code, .sentence])
        XCTAssertEqual(script.segments[1].text, "print(\"hi\")")
        XCTAssertEqual(script.segments[1].weight, 0)
        XCTAssertEqual(script.segments.map(\.paragraph), [0, 1, 2])
    }

    func testNarratedActionsAndBareLinksWeighNothing() {
        XCTAssertEqual(ReadAloudScript.spokenWeight(of: "*sets down the gavel*"), 0)
        XCTAssertEqual(ReadAloudScript.spokenWeight(of: "https://example.com/a/b"), 0)
        XCTAssertGreaterThan(
            ReadAloudScript.spokenWeight(of: "It costs 2026 dollars"),
            ReadAloudScript.spokenWeight(of: "It costs abcd dollars"),
            "digits take longer to say than letters"
        )
    }

    func testCompleteAudioMapsItsShareOntoTheSentences() throws {
        let script = ReadAloudScript(segments: [
            .init(id: 0, text: "a", paragraph: 0, kind: .sentence, weight: 10),
            .init(id: 1, text: "code", paragraph: 1, kind: .code, weight: 0),
            .init(id: 2, text: "b", paragraph: 2, kind: .sentence, weight: 30),
        ])

        XCTAssertEqual(script.segmentIndex(playedSeconds: 0, receivedSeconds: 40, isComplete: true), 0)
        XCTAssertEqual(script.segmentIndex(playedSeconds: 9, receivedSeconds: 40, isComplete: true), 0)
        XCTAssertEqual(script.segmentIndex(playedSeconds: 10, receivedSeconds: 40, isComplete: true), 2, "code is skipped")
        XCTAssertEqual(script.segmentIndex(playedSeconds: 40, receivedSeconds: 40, isComplete: true), 2, "the end stays on the last sentence")
        XCTAssertEqual(script.segmentIndex(playedSeconds: 99, receivedSeconds: 40, isComplete: true), 2)
    }

    func testIncompleteAudioUsesATypicalPace() {
        let pace = ReadAloudScript.typicalWeightPerSecond
        let script = ReadAloudScript(segments: [
            .init(id: 0, text: "a", paragraph: 0, kind: .sentence, weight: pace * 2),
            .init(id: 1, text: "b", paragraph: 0, kind: .sentence, weight: pace * 2),
        ])

        // Only 4 s received of what will be much more: the share would say
        // the end, the pace says the second sentence.
        XCTAssertEqual(script.segmentIndex(playedSeconds: 1, receivedSeconds: 4, isComplete: false), 0)
        XCTAssertEqual(script.segmentIndex(playedSeconds: 3, receivedSeconds: 4, isComplete: false), 1)
    }

    func testNothingSpokenHasNoHighlight() {
        let script = ReadAloudScript.make(from: "```\ncode only\n```")
        XCTAssertNil(script.segmentIndex(playedSeconds: 1, receivedSeconds: 2, isComplete: true))
    }

    // MARK: - Playback progress

    func testProgressCountsPlayedBuffersAndInterpolatesTheHead() {
        let start = ContinuousClock.now
        var progress = SpeechPlaybackProgress()
        progress.scheduled(1, now: start)
        progress.scheduled(2, now: start)

        XCTAssertEqual(progress.receivedSeconds, 3, accuracy: 1e-9)
        XCTAssertEqual(progress.playedSeconds(now: start + .milliseconds(500)), 0.5, accuracy: 1e-6)
        XCTAssertEqual(progress.playedSeconds(now: start + .seconds(5)), 1, accuracy: 1e-6, "never past the head buffer")

        progress.bufferPlayed(now: start + .seconds(1))
        XCTAssertEqual(progress.playedSeconds(now: start + .milliseconds(1_500)), 1.5, accuracy: 1e-6)
    }

    func testProgressHoldsStillWhileStarvedAndPaused() {
        let start = ContinuousClock.now
        var progress = SpeechPlaybackProgress()
        progress.scheduled(1, now: start)
        progress.bufferPlayed(now: start + .seconds(1))
        // Waiting for the next chunk.
        XCTAssertEqual(progress.playedSeconds(now: start + .seconds(3)), 1, accuracy: 1e-6)

        progress.scheduled(2, now: start + .seconds(3))
        progress.pause(now: start + .seconds(4))
        XCTAssertEqual(progress.playedSeconds(now: start + .seconds(9)), 2, accuracy: 1e-6)
        progress.resume(now: start + .seconds(9))
        XCTAssertEqual(progress.playedSeconds(now: start + .milliseconds(9_500)), 2.5, accuracy: 1e-6)
    }

    func testProgressCountsSourceSecondsAtTheCurrentSpeed() {
        let start = ContinuousClock.now
        var progress = SpeechPlaybackProgress(rate: 2)
        progress.scheduled(10, now: start)
        XCTAssertEqual(progress.playedSeconds(now: start + .seconds(1)), 2, accuracy: 1e-6)

        progress.setRate(1, now: start + .seconds(1))
        XCTAssertEqual(progress.playedSeconds(now: start + .seconds(2)), 3, accuracy: 1e-6)
    }

    func testProgressIgnoresCompletionsWithNothingQueued() {
        var progress = SpeechPlaybackProgress()
        progress.bufferPlayed()
        XCTAssertEqual(progress.playedSeconds(), 0)
        progress.reset()
        XCTAssertEqual(progress.receivedSeconds, 0)
    }

    func testClosestSpeedForAnArbitraryRate() {
        XCTAssertEqual(ReadAloudSpeed.closest(to: 1.3), .fast)
        XCTAssertEqual(ReadAloudSpeed.closest(to: 9), .double)
        XCTAssertEqual(ReadAloudSpeed.closest(to: 1), .normal)
    }
}
