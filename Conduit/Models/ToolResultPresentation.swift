//
//  ToolResultPresentation.swift
//  Conduit
//
//  What an opened tool row shows first: the part of a bundled Hermes
//  tool's result a person reads (a command's output, a plan, a diff, the
//  pages a search found, the file it made), read from the stored result
//  itself so a reloaded chat shows the same as a live one. The raw result
//  stays below it, pretty-printed.
//

import Foundation

struct ToolResultPresentation: Equatable {
    struct TodoItem: Equatable, Identifiable {
        enum Status: String, Equatable {
            case pending
            case inProgress = "in_progress"
            case completed
            case cancelled
        }

        var id: String
        var content: String
        var status: Status
        /// How deep it sits under its parent tasks (0 for a top-level one).
        var depth: Int = 0
    }

    struct Link: Equatable, Identifiable {
        var title: String
        /// Empty for an item Hermes couldn't read at all (no usable URL).
        var url: String
        var snippet: String?
        /// The page couldn't be read: what Hermes said instead.
        var error: String?
        var id: String { url.isEmpty ? "error:\(title):\(error ?? "")" : url }
        /// Only an http(s) page is opened from the row.
        var opensPage: Bool { ToolResultPresentation.isWebURL(url) }
    }

    enum Body: Equatable {
        /// A todo list: the whole plan as the tool last left it.
        case todos([TodoItem])
        /// A unified diff of the change the call made.
        case diff(String)
        /// Plain text the tool produced (a command's output, a file's
        /// contents, an image description).
        case text(String)
        /// Web pages: what a search or extract returned, or a file a tool
        /// made that lives on the web (opened, never fetched by the row).
        case links([Link])
        /// A file a tool made on the Hermes host (a picture, audio, a
        /// screenshot), drawn by the chat's own media rendering.
        case media([String])
    }

    /// Nil when the result has only a status worth showing (an exit code,
    /// an error, a notice).
    var body: Body?
    /// A failed call's own words.
    var error: String?
    /// A command's exit status, when it isn't 0.
    var exitCode: Int?
    /// Hermes' note that it fell back to another backend.
    var notice: String?

    /// Above this size the result is shown raw: parsing and reformatting a
    /// very large result on the main thread would stall scrolling.
    static let parseLimit = 65_536

    /// Bundled tools by every name Hermes has registered them under (the
    /// current name first, then the legacy alias).
    private static let todoTools: Set<String> = ["todo_list", "todo"]
    private static let commandTools: Set<String> = ["terminal", "process_manage", "process", "execute_code"]

    /// The readable part of `output` for the `toolName` call, or nil when
    /// Conduit has nothing to add to the raw result: the tool isn't one it
    /// knows, or the result isn't the shape Hermes writes.
    static func make(toolName: String, output: String?) -> ToolResultPresentation? {
        guard let object = jsonObject(output) else { return nil }
        let name = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let error = text(object["error"])
        let notice = text(object["fallback_warning"])
        var exitCode: Int?
        if let code = (object["exit_code"] as? NSNumber)?.intValue, code != 0 { exitCode = code }

        let body: Body?
        switch name {
        case _ where todoTools.contains(name):
            body = todos(object["todos"]).map(Body.todos)
        case "patch":
            body = text(object["diff"]).map(Body.diff)
        case _ where commandTools.contains(name):
            // process_manage's poll answers with a preview of the output.
            body = (text(object["output"]) ?? text(object["output_preview"])).map(Body.text)
        case "read_file":
            body = text(object["content"]).map(Body.text)
        case "web_search":
            let data = object["data"] as? [String: Any]
            body = links(data?["web"], snippetKey: "description").map(Body.links)
        case "web_extract":
            let data = object["data"] as? [String: Any]
            body = (links(object["results"], snippetKey: nil) ?? links(data?["results"], snippetKey: nil)).map(Body.links)
        case "vision_analyze":
            body = text(object["analysis"]).map(Body.text)
        case "image_generate":
            body = file(object["image"])
        case "text_to_speech":
            // A long reading comes back in parts: `file_path` is the first.
            body = files(object["file_paths"]) ?? file(object["file_path"])
        case _ where name.hasPrefix("browser_"):
            body = file(object["screenshot_path"]) ?? text(object["analysis"]).map(Body.text)
        default:
            body = nil
        }

        guard body != nil || error != nil || exitCode != nil || notice != nil else { return nil }
        return ToolResultPresentation(body: body, error: error, exitCode: exitCode, notice: notice)
    }

    /// `text` reformatted with sorted keys and indentation when it is a JSON
    /// object or array under `parseLimit`; nil for anything else, which is
    /// shown as it came.
    static func prettyJSON(_ text: String?) -> String? {
        guard let text, text.utf8.count <= parseLimit else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let data = trimmed.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(value),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    /// A host file as a `MEDIA:` tag, so the chat's own media rendering
    /// draws it (inline pictures and audio, a file card for the rest).
    static func mediaTag(for path: String) -> String {
        "MEDIA:`\(path)`"
    }

    /// An http(s) URL with a host, the only links a tool row opens.
    static func isWebURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host?.isEmpty == false else { return false }
        return true
    }

    // MARK: - Reading

    private static func jsonObject(_ text: String?) -> [String: Any]? {
        guard let text, text.utf8.count <= parseLimit,
              let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string.trimmingCharacters(in: .newlines)
    }

    /// A file a tool made: an absolute path on the Hermes host (POSIX,
    /// `~/` or a Windows drive, as `MEDIA:` tags take them) is drawn; a web
    /// URL is offered as a link. Nil for anything else (a data URL, a
    /// relative path).
    private static func file(_ value: Any?) -> Body? {
        guard let reference = text(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.contains("\n"), !reference.contains("`") else { return nil }
        if isWebURL(reference) {
            return .links([Link(title: reference, url: reference)])
        }
        let isWindowsPath = reference.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
        if reference.hasPrefix("/") || reference.hasPrefix("~/") || isWindowsPath {
            return .media([reference])
        }
        return nil
    }

    /// Every part in `file_paths`, when each is a file the row can show.
    private static func files(_ value: Any?) -> Body? {
        guard let paths = value as? [Any], !paths.isEmpty else { return nil }
        var media: [String] = []
        for path in paths {
            guard case .media(let parts)? = file(path) else { return nil }
            media += parts
        }
        return .media(media)
    }

    private static func todos(_ value: Any?) -> [TodoItem]? {
        guard let rows = value as? [[String: Any]] else { return nil }
        var parents: [String: String] = [:]
        var items = rows.enumerated().compactMap { index, row -> TodoItem? in
            guard let content = text(row["content"]) else { return nil }
            let status = (row["status"] as? String).flatMap { TodoItem.Status(rawValue: $0.lowercased()) } ?? .pending
            let id = text(row["id"]) ?? "todo-\(index)"
            if let parent = text(row["parent"]) { parents[id] = parent }
            return TodoItem(id: id, content: content, status: status)
        }
        // A subtask is indented under its parent. A parent that isn't in
        // the list, or a loop, stops the count where it breaks.
        let known = Set(items.map(\.id))
        for index in items.indices {
            var seen: Set<String> = [items[index].id]
            var depth = 0
            var current = items[index].id
            while let parent = parents[current], known.contains(parent), seen.insert(parent).inserted {
                depth += 1
                current = parent
            }
            items[index].depth = depth
        }
        return items.isEmpty ? nil : items
    }

    private static func links(_ value: Any?, snippetKey: String?) -> [Link]? {
        guard let rows = value as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        let items = rows.compactMap { row -> Link? in
            let error = text(row["error"])
            let url = text(row["url"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if isWebURL(url) {
                guard seen.insert(url).inserted else { return nil }
                let snippet = snippetKey.flatMap { text(row[$0]) }
                return Link(title: text(row["title"]) ?? url, url: url, snippet: snippet, error: error)
            }
            // An item Hermes couldn't read still says why, without a link.
            guard let error else { return nil }
            return Link(title: url.isEmpty ? (text(row["title"]) ?? "") : url, url: "", snippet: nil, error: error)
        }
        return items.isEmpty ? nil : items
    }
}
