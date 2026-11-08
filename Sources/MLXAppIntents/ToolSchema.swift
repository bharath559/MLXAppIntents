import Foundation

/// One JSON-schema property in a tool's parameter object.
/// `enumValues` encodes as the JSON Schema `"enum"` key.
public struct ToolProperty: Codable, Sendable, Equatable {
    public let type: String
    public let description: String?
    public let enumValues: [String]?

    public init(type: String, description: String? = nil, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
    }

    private enum CodingKeys: String, CodingKey {
        case type, description
        case enumValues = "enum"
    }
}

/// The JSON Schema object describing a tool's arguments.
/// Always `type == "object"`: tools take a single JSON object.
public struct ToolParameters: Codable, Sendable, Equatable {
    public let type: String
    public let properties: [String: ToolProperty]
    public let required: [String]

    public init(properties: [String: ToolProperty] = [:], required: [String] = []) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

/// A tool as the model sees it: name, human description, and parameter schema.
/// This is the single schema shared by the MLX `ToolSpec` projection, the
/// Foundation Models `Tool` projection, and the registry — one definition,
/// every runtime reads the same shape.
public struct ToolDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: ToolParameters

    public init(name: String, description: String, parameters: ToolParameters) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// Deterministic JSON (sorted keys) so schema snapshots are stable in tests.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public func jsonString() throws -> String {
        let data = try jsonData()
        guard let string = String(data: data, encoding: .utf8) else {
            throw MLXAppIntentsError.invalidToolCall(detail: "tool '\(name)' schema is not UTF-8")
        }
        return string
    }

    /// Catches the schema bugs that silently break tool calling: empty name /
    /// description, and a `required` key with no matching property.
    /// Throws `MLXAppIntentsError.invalidToolCall` — never a crash.
    public func validate() throws {
        guard !name.isEmpty else {
            throw MLXAppIntentsError.invalidToolCall(detail: "tool name must not be empty")
        }
        guard !description.isEmpty else {
            throw MLXAppIntentsError.invalidToolCall(detail: "tool '\(name)' description must not be empty")
        }
        for key in parameters.required {
            guard parameters.properties[key] != nil else {
                throw MLXAppIntentsError.invalidToolCall(
                    detail: "tool '\(name)' requires '\(key)' but has no such property")
            }
        }
        let duplicates = parameters.required.filter { key in
            parameters.required.filter { $0 == key }.count > 1
        }
        guard duplicates.isEmpty else {
            throw MLXAppIntentsError.invalidToolCall(
                detail: "tool '\(name)' has duplicate required keys: \(Set(duplicates).sorted())")
        }
    }
}
