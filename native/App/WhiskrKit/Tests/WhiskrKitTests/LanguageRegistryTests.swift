import Foundation
import Testing
@testable import WhiskrKit

/// The bundled language data and the registry over it: what VS Code would call each file, fences,
/// configurations, grammars and their licences, and languages a person adds.
@Suite("Languages")
struct LanguageRegistryTests {
    let registry = LanguageRegistry(folder: LanguageRegistry.bundledFolder)

    // MARK: Detection

    @Test("every file name and extension a bundled language claims is detected as that language")
    func everyClaimDetects() throws {
        let index = try Self.bundledIndex()
        var checked = 0
        for language in index.languages {
            for name in language.filenames ?? [] {
                #expect(registry.detect(fileName: name).id == language.id, "\(name)")
                checked += 1
            }
            for suffix in language.extensions ?? [] {
                #expect(registry.detect(fileName: "name" + suffix).id == language.id, "\(suffix)")
                checked += 1
            }
        }
        #expect(checked > 300)
    }

    @Test("file names, patterns and extensions resolve as in VS Code", arguments: [
        ("Dockerfile", "dockerfile"), ("dockerfile", "dockerfile"), ("Dockerfile.dev", "dockerfile"), ("app.dockerfile", "dockerfile"),
        ("Containerfile", "dockerfile"), ("Makefile", "makefile"), ("GNUmakefile", "makefile"), ("rules.mk", "makefile"),
        ("Gemfile", "ruby"), ("Podfile", "ruby"), ("Rakefile", "ruby"), ("Fastfile", "ruby"), ("x.gemspec", "ruby"),
        (".zshrc", "shellscript"), ("zshrc", "shellscript"), (".bashrc", "shellscript"), ("PKGBUILD", "shellscript"), ("x.sh", "shellscript"),
        (".env", "dotenv"), (".env.local", "dotenv"), ("x.env", "dotenv"),
        ("tsconfig.json", "jsonc"), ("tsconfig.app.json", "jsonc"), ("jsconfig.json", "jsonc"), ("settings.json", "jsonc"),
        (".eslintrc.json", "jsonc"), ("x.code-workspace", "jsonc"), ("package.json", "json"), ("x.json", "json"), ("x.jsonl", "jsonl"),
        ("x.ts", "typescript"), ("x.d.ts", "typescript"), ("x.mts", "typescript"), ("x.tsx", "typescriptreact"),
        ("x.js", "javascript"), ("x.mjs", "javascript"), ("x.jsx", "javascriptreact"),
        ("x.h", "cpp"), ("x.c", "c"), ("x.hpp", "cpp"), ("x.cc", "cpp"), ("x.m", "objective-c"), ("x.mm", "objective-cpp"),
        ("x.swift", "swift"), ("Package.SWIFT", "swift"), ("x.py", "python"), ("x.pyi", "python"), ("SConstruct", "python"),
        ("x.rs", "rust"), ("x.go", "go"), ("x.java", "java"), ("x.kt", "kotlin"), ("x.kts", "kotlin"), ("x.cs", "csharp"),
        ("x.php", "php"), ("x.html", "html"), ("x.css", "css"), ("x.scss", "scss"), ("x.less", "less"),
        ("x.yml", "yaml"), ("x.yaml", "yaml"), ("compose.yml", "dockercompose"), ("docker-compose.yaml", "dockercompose"),
        ("x.toml", "toml"), ("Cargo.lock", "toml"), ("x.md", "markdown"), ("x.sql", "sql"), ("x.xml", "xml"), ("x.svg", "xml"),
        ("x.xsl", "xsl"), ("x.lua", "lua"), ("x.dart", "dart"), ("x.zig", "zig"), ("x.graphql", "graphql"), ("x.gql", "graphql"),
        ("x.diff", "diff"), ("x.patch", "diff"), ("x.ini", "ini"), ("x.properties", "properties"), (".gitconfig", "properties"),
        (".editorconfig", "properties"), ("x.log", "log"), (".gitignore", "ignore"), (".npmignore", "ignore"),
        ("COMMIT_EDITMSG", "git-commit"), ("MERGE_MSG", "git-commit"), ("git-rebase-todo", "git-rebase"),
        ("/repo/.git/config", "properties"), ("/home/a/.config/git/config", "properties"), ("/repo/.git/rebase-merge/done", "git-rebase"),
        ("/repo/.cursor/rules/style.mdc", "markdown"), ("/repo/.github/hooks/pre.json", "jsonc"), ("config", "plaintext"),
        ("x.txt", "plaintext"), ("README", "plaintext"), ("LICENSE", "plaintext"), ("x.unknown", "plaintext"), ("", "plaintext"),
    ])
    func detection(name: String, id: String) {
        #expect(registry.detect(fileName: name).id == id)
    }

    @Test("a first line decides only when the name does not", arguments: [
        ("script", "#!/usr/bin/env python3", "python"), ("script", "#!/bin/bash", "shellscript"), ("script", "#!/usr/bin/env zsh", "shellscript"),
        ("script", "#!/usr/bin/env node", "javascript"), ("script", "#!/usr/bin/env -S deno run", "typescript"),
        ("script", "#!/usr/bin/env ruby", "ruby"), ("script", "#!/usr/bin/php", "php"), ("script", "#!/usr/bin/make -f", "makefile"),
        ("data", "<?xml version=\"1.0\"?>", "xml"), ("cloud", "#cloud-config", "yaml"), ("script", "\u{FEFF}#!/bin/sh", "shellscript"),
        ("script", "#!/bin/sh\necho", "shellscript"), ("x.py", "#!/bin/bash", "python"), ("notes", "hello", "plaintext"), ("notes", "", "plaintext"),
    ])
    func firstLine(name: String, line: String, id: String) {
        #expect(registry.detect(fileName: name, firstLine: line).id == id)
    }

    // MARK: Fences

    @Test("a Markdown fence names its language as VS Code's Markdown grammar does", arguments: [
        ("ts", "typescript"), ("TypeScript", "typescript"), ("tsx", "typescriptreact"), ("js", "javascript"), ("jsx", "javascript"),
        ("py", "python"), ("python {.numberLines}", "python"), ("rust title=main.rs", "rust"), ("rs", "rust"), ("sh", "shellscript"),
        ("bash", "shellscript"), ("zsh", "shellscript"), ("console", "shellscript"), ("shell", "shellscript"), ("objc", "objective-c"),
        ("objective-c", "objective-c"), ("c++", "cpp"), ("cpp", "cpp"), ("h", "c"), ("c#", "csharp"), ("cs", "csharp"), ("go", "go"),
        ("golang", "go"), ("swift", "swift"), ("kotlin", "kotlin"), ("kt", "kotlin"), ("toml", "toml"), ("zig", "zig"), ("graphql", "graphql"),
        ("gql", "graphql"), ("Dockerfile", "dockerfile"), ("docker", "dockerfile"), ("yml", "yaml"), ("json5", "json"), ("jsonc", "jsonc"),
        ("html", "html"), ("xml", "xml"), ("diff", "diff"), ("patch", "diff"), ("md", "markdown"), ("ini", "ini"), ("sql", "sql"),
        ("Makefile", "makefile"), ("text", "plaintext"), ("txt", "plaintext"), ("gitignore", "ignore"),
    ])
    func fence(info: String, id: String) {
        #expect(registry.language(forFence: info)?.id == id)
    }

    @Test("a fence of no known language names none")
    func unknownFence() {
        #expect(registry.language(forFence: "") == nil)
        #expect(registry.language(forFence: "   ") == nil)
        #expect(registry.language(forFence: "{.python}") == nil)
        #expect(registry.language(forFence: "brainfrog") == nil)
        // A language VS Code's Markdown grammar knows but Whiskr does not bundle.
        #expect(registry.language(forFence: "perl") == nil)
    }

    // MARK: Languages

    @Test("languages carry VS Code's names, aliases and grammars")
    func names() throws {
        let typescriptReact = try #require(registry.language(id: "typescriptreact"))
        #expect(typescriptReact.displayName == "TypeScript JSX")
        #expect(typescriptReact.scopeName == "source.tsx")
        #expect(typescriptReact.aliases.contains("tsx"))
        #expect(registry.language(id: "javascriptreact")?.scopeName == "source.js.jsx")
        #expect(registry.language(id: "shellscript")?.displayName == "Shell Script")
        #expect(registry.language(id: "cpp")?.scopeName == "source.cpp")
        #expect(registry.language(id: "php")?.scopeName == "text.html.php")
        #expect(registry.language(id: "html")?.scopeName == "text.html.derivative")
        #expect(registry.language(id: "properties")?.scopeName == "source.ini")
        #expect(registry.language(id: "dockercompose")?.scopeName == "source.yaml")
        #expect(registry.language(id: "ignore")?.displayName == "Ignore")
        #expect(registry.language(id: "jsonc")?.displayName == "JSON with Comments")
        #expect(registry.language(id: "kotlin")?.scopeName == "source.kotlin")
        let plain = try #require(registry.language(id: "plaintext"))
        #expect(plain.isPlainText && plain.displayName == "Plain Text" && plain.scopeName == nil)
        #expect(registry.language(id: "no-such-language") == nil)
        #expect(CodeLanguage.markdown.scopeName == "text.html.markdown")
        #expect(CodeLanguage.plainText.isPlainText)
        #expect(CodeLanguage.gitCommit.scopeName == "text.git-commit")
    }

    @Test("the language menu lists named languages by name")
    func menu() {
        let all = registry.all
        let names = all.map(\.displayName)
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        #expect(all.contains { $0.id == "swift" } && all.contains { $0.isPlainText })
        // "jsx-tags" is contributed with no aliases: VS Code gives it no name and no place in menus.
        #expect(!all.contains { $0.id == "jsx-tags" })
        #expect(registry.language(id: "jsx-tags") != nil)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.count >= 45)
    }

    // MARK: Configurations

    @Test("a configuration takes VS Code's defaults for what it leaves out")
    func configurationDefaults() throws {
        let only = try LanguageConfiguration(data: Data(#"""
            { "brackets": [["{", "}"], ["(", ")"], ["bad"]], // a comment
              "comments": { "lineComment": { "comment": "--", "noIndent": true } }, }
            """#.utf8))
        #expect(only.lineComment == "--")
        #expect(only.brackets == [EditingPairs.Pair("{", "}"), EditingPairs.Pair("(", ")")])
        #expect(only.autoClosingPairs == [EditingPairs.AutoClosingPair("{", "}"), EditingPairs.AutoClosingPair("(", ")")])
        #expect(only.surroundingPairs == only.brackets)
        #expect(only.autoCloseBefore == nil && only.wordPattern == nil && only.indentationRules == nil && only.blockComment == nil)

        let full = LanguageConfiguration(json: [
            "comments": ["lineComment": "//", "blockComment": ["/*", "*/"]],
            "brackets": [["[", "]"]],
            "autoClosingPairs": [["open": "\"", "close": "\"", "notIn": ["string", "comment", "regex"]], ["'", "'"],
                                 ["open": "x", "close": "y", "notIn": "string"], ["open": 1, "close": "z"]],
            "surroundingPairs": [["<", ">"]],
            "autoCloseBefore": ";)",
            "wordPattern": ["pattern": "\\w+", "flags": "iu"],
            "indentationRules": ["increaseIndentPattern": "\\{$", "decreaseIndentPattern": ["pattern": "^\\}"], "indentNextLinePattern": "if$"],
        ])
        #expect(full.blockComment == LanguageConfiguration.CommentPair(open: "/*", close: "*/"))
        #expect(full.autoClosingPairs == [EditingPairs.AutoClosingPair("\"", "\"", notIn: [.string, .comment, .regex]), EditingPairs.AutoClosingPair("'", "'")])
        #expect(full.surroundingPairs == [EditingPairs.Pair("<", ">")])
        #expect(full.autoCloseBefore == ";)")
        #expect(full.wordPattern == LanguageConfiguration.Pattern("\\w+", flags: "iu"))
        #expect(full.wordPattern?.regularExpression()?.options.contains(.caseInsensitive) == true)
        #expect(full.indentationRules?.increaseIndentPattern.source == "\\{$")
        #expect(full.indentationRules?.decreaseIndentPattern.source == "^\\}")
        #expect(full.indentationRules?.indentNextLinePattern?.source == "if$")
        #expect(full.indentationRules?.unIndentedLinePattern == nil)
        #expect(full.editingPairs.autoClosingPairs == full.autoClosingPairs)

        // Both indentation patterns are needed; an empty list counts as absent.
        let partial = LanguageConfiguration(json: ["indentationRules": ["increaseIndentPattern": "x"], "brackets": [["(", ")"]], "autoClosingPairs": []])
        #expect(partial.indentationRules == nil)
        #expect(partial.autoClosingPairs == [EditingPairs.AutoClosingPair("(", ")")])
        #expect(LanguageConfiguration() == LanguageConfiguration(json: [:]))
    }

    @Test("Enter rules read as VS Code reads them")
    func onEnterRules() throws {
        let configuration = LanguageConfiguration(json: ["onEnterRules": [
            ["beforeText": "^\\s*/\\*\\*", "afterText": ["pattern": "^\\s*\\*/$", "flags": "i"],
             "action": ["indent": "indentOutdent", "appendText": " * "]],
            ["beforeText": "x", "previousLineText": "y", "action": ["indent": "outdent", "removeText": 1, "appendText": 3]],
            ["beforeText": "x", "action": ["indent": "sideways"]],
            ["action": ["indent": "none"]],
            ["beforeText": "x"],
        ]])
        #expect(configuration.onEnterRules == [
            LanguageConfiguration.OnEnterRule(beforeText: .init("^\\s*/\\*\\*"), afterText: .init("^\\s*\\*/$", flags: "i"), previousLineText: nil,
                                              indent: .indentOutdent, appendText: " * ", removeText: nil),
            LanguageConfiguration.OnEnterRule(beforeText: .init("x"), afterText: nil, previousLineText: .init("y"),
                                              indent: .outdent, appendText: nil, removeText: 1),
        ])
        let python = try #require(registry.language(id: "python")).configuration
        let rule = try #require(python.onEnterRules.first)
        #expect(rule.indent == .indent && rule.beforeText.source.contains("def|class"))
        #expect(rule.beforeText.regularExpression() != nil)
        #expect(try #require(registry.language(id: "swift")).configuration.onEnterRules.isEmpty == false)
        #expect(try #require(registry.language(id: "typescript")).configuration.onEnterRules.contains { $0.appendText == " * " })
        #expect(python.offSide && registry.language(id: "yaml")?.configuration.offSide == true)
        #expect(registry.language(id: "swift")?.configuration.offSide == false)
        #expect(LanguageConfiguration(json: ["folding": ["offSide": true]]).offSide && !LanguageConfiguration().offSide)
    }

    @Test("VS Code's default word pattern finds words and numbers")
    func defaultWords() throws {
        let expression = try #require(LanguageConfiguration.defaultWordPattern.regularExpression())
        let text = "let x_1 = foo.bar(-1.5);"
        let words = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
        #expect(words == ["let", "x_1", "foo", "bar", "-1.5"])
    }

    @Test("the bundled configurations read as VS Code's")
    func bundledConfigurations() throws {
        let typescript = try #require(registry.language(id: "typescript")).configuration
        #expect(typescript.lineComment == "//")
        #expect(typescript.blockComment == LanguageConfiguration.CommentPair(open: "/*", close: "*/"))
        #expect(typescript.autoClosingPairs.contains(EditingPairs.AutoClosingPair("`", "`", notIn: [.string, .comment])))
        #expect(typescript.autoCloseBefore == ";:.,=}])>` \n\t")
        #expect(typescript.indentationRules != nil && typescript.wordPattern != nil)
        #expect(registry.language(id: "python")?.configuration.lineComment == "#")
        #expect(registry.language(id: "html")?.configuration.blockComment == LanguageConfiguration.CommentPair(open: "<!--", close: "-->"))
        let plain = CodeLanguage.plainText.configuration
        #expect(plain.brackets.count == 3 && plain.autoClosingPairs.count == 3 && plain.surroundingPairs.count == 7)
        #expect(plain.lineComment == nil)
        #expect(plain.offSide)
        for language in registry.all {
            #expect(language.configuration.brackets.allSatisfy { !$0.open.isEmpty && !$0.close.isEmpty }, "\(language.id)")
        }
    }

    // MARK: Grammars

    @Test("every bundled grammar is JSON with the scope its entry names, and the engine reads it")
    func grammarsParse() throws {
        let index = try Self.bundledIndex()
        #expect(index.grammars.count >= 60)
        for entry in index.grammars {
            let url = LanguageRegistry.bundledFolder.appendingPathComponent(entry.file)
            let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "\(entry.file)")
            #expect(json["scopeName"] as? String == entry.scopeName)
            #expect(registry.grammar(scopeName: entry.scopeName)?.scopeName == entry.scopeName)
        }
        for language in registry.all where !language.isPlainText {
            #expect(language.scopeName.flatMap(registry.grammarSource(scopeName:)) != nil, "\(language.id)")
        }
    }

    @Test("every grammar another includes is bundled or listed, with a reason, as left out")
    func includesResolve() throws {
        let index = try Self.bundledIndex()
        let sources = try Self.sourceList()
        let listed = try #require((sources["unresolvedIncludes"] as? [String: Any])?["scopes"] as? [String: String])
        #expect(listed.values.allSatisfy { !$0.isEmpty })
        let bundled = Set(index.grammars.map(\.scopeName))
        var unresolved = Set<String>()
        for entry in index.grammars {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: LanguageRegistry.bundledFolder.appendingPathComponent(entry.file)))
            for include in Self.externalIncludes(json) where !bundled.contains(include) {
                unresolved.insert(include)
            }
        }
        #expect(unresolved == Set(listed.keys))
    }

    @Test("grammars injected into a scope are found by its prefixes, with their embedded languages")
    func injections() throws {
        let intoTypeScript = registry.injections(into: "source.ts")
        #expect(intoTypeScript.contains("documentation.injection.ts") && intoTypeScript.contains("inline.graphql"))
        #expect(registry.injections(into: "source.js.jsx").contains("documentation.injection.js.jsx"))
        let markdown = try #require(registry.grammarSource(scopeName: "text.html.markdown"))
        #expect(Set(markdown.injections).isSuperset(of: ["markdown.kotlin.codeblock", "markdown.toml.codeblock", "inline.graphql.markdown.codeblock"]))
        #expect(markdown.embeddedLanguages["meta.embedded.block.kotlin"] == "kotlin")
        #expect(markdown.embeddedLanguages["meta.embedded.block.python"] == "python")
        #expect(markdown.languageID == "markdown")
        #expect(registry.injections(into: "source.rust").isEmpty)
        let typescript = try #require(registry.grammarSource(scopeName: "source.ts"))
        #expect(typescript.tokenTypes["punctuation.definition.template-expression"] == .code)
        #expect(typescript.unbalancedBracketScopes.contains("storage.type.function.arrow"))
        #expect(registry.grammarSource(scopeName: "source.shell")?.balancedBracketScopes == ["*"])
        #expect(registry.grammarSource(scopeName: "source.nothing") == nil)
    }

    @Test("the index is read without reading any grammar, and a grammar is read once")
    func lazy() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // The index and configurations, without a single grammar file.
        let bundle = LanguageRegistry.bundledFolder
        try FileManager.default.copyItem(at: bundle.appendingPathComponent("index.json"), to: folder.appendingPathComponent("index.json"))
        try FileManager.default.copyItem(at: bundle.appendingPathComponent("configurations"), to: folder.appendingPathComponent("configurations"))
        let bare = LanguageRegistry(folder: folder)
        #expect(bare.detect(fileName: "main.swift").scopeName == "source.swift")
        #expect(bare.all.count == registry.all.count)
        #expect(bare.language(forFence: "ts")?.id == "typescript")
        #expect(bare.grammarSource(scopeName: "source.swift")?.url.lastPathComponent == "source.swift.json")
        #expect(bare.grammar(scopeName: "source.swift") == nil)

        let first = try #require(registry.grammar(scopeName: "source.swift"))
        #expect(registry.grammar(scopeName: "source.swift") === first)
    }

    // MARK: Licences

    @Test("every bundled file is covered by a permissive licence whose text is bundled")
    func licences() throws {
        let bundle = LanguageRegistry.bundledFolder
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("ThirdParty/manifest.json"))) as? [[String: Any]])
        // Each permissive licence, and words only its text has: the text bundled must be the licence named,
        // and no copyleft licence may be among them (a repository's licence can change between commits).
        let permissive: [String: String] = [
            "MIT": "Permission is hereby granted, free of charge",
            "BSD-3-Clause": "Neither the name",
            "Apache-2.0": "Apache License",
            "LicenseRef-TextMate-Bundle": "Permission to copy, use, modify, sell and distribute",
        ]
        let copyleft = ["GNU General Public", "GNU GENERAL PUBLIC", "GNU Lesser", "Eclipse Public License", "Mozilla Public License", "ShareAlike"]
        var covered = Set<String>()
        for entry in manifest {
            let license = try #require(entry["license"] as? String)
            let text = try String(contentsOf: bundle.appendingPathComponent("ThirdParty").appendingPathComponent(try #require(entry["licenseFile"] as? String)), encoding: .utf8)
            for part in license.components(separatedBy: " AND ") {
                let words = permissive[part]
                #expect(words != nil, "\(entry["name"] ?? ""): \(part) is not a licence the bundle may use")
                if let words { #expect(text.contains(words), "\(entry["name"] ?? ""): the bundled text is not \(part)") }
            }
            #expect(!copyleft.contains { text.contains($0) }, "\(entry["name"] ?? ""): a copyleft licence")
            #expect((entry["commit"] as? String)?.count == 40)
            #expect((entry["url"] as? String)?.hasPrefix("https://github.com/") == true)
            #expect(text.count > 100)
            covered.formUnion(entry["files"] as? [String] ?? [])
        }
        let files = try #require(FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey]))
        var bundled = Set<String>()
        for case let url as URL in files where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            let path = String(url.standardizedFileURL.path.dropFirst(bundle.standardizedFileURL.path.count + 1))
            if !path.hasPrefix("ThirdParty/") { bundled.insert(path) }
        }
        #expect(bundled == covered)
    }

    // MARK: Installing

    @Test("a grammar file adds its language, found by its file types and first line")
    func installGrammar() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = LanguageRegistry(folder: LanguageRegistry.bundledFolder)
        let file = folder.appendingPathComponent("Nim.tmLanguage.json")
        try Data(#"""
            { "name": "Nim", "scopeName": "source.nim", "fileTypes": ["nim", "nims"], "firstLineMatch": "^#!.*\\bnim\\b", // comment
              "patterns": [{ "match": "\\bproc\\b", "name": "keyword.nim" }] }
            """#.utf8).write(to: file)
        let installed = folder.appendingPathComponent("Languages")
        let added = try registry.install(from: file, into: installed)
        #expect(added.map(\.id) == ["nim"])
        #expect(added.first?.displayName == "Nim" && added.first?.scopeName == "source.nim")
        #expect(registry.detect(fileName: "x.nims").id == "nim")
        #expect(registry.detect(fileName: "run", firstLine: "#!/usr/bin/env nim").id == "nim")
        #expect(registry.grammar(scopeName: "source.nim")?.scopeName == "source.nim")
        #expect(registry.installed == [InstalledLanguages(id: "source.nim", name: "Nim", languageIDs: ["nim"], scopeNames: ["source.nim"])])
        // Read again by a fresh registry, as the app does at launch.
        let fresh = LanguageRegistry(folder: LanguageRegistry.bundledFolder)
        fresh.loadInstalled(from: installed)
        #expect(fresh.language(id: "nim")?.scopeName == "source.nim")

        try registry.remove("source.nim", from: installed)
        #expect(registry.language(id: "nim") == nil && registry.installed.isEmpty)
        #expect(registry.detect(fileName: "x.nim").isPlainText)
    }

    @Test("a property-list grammar for a known scope replaces that language's grammar")
    func installReplacingGrammar() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = LanguageRegistry(folder: LanguageRegistry.bundledFolder)
        let grammar: [String: Any] = ["name": "My Swift", "scopeName": "source.swift", "fileTypes": ["swift"],
                                      "patterns": [["match": "func", "name": "keyword.swift"]]]
        let file = folder.appendingPathComponent("Swift.tmLanguage")
        try PropertyListSerialization.data(fromPropertyList: grammar, format: .xml, options: 0).write(to: file)
        let installed = folder.appendingPathComponent("Languages")
        let added = try registry.install(from: file, into: installed)
        #expect(added.map(\.id) == ["swift"])
        let source = try #require(registry.grammarSource(scopeName: "source.swift"))
        #expect(source.url.resolvingSymlinksInPath().path.hasPrefix(installed.resolvingSymlinksInPath().path))
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: source.url)) is [String: Any])
        #expect(registry.detect(fileName: "x.swift").displayName == "Swift")
        #expect(registry.language(id: "swift")?.configuration.lineComment == "//")
    }

    @Test("an extension folder and a .vsix add their languages, configurations and injections")
    func installExtension() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensionFolder = folder.appendingPathComponent("ext/extension")
        try Self.writeExtension(at: extensionFolder)
        let installed = folder.appendingPathComponent("Languages")

        let registry = LanguageRegistry(folder: LanguageRegistry.bundledFolder)
        let added = try registry.install(from: extensionFolder, into: installed)
        #expect(added.map(\.id) == ["mylang"])
        let language = try #require(registry.language(id: "mylang"))
        #expect(language.displayName == "My Language" && language.scopeName == "source.mylang")
        #expect(language.configuration.lineComment == ";;")
        #expect(registry.detect(fileName: "a.myl").id == "mylang")
        #expect(registry.detect(fileName: "Myfile").id == "mylang")
        // A user's language wins an extension a bundled one also claims.
        #expect(registry.detect(fileName: "a.ini").id == "mylang")
        #expect(registry.injections(into: "source.ts").contains("mylang.injection"))
        #expect(registry.grammarSource(scopeName: "source.mylang")?.embeddedLanguages == ["meta.embedded.sql": "sql"])
        #expect(registry.grammarSource(scopeName: "source.mylang")?.tokenTypes == ["string.template": .code])
        // The grammar outside the extension's folder is not read.
        #expect(registry.grammarSource(scopeName: "source.outside") == nil)
        #expect(registry.installed.map(\.id) == ["someone.mylang"])
        #expect(registry.installed.first?.name == "My Language Support")

        // The same extension packed as a .vsix replaces the folder's copy.
        let vsix = folder.appendingPathComponent("mylang.vsix")
        try Self.zip(folder.appendingPathComponent("ext"), to: vsix)
        let again = try registry.install(from: vsix, into: installed)
        #expect(again.map(\.id) == ["mylang"])
        #expect(registry.installed.count == 1)
    }

    @Test("what is not a grammar or holds no languages is refused")
    func installRefusals() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = LanguageRegistry(folder: LanguageRegistry.bundledFolder)
        let installed = folder.appendingPathComponent("Languages")

        let notGrammar = folder.appendingPathComponent("theme.json")
        try Data(#"{ "name": "A theme", "colors": {} }"#.utf8).write(to: notGrammar)
        #expect(throws: LanguageInstallError.notAGrammar) { try registry.install(from: notGrammar, into: installed) }

        let themeOnly = folder.appendingPathComponent("theme-extension")
        try FileManager.default.createDirectory(at: themeOnly, withIntermediateDirectories: true)
        try Data(#"{ "name": "t", "contributes": { "themes": [{ "label": "T", "path": "./t.json" }] } }"#.utf8).write(to: themeOnly.appendingPathComponent("package.json"))
        #expect(throws: LanguageInstallError.nothingToInstall) { try registry.install(from: themeOnly, into: installed) }

        let empty = folder.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: LanguageInstallError.notAnExtension) { try registry.install(from: empty, into: installed) }
        #expect(throws: LanguageInstallError.unreadable) { try registry.install(from: folder.appendingPathComponent("missing.json"), into: installed) }
        #expect(registry.installed.isEmpty)
        #expect(!LanguageInstallError.notAGrammar.message.isEmpty)
    }

    // MARK: Globs

    @Test("file name patterns match as VS Code's globs", arguments: [
        ("Dockerfile.*", "dockerfile.dev", true), ("Dockerfile.*", "dockerfile", false), ("tsconfig.*.json", "tsconfig.app.json", true),
        ("*docker*compose*.yml", "my-docker-compose.yml", true), ("**/.git/config", "/a/b/.git/config", true),
        ("**/.git/config", ".git/config", true), ("**/.git/config", "/a/.git/configs", false), ("**/.cursor/**/*.mdc", "/r/.cursor/a/b/c.mdc", true),
        ("**/.cursor/**/*.mdc", "/r/.cursor/c.mdc", true), ("*.{ts,js}", "a.js", true), ("x.[0-9]", "x.5", true), ("x.[!0-9]", "x.5", false),
        ("a?c", "abc", true), ("a?c", "a/c", false), ("*.md", "dir/a.md", false), ("**", "anything/at/all", true),
    ])
    func glob(pattern: String, path: String, matches: Bool) throws {
        #expect(try #require(PathGlob(pattern)).matches(path) == matches)
    }

    // MARK: Helpers

    static func bundledIndex() throws -> Pack.Index {
        try JSONDecoder().decode(Pack.Index.self, from: Data(contentsOf: LanguageRegistry.bundledFolder.appendingPathComponent("index.json")))
    }

    /// `Scripts/update-languages.json`, the source list the bundle is built from.
    static func sourceList() throws -> [String: Any] {
        let scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Scripts").standardizedFileURL
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: scripts.appendingPathComponent("update-languages.json"))) as? [String: Any])
    }

    static func externalIncludes(_ node: Any) -> [String] {
        if let object = node as? [String: Any] {
            var found: [String] = []
            if let include = object["include"] as? String, let first = include.first, first != "#", first != "$" {
                found.append(String(include.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]))
            }
            return found + object.values.flatMap(externalIncludes)
        }
        if let list = node as? [Any] { return list.flatMap(externalIncludes) }
        return []
    }

    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-languages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A small extension: one language with a configuration and a grammar, an injection grammar, and a
    /// grammar whose path leads outside the extension.
    static func writeExtension(at folder: URL) throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("syntaxes"), withIntermediateDirectories: true)
        let manifest = #"""
        { "name": "mylang", "publisher": "someone", "displayName": "My Language Support", "main": "./extension.js",
          "contributes": {
            "languages": [{ "id": "mylang", "aliases": ["My Language", "myl"], "extensions": [".myl", ".ini"], "filenames": ["Myfile"],
                            "configuration": "./language-configuration.json" }],
            "grammars": [
              { "language": "mylang", "scopeName": "source.mylang", "path": "./syntaxes/mylang.tmLanguage.json",
                "embeddedLanguages": { "meta.embedded.sql": "sql" }, "tokenTypes": { "string.template": "other" } },
              { "scopeName": "mylang.injection", "path": "./syntaxes/injection.json", "injectTo": ["source.ts"] },
              { "scopeName": "source.outside", "path": "../../outside.json" }
            ] } }
        """#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("package.json"))
        try Data(#"{ "comments": { "lineComment": ";;" }, "brackets": [["(", ")"]] }"#.utf8).write(to: folder.appendingPathComponent("language-configuration.json"))
        try Data(#"{ "scopeName": "source.mylang", "patterns": [] }"#.utf8).write(to: folder.appendingPathComponent("syntaxes/mylang.tmLanguage.json"))
        try Data(#"{ "scopeName": "mylang.injection", "injectionSelector": "L:source.ts", "patterns": [] }"#.utf8).write(to: folder.appendingPathComponent("syntaxes/injection.json"))
        try Data(#"{ "scopeName": "source.outside", "patterns": [] }"#.utf8).write(to: folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("outside.json"))
        try Data("module.exports = {}".utf8).write(to: folder.appendingPathComponent("extension.js"))
    }

    /// Zips a folder's contents as a .vsix is packed (`extension/…` at the top).
    static func zip(_ folder: URL, to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", folder.path, archive.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + 60) == .timedOut {
            process.terminate()
            exited.wait()
        }
        #expect(process.terminationStatus == 0)
    }
}
