//
//  ToolResultPresentationTests.swift
//  Conduit
//
//  An opened tool row leads with the readable part of a bundled Hermes
//  tool's result, read from the stored result, and shows the raw result
//  pretty-printed.
//

import XCTest
@testable import Conduit

final class ToolResultPresentationTests: XCTestCase {

    func testATodoResultReadsAsTheWholePlan() throws {
        let output = #"{"todos": [{"id": "1", "content": "Read the logs", "status": "completed"}, {"id": "2", "content": "Fix the parser", "status": "in_progress"}, {"id": "3", "content": "Ship", "status": "pending"}], "summary": {"total": 3}}"#
        // Hermes' current name and its legacy alias.
        for name in ["todo_list", "todo"] {
            let presentation = try XCTUnwrap(ToolResultPresentation.make(toolName: name, output: output))
            guard case .todos(let items)? = presentation.body else { return XCTFail("expected a plan from \(name)") }
            XCTAssertEqual(items.map(\.content), ["Read the logs", "Fix the parser", "Ship"])
            XCTAssertEqual(items.map(\.status), [.completed, .inProgress, .pending])
        }
    }

    func testSubtasksAreIndentedUnderTheirParent() throws {
        let output = #"{"todos": [{"id": "a", "content": "Ship", "status": "in_progress"}, {"id": "b", "content": "Tests", "status": "pending", "parent": "a"}, {"id": "c", "content": "Flaky one", "status": "pending", "parent": "b"}, {"id": "d", "content": "Orphan", "status": "pending", "parent": "gone"}, {"id": "e", "content": "Loop", "status": "pending", "parent": "f"}, {"id": "f", "content": "Loop back", "status": "pending", "parent": "e"}]}"#
        let presentation = try XCTUnwrap(ToolResultPresentation.make(toolName: "todo_list", output: output))
        guard case .todos(let items)? = presentation.body else { return XCTFail("expected a plan") }
        XCTAssertEqual(items.map(\.depth), [0, 1, 2, 0, 1, 1], "an unknown parent or a loop stops the count")
    }

    func testAPatchResultReadsAsItsDiff() throws {
        let diff = "--- a/app.py\n+++ b/app.py\n@@ -1 +1 @@\n-print('hi')\n+print('hello')"
        let output = try json(["success": true, "diff": diff, "files_modified": ["app.py"]])
        let presentation = try XCTUnwrap(ToolResultPresentation.make(toolName: "patch", output: output))
        XCTAssertEqual(presentation.body, .diff(diff))
    }

    func testACommandLeadsWithItsOutputAndAFailedExitCode() throws {
        let output = #"{"output": "make: *** [test] Error 2\n", "exit_code": 2, "error": null}"#
        let presentation = try XCTUnwrap(ToolResultPresentation.make(toolName: "terminal", output: output))
        XCTAssertEqual(presentation.body, .text("make: *** [test] Error 2"))
        XCTAssertEqual(presentation.exitCode, 2)
        XCTAssertNil(presentation.error)

        let clean = try XCTUnwrap(ToolResultPresentation.make(toolName: "process_manage", output: #"{"output": "ok", "exit_code": 0}"#))
        XCTAssertNil(clean.exitCode, "a 0 exit code isn't worth a line")

        // process_manage's poll previews the output.
        let poll = try XCTUnwrap(ToolResultPresentation.make(toolName: "process_manage", output: #"{"session_id": "p1", "status": "running", "uptime_seconds": 4, "output_preview": "compiling 3/9"}"#))
        XCTAssertEqual(poll.body, .text("compiling 3/9"))

        // A failure with nothing printed still says how it ended.
        let silent = try XCTUnwrap(ToolResultPresentation.make(toolName: "terminal", output: #"{"output": "", "exit_code": 1}"#))
        XCTAssertNil(silent.body)
        XCTAssertEqual(silent.exitCode, 1)
        let warned = try XCTUnwrap(ToolResultPresentation.make(toolName: "web_search", output: #"{"success": true, "fallback_warning": "Used the backup search backend"}"#))
        XCTAssertEqual(warned.notice, "Used the backup search backend")
    }

    func testWebResultsReadAsLinks() throws {
        let search = #"{"success": true, "data": {"web": [{"title": "Swift", "url": "https://swift.org", "description": "The language", "position": 1}, {"title": "", "url": "https://example.com"}, {"title": "Again", "url": "https://swift.org"}]}}"#
        let presentation = try XCTUnwrap(ToolResultPresentation.make(toolName: "web_search", output: search))
        XCTAssertEqual(presentation.body, .links([
            .init(title: "Swift", url: "https://swift.org", snippet: "The language"),
            .init(title: "https://example.com", url: "https://example.com", snippet: nil)
        ]))

        let extract = #"{"results": [{"url": "https://swift.org/blog", "title": "Blog", "content": "long page text"}, {"url": "https://down.example", "title": "", "content": "", "error": "Extract backend returned no result for this URL"}, {"url": "file:///etc/passwd", "title": "Local"}, {"url": "tel:123", "title": "Call"}, {"url": "", "title": "", "content": "", "error": "Invalid URL: not a string"}]}"#
        let extracted = try XCTUnwrap(ToolResultPresentation.make(toolName: "web_extract", output: extract))
        XCTAssertEqual(extracted.body, .links([
            .init(title: "Blog", url: "https://swift.org/blog", snippet: nil),
            .init(title: "https://down.example", url: "https://down.example", snippet: nil,
                  error: "Extract backend returned no result for this URL"),
            .init(title: "", url: "", snippet: nil, error: "Invalid URL: not a string")
        ]), "a page that failed says so, and only web links are offered")
        if case .links(let links)? = extracted.body {
            XCTAssertEqual(links.map(\.opensPage), [true, true, false])
        }
    }

    func testAFileAToolMadeIsDrawnFromTheHostOrOfferedAsALink() throws {
        let audio = try XCTUnwrap(ToolResultPresentation.make(
            toolName: "text_to_speech", output: #"{"success": true, "file_path": "/home/me/.hermes/audio/reply.mp3"}"#))
        XCTAssertEqual(audio.body, .media(["/home/me/.hermes/audio/reply.mp3"]))
        let parts = try XCTUnwrap(ToolResultPresentation.make(
            toolName: "text_to_speech", output: #"{"success": true, "file_path": "/a/1.mp3", "file_paths": ["/a/1.mp3", "/a/2.mp3"]}"#))
        XCTAssertEqual(parts.body, .media(["/a/1.mp3", "/a/2.mp3"]), "a long reading shows every part")
        let windows = try XCTUnwrap(ToolResultPresentation.make(
            toolName: "browser_vision", output: #"{"success": true, "screenshot_path": "C:\\Users\\me\\shot.png"}"#))
        XCTAssertEqual(windows.body, .media(["C:\\Users\\me\\shot.png"]))
        // A file on the web is a link to open, never fetched by the row.
        let image = try XCTUnwrap(ToolResultPresentation.make(
            toolName: "image_generate", output: #"{"success": true, "image": "https://cdn.example.com/cat.png"}"#))
        XCTAssertEqual(image.body, .links([.init(title: "https://cdn.example.com/cat.png", url: "https://cdn.example.com/cat.png")]))
        // A data URL or a relative path isn't something the chat can show.
        XCTAssertNil(ToolResultPresentation.make(toolName: "image_generate", output: #"{"image": "data:image/png;base64,AAAA"}"#))
        XCTAssertNil(ToolResultPresentation.make(toolName: "text_to_speech", output: #"{"file_path": "audio/reply.mp3"}"#))

        XCTAssertEqual(ToolResultPresentation.mediaTag(for: "/tmp/My Shots/a.png"), "MEDIA:`/tmp/My Shots/a.png`")
    }

    func testAFailedCallOfAnyToolLeadsWithItsError() throws {
        let failed = try XCTUnwrap(ToolResultPresentation.make(
            toolName: "some_mcp_tool", output: #"{"success": false, "error": "Permission denied"}"#))
        XCTAssertNil(failed.body)
        XCTAssertEqual(failed.error, "Permission denied")

        let readFailed = try XCTUnwrap(ToolResultPresentation.make(
            toolName: "read_file", output: #"{"content": "partial", "error": "File was truncated"}"#))
        XCTAssertEqual(readFailed.body, .text("partial"))
        XCTAssertEqual(readFailed.error, "File was truncated")
        // write_file's result carries no diff: its row stays as it was.
        XCTAssertNil(ToolResultPresentation.make(toolName: "write_file", output: #"{"bytes_written": 12}"#))
    }

    func testResultsConduitCantReadKeepTheRawRow() {
        // Not JSON, an unknown tool's success, the wrong shape, too large.
        XCTAssertNil(ToolResultPresentation.make(toolName: "terminal", output: "plain text"))
        XCTAssertNil(ToolResultPresentation.make(toolName: "memory", output: #"{"success": true}"#))
        XCTAssertNil(ToolResultPresentation.make(toolName: "todo", output: #"{"todos": "none"}"#))
        let huge = #"{"output": ""# + String(repeating: "x", count: ToolResultPresentation.parseLimit) + #""}"#
        XCTAssertNil(ToolResultPresentation.make(toolName: "terminal", output: huge))
        XCTAssertNil(ToolResultPresentation.make(toolName: "terminal", output: nil))
    }

    func testRawJSONIsPrettyPrintedWithSortedKeysAndPlainSlashes() {
        XCTAssertEqual(
            ToolResultPresentation.prettyJSON(#"{"url":"https://a.b/c","a":[1,2]}"#),
            "{\n  \"a\" : [\n    1,\n    2\n  ],\n  \"url\" : \"https://a.b/c\"\n}"
        )
        // Anything that isn't a JSON object or array is shown as it came.
        XCTAssertNil(ToolResultPresentation.prettyJSON("Searching the web for swift"))
        XCTAssertNil(ToolResultPresentation.prettyJSON("42"))
        XCTAssertNil(ToolResultPresentation.prettyJSON(#"{"truncated": "#))
        let huge = "[" + String(repeating: "1,", count: ToolResultPresentation.parseLimit) + "1]"
        XCTAssertNil(ToolResultPresentation.prettyJSON(huge), "a very large result isn't reformatted")
    }

    func testADiffIsColoredByLine() {
        let colored = ToolResultBodyView.coloredDiff("@@ -1 +1 @@\n-old\n+new\n same", font: .systemFont(ofSize: 12))
        XCTAssertEqual(colored.string, "@@ -1 +1 @@\n-old\n+new\n same")
        func color(at text: String) -> UIColor? {
            let range = (colored.string as NSString).range(of: text)
            return colored.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
        }
        XCTAssertEqual(color(at: "-old"), .systemRed)
        XCTAssertEqual(color(at: "+new"), .systemGreen)
        XCTAssertEqual(color(at: "@@"), .tertiaryLabel)
        XCTAssertEqual(color(at: " same"), .secondaryLabel)
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
