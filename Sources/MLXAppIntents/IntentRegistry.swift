import Foundation

/// A type-erased `IntentTool`: name, definition, risk, and a JSON-in /
/// JSON-out execute closure. The registry stores these, never the concrete
/// intent types, so dispatch is uniform across tools.
public struct AnyIntentTool: Sendable {
    public let definition: ToolDefinition
    public let risk: IntentRisk
    private let execute: @Sendable (Data) async throws -> Data

    public init<I: IntentTool>(_ type: I.Type) {
        self.definition = I.toolDefinition
        self.risk = I.risk
        self.execute = { data in
            let arguments = try JSONDecoder().decode(I.Arguments.self, from: data)
            let tool = I(arguments: arguments)
            let result = try await tool.run(arguments: arguments)
            return try JSONEncoder().encode(result)
        }
    }

    public func executeJSON(_ data: Data) async throws -> Data {
        try await execute(data)
    }
}

/// The registry of bridged intents. An actor so registration and dispatch
/// are serialized and `Sendable`-safe: the runner and the model backend
/// share one registry across concurrent turns.
///
/// Registration is explicit — there is no runtime scan for intents.
/// Duplicate names are rejected at registration time, never at dispatch.
public actor IntentRegistry {
    private var tools: [String: AnyIntentTool] = [:]

    public init() {}

    /// Registers a tool type. Throws `invalidToolCall` on a duplicate name
    /// or on a schema that fails `ToolDefinition.validate()`.
    public func register<I: IntentTool>(_ type: I.Type) throws {
        let box = AnyIntentTool(type)
        try box.definition.validate()
        guard tools[box.definition.name] == nil else {
            throw MLXAppIntentsError.invalidToolCall(
                detail: "duplicate tool name '\(box.definition.name)'")
        }
        tools[box.definition.name] = box
    }

    public func toolDefinitions() -> [ToolDefinition] {
        tools.values.map(\.definition).sorted { $0.name < $1.name }
    }

    public func tool(named name: String) -> ToolDefinition? {
        tools[name]?.definition
    }

    public func risk(of name: String) -> IntentRisk? {
        tools[name]?.risk
    }

    /// Decodes `argumentsJSON` to the tool's `Arguments`, runs it, and
    /// returns the `ResultValue` as a JSON string.
    /// - Unknown tool: throws `unknownTool`.
    /// - Argument JSON that does not match the schema: throws
    ///   `invalidArguments` with the decoder detail — never a crash.
    /// - A tool that throws: wrapped as `toolFailed`, unless it is already
    ///   an `MLXAppIntentsError`, which is rethrown as-is.
    public func dispatch(name: String, argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8) else {
            throw MLXAppIntentsError.invalidArguments(
                tool: name, detail: "arguments are not valid UTF-8")
        }
        return try await dispatch(name: name, argumentsData: data)
    }

    public func dispatch(name: String, argumentsData: Data) async throws -> String {
        guard let box = tools[name] else {
            throw MLXAppIntentsError.unknownTool(name: name)
        }
        do {
            let output = try await box.executeJSON(argumentsData)
            guard let string = String(data: output, encoding: .utf8) else {
                throw MLXAppIntentsError.toolFailed(
                    tool: name, detail: "result is not valid UTF-8")
            }
            return string
        } catch let error as MLXAppIntentsError {
            throw error
        } catch is DecodingError {
            throw MLXAppIntentsError.invalidArguments(
                tool: name, detail: "arguments do not match the tool schema")
        } catch is EncodingError {
            throw MLXAppIntentsError.toolFailed(
                tool: name, detail: "result could not be encoded")
        } catch {
            throw MLXAppIntentsError.toolFailed(tool: name, detail: "\(error)")
        }
    }
}
