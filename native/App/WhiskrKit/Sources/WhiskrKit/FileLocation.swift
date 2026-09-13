import Foundation

/// "src/app.ts:12:4", "./README.md", "~/notes.txt:3", "file:///tmp/a.swift": a path a terminal printed
/// (⌘-click on it), with the line and column after it, made absolute against the folder the terminal
/// was in.
public struct FileLocation: Sendable, Equatable {
    public var path: String
    /// 1-based, as compilers and `grep -n` print them.
    public var line: Int?
    public var column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }

    /// nil for text that holds no path. `home` expands "~".
    public init?(_ text: String, folder: String, home: String = NSHomeDirectory()) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("file://"), let url = URL(string: text) { text = url.path }
        // Quotes and brackets some tools put round paths.
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]<>,;"))
        // "file.c:10:" as some compilers print it.
        while text.hasSuffix(":") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        var numbers: [Int] = []
        while numbers.count < 2, let colon = text.lastIndex(of: ":"), let number = Int(text[text.index(after: colon)...]) {
            numbers.insert(number, at: 0)
            text = String(text[..<colon])
        }
        guard !text.isEmpty else { return nil }
        if text == "~" || text.hasPrefix("~/") { text = home + text.dropFirst() }
        let absolute = text.hasPrefix("/") ? text : (folder as NSString).appendingPathComponent(text)
        path = URL(fileURLWithPath: absolute).standardizedFileURL.path
        line = numbers.first
        column = numbers.count > 1 ? numbers[1] : nil
    }
}
