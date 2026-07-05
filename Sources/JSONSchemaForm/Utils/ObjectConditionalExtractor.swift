import Foundation

/// Extracts object-level `if`/`then`/`else` conditionals from a raw JSON
/// schema string, keyed by field ID path ("root", "root_settings", ...).
///
/// The `JSONSchema` model type does not represent `if`/`then`/`else`, so this
/// utility parses the raw JSON directly (the same side-channel pattern as
/// `PropertyOrderExtractor`). The result is injected into the uiSchema under
/// the reserved `__objectConditionals` key and consumed by `ObjectField`,
/// which shows/hides the conditional properties as the object's own form
/// data changes.
enum ObjectConditionalExtractor {

    /// Walks the raw schema JSON and returns per-object conditionals keyed by
    /// field ID: any object node carrying "if" (plus optional "then"/"else")
    /// yields a `ConditionalSchema` under that node's field ID.
    ///
    /// - Parameters:
    ///   - jsonString: The raw JSON schema string
    ///   - idPrefix: The root field ID prefix (default: "root")
    ///   - idSeparator: The separator used in field IDs (default: "_")
    /// - Returns: A dictionary mapping field ID paths to their conditionals,
    ///   or `nil` when the JSON has none (or cannot be parsed).
    static func extract(
        from jsonString: String,
        idPrefix: String = "root",
        idSeparator: String = "_"
    ) -> [String: [ConditionalSchema]]? {
        guard let data = jsonString.data(using: .utf8),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        var result: [String: [ConditionalSchema]] = [:]
        walk(schema: root, id: idPrefix, separator: idSeparator, result: &result)
        return result.isEmpty ? nil : result
    }

    private static func walk(
        schema: [String: Any],
        id: String,
        separator: String,
        result: inout [String: [ConditionalSchema]]
    ) {
        if let condition = schema["if"] as? [String: Any] {
            result[id, default: []].append(
                ConditionalSchema(
                    condition: condition,
                    thenSchema: schema["then"] as? [String: Any],
                    elseSchema: schema["else"] as? [String: Any]
                ))
        }
        guard let properties = schema["properties"] as? [String: Any] else { return }
        for (name, child) in properties {
            if let childSchema = child as? [String: Any] {
                walk(
                    schema: childSchema,
                    id: "\(id)\(separator)\(name)",
                    separator: separator,
                    result: &result)
            }
        }
    }
}
