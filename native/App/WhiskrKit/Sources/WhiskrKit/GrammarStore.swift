import Foundation
import Synchronization

/// Every language's compiled grammar and its tokenizer, made once for the app's life, off the main
/// thread, the first time a file, a Markdown fence or a diff in that language is shown. Every document
/// of a language shares the tokenizer (and so the expressions it has compiled).
public final class GrammarStore: Sendable {
    public static let shared = GrammarStore(registry: .shared)

    private let registry: LanguageRegistry
    private let made = Mutex<[String: Task<TextMateTokenizer?, Never>]>([:])

    public init(registry: LanguageRegistry) {
        self.registry = registry
    }

    /// The tokenizer for `language`; nil for plain text, or when its grammar cannot be read.
    public func tokenizer(for language: CodeLanguage) async -> TextMateTokenizer? {
        guard let scope = language.scopeName else { return nil }
        return await tokenizer(scopeName: scope)
    }

    /// The tokenizer for a scope's grammar, compiled with the grammars it includes and those injected into it.
    public func tokenizer(scopeName: String) async -> TextMateTokenizer? {
        let registry = registry
        let task = made.withLock { made in
            if let known = made[scopeName] { return known }
            let task = Task.detached(priority: .userInitiated) { () -> TextMateTokenizer? in
                guard let raw = registry.grammar(scopeName: scopeName) else { return nil }
                return TextMateTokenizer(grammar: TextMateGrammar(raw, provider: registry, tokenTypes: registry.grammarSource(scopeName: scopeName)?.tokenTypes ?? [:]))
            }
            made[scopeName] = task
            return task
        }
        return await task.value
    }

    /// Forgets every grammar (after languages were added or removed): the next use reads them again.
    public func reset() {
        made.withLock { $0.removeAll() }
    }
}
