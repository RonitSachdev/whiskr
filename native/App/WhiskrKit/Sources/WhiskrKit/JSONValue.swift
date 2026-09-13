import Foundation

/// Any JSON document, as a value. Hook payloads come from outside the app and differ per event and per
/// Claude Code version, so they are kept in this shape and every field is checked for its type where
/// it is used, never trusted.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { fields[key] } else { nil }
    }

    /// The string, or "" for anything that is not one.
    public var text: String {
        if case .string(let value) = self { value } else { "" }
    }

    /// The fields, or none for anything that is not an object.
    public var fields: [String: JSONValue] {
        if case .object(let value) = self { value } else { [:] }
    }

    public var items: [JSONValue] {
        if case .array(let value) = self { value } else { [] }
    }

    /// True only for JSON `true`.
    public var isTrue: Bool {
        if case .bool(true) = self { true } else { false }
    }
}

public extension Optional where Wrapped == JSONValue {
    var text: String { self?.text ?? "" }
    var fields: [String: JSONValue] { self?.fields ?? [:] }
    var items: [JSONValue] { self?.items ?? [] }
    var isTrue: Bool { self?.isTrue ?? false }
    subscript(key: String) -> JSONValue? { self?[key] }
}

/// Literals, so payloads can be written as plain dictionaries (mostly in tests).
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements) { first, _ in first }) }
}
