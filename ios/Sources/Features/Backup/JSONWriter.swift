import CyberSendDomain
import Foundation

// Deterministic ordered JSON writer. The TypeScript spec serializes exports with
// JSON.stringify(payload, null, 2), which emits object keys in insertion order: payload
// keys app, schema_version, exported_at, tables; table keys in FK insert order; row keys
// in column order. Swift dictionaries have no order, so exports render through this
// explicit node tree instead of JSONEncoder. Keys are not alphabetically sorted: fixed
// spec order is what keeps the Swift and TypeScript bytes identical for the same data
// (determinism comes from the fixed order, not from sorting). Number and string
// formatting mirrors JavaScript's String(number) and JSON.stringify escaping so golden
// fixtures compare byte for byte.

/// A JSON value with explicit object key order.
enum JSONNode {
    case object([(String, JSONNode)])
    case array([JSONNode])
    case string(String)
    /// A pre-formatted, JavaScript compatible number literal.
    case number(String)
    case null
}

enum JSONRenderer {
    /// Renders like JSON.stringify(value, null, 2): two space indent, ",\n" separators,
    /// no trailing newline, compact "{}" and "[]" for empty containers.
    static func render(_ node: JSONNode, indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: (indent + 1) * 2)
        let closePad = String(repeating: " ", count: indent * 2)
        switch node {
        case .object(let entries):
            guard !entries.isEmpty else { return "{}" }
            let body = entries.map { key, value in
                "\(pad)\(JSONRenderer.escape(key)): \(JSONRenderer.render(value, indent: indent + 1))"
            }.joined(separator: ",\n")
            return "{\n\(body)\n\(closePad)}"
        case .array(let elements):
            guard !elements.isEmpty else { return "[]" }
            let body = elements
                .map { "\(pad)\(JSONRenderer.render($0, indent: indent + 1))" }
                .joined(separator: ",\n")
            return "[\n\(body)\n\(closePad)]"
        case .string(let value):
            return escape(value)
        case .number(let literal):
            return literal
        case .null:
            return "null"
        }
    }

    /// JSON.stringify string escaping: quote, backslash, control characters. Non ASCII
    /// stays raw, exactly like JSON.stringify.
    static func escape(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            case "\u{08}":
                result += "\\b"
            case "\u{0C}":
                result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}

/// Formats a Double the way JavaScript's String(number) does, which is what
/// JSON.stringify uses for JSON numbers. Integral values lose the ".0" (JSON.stringify
/// prints 1.0 as "1"); values in the 1e16 to 1e21 range print with full digits in
/// JavaScript but with an exponent in Swift, a documented divergence that fixtures
/// avoid by staying in ordinary ranges.
func jsNumberString(_ value: Double) -> String {
    guard value.isFinite else { return "null" }
    if value == value.rounded(), abs(value) < 1e16 {
        return String(Int64(value))
    }
    return String(describing: value)
}

/// Converts an export value into a JSON node, honoring the column type so a real
/// column holding 30.0 renders as "30" like the TypeScript port.
func jsonNode(for value: ExportValue, type: ExportColumnType) -> JSONNode {
    switch value {
    case .text(let text):
        return .string(text)
    case .integer(let integer):
        return .number(String(integer))
    case .real(let double):
        return .number(jsNumberString(double))
    case .null:
        return .null
    }
}
