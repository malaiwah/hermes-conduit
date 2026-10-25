import SwiftUI
import XCTest
@testable import Conduit

/// Throwaway (render-steps branch only): draws the folded and open step
/// group headers to PNGs for review.
@MainActor
final class StepGroupRenderTests: XCTestCase {
    private func step(_ index: Int, _ name: String) -> ChatMessage {
        ChatMessage(
            id: "row-\(index)", role: .tool, content: "", timestamp: "2026-10-25T07:41:\(String(format: "%02d", index * 3))Z",
            tool: ToolActivity(id: "call_render_\(index)_abcdef", name: name, input: nil, output: nil, status: .complete, duration: 2.5)
        )
    }

    private func members(_ names: [String]) -> [ChatStepGroupMember] {
        names.enumerated().map { ChatStepGroupMember(step($0.offset, $0.element)) }
    }

    func testRenderStepGroupHeaders() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_DIR"] else { throw XCTSkip("RENDER_DIR not set") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let five = members(["tool_describe", "crawl4ai_md", "crawl4ai_md", "memory", "memory"])
        let many = members(["terminal", "execute_code", "web_search", "session_search", "patch", "read_file", "browser_navigate",
                            "web_search", "crawl4ai_md", "terminal", "terminal", "memory", "patch", "web_search",
                            "read_file", "terminal", "execute_code", "memory", "session_search", "web_search", "patch", "terminal"])
        let fr = "Tu avais raison sur crawl4ai, alors j'ai voulu vérifier si son accès réseau différait de celui de SearXNG : j'ai d'abord interrogé sa fiche, puis testé la page Wikipédia refusée ailleurs, et enfin example.com, pour confirmer que le blocage visait seulement le serveur SearXNG."
        let en = "You were right about crawl4ai, so I wanted to see whether its network path differed from SearXNG's: I first read its tool card, then tried the Wikipedia page refused elsewhere, and finally example.com, to confirm the block was only on the SearXNG server."
        let cases: [(String, [ChatStepGroupMember], Bool, String?, Bool)] = [
            ("1-folded-fr", five, false, fr, false),
            ("2-open-fr", five, true, fr, false),
            ("3-folded-en", five, false, en, false),
            ("4-folded-22-steps", many, false, en, false),
            ("5-folded-no-summary", five, false, nil, false),
            ("6-looking-back", five, false, nil, true),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, group, expanded, summary, lookingBack) in cases {
                let view = ChatStepGroupHeader(
                    members: group, isLive: false, expanded: expanded,
                    summary: summary, lookingBack: lookingBack, explain: {}, toggle: {}
                )
                .chatStepCard(!expanded)
                .background { if expanded { RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)) } }
                .frame(width: 370)
                .padding(16)
                .background(Color(uiColor: .systemBackground))
                .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let data = try XCTUnwrap(renderer.uiImage?.pngData(), name)
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
