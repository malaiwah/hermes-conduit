//
//  PreviewTextTests.swift
//  ConduitTests
//

import XCTest
@testable import Conduit

final class PreviewTextTests: XCTestCase {
    func testInlineMarksDrop() {
        XCTAssertEqual(PreviewText.plain("Pfeiffer has **two sites** and `#112` [booked](https://x.y)"),
                       "Pfeiffer has two sites and #112 booked")
    }

    func testBlockMarksDropAndLinesJoin() {
        let text = "Three quick ones:\n\n- **Mon** Lemon chicken\n2. Quesadillas\n## Food\n> Pack water"
        XCTAssertEqual(PreviewText.plain(text), "Three quick ones: Mon Lemon chicken Quesadillas Food Pack water")
    }

    func testCodeFenceLinesDrop() {
        XCTAssertEqual(PreviewText.plain("Found it:\n```python\nassert done.wait(1)\n```"),
                       "Found it: assert done.wait(1)")
    }

    func testPreviewCutMidSpanLosesItsMark() {
        XCTAssertEqual(PreviewText.plain("Good news: **two sites left for Sat"), "Good news: two sites left for Sat")
    }

    func testPlainTextStaysAsIs() {
        XCTAssertEqual(PreviewText.plain("Make me a watering schedule, 5 * 3 = 15"), "Make me a watering schedule, 5 * 3 = 15")
        XCTAssertEqual(PreviewText.plain("#hashtag and -dash"), "#hashtag and -dash")
        XCTAssertEqual(PreviewText.plain("Python power: 5 ** 3"), "Python power: 5 ** 3")
    }

    func testNestedQuotesDrop() {
        XCTAssertEqual(PreviewText.plain(">> Pack water"), "Pack water")
    }
}
