import Foundation

/// JSON with comments and trailing commas, as VS Code writes its settings, themes, language configurations
/// and extension manifests (`settings.json`, `*-color-theme.json`, `language-configuration.json`): `//` and
/// `/* … */` comments and a comma before `}` or `]` are taken out, then Foundation reads what is left.
public enum JSONC {
    public enum Failure: Error, Equatable, Sendable {
        case notJSON(String)
    }

    /// The text as plain JSON: comments become spaces (so positions in error messages still point at the
    /// right place) and trailing commas are dropped. Strings are left exactly as written.
    public static func strip(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        // A byte order mark is not JSON.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        // Where the last comma written outside a string is in `out`, while only spaces have followed it.
        var pendingComma: Int?
        var index = 0
        let count = bytes.count
        while index < count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                pendingComma = nil
                out.append(byte)
                index += 1
                while index < count {
                    let inner = bytes[index]
                    out.append(inner)
                    index += 1
                    if inner == UInt8(ascii: "\\"), index < count {
                        out.append(bytes[index])
                        index += 1
                    } else if inner == UInt8(ascii: "\"") {
                        break
                    }
                }
            case UInt8(ascii: "/") where index + 1 < count && bytes[index + 1] == UInt8(ascii: "/"):
                while index < count, bytes[index] != UInt8(ascii: "\n") {
                    out.append(UInt8(ascii: " "))
                    index += 1
                }
            case UInt8(ascii: "/") where index + 1 < count && bytes[index + 1] == UInt8(ascii: "*"):
                out.append(contentsOf: [UInt8(ascii: " "), UInt8(ascii: " ")])
                index += 2
                while index < count, !(bytes[index] == UInt8(ascii: "*") && index + 1 < count && bytes[index + 1] == UInt8(ascii: "/")) {
                    out.append(bytes[index] == UInt8(ascii: "\n") ? bytes[index] : UInt8(ascii: " "))
                    index += 1
                }
                if index < count {
                    out.append(contentsOf: [UInt8(ascii: " "), UInt8(ascii: " ")])
                    index += 2
                }
            case UInt8(ascii: ","):
                pendingComma = out.count
                out.append(byte)
                index += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if let comma = pendingComma { out[comma] = UInt8(ascii: " ") }
                pendingComma = nil
                out.append(byte)
                index += 1
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                out.append(byte)
                index += 1
            default:
                pendingComma = nil
                out.append(byte)
                index += 1
            }
        }
        return Data(out)
    }

    /// The parsed value (dictionaries, arrays, strings, numbers, booleans, `NSNull`).
    public static func object(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: strip(data), options: [.fragmentsAllowed])
        } catch {
            throw Failure.notJSON((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription)
        }
    }

    /// The parsed value when it is an object.
    public static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let dictionary = try object(data) as? [String: Any] else { throw Failure.notJSON("The top level is not an object.") }
        return dictionary
    }
}
