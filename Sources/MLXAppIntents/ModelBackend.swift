/// The pluggable model seam. No MLX import, no Foundation Models import:
/// any backend — MLX `ChatSession`, a Foundation Models `LanguageModelSession`,
/// or a scripted fake — adapts to this protocol. See `docs/mlx-adapter.md`
/// for the real `ChatSession` wiring (unverified against mlx-swift-lm 3.32.x).
///
/// Backends must be cancellation-cooperative: check for cancellation per
/// turn so the runner's timeouts and the caller's `Task.cancel()` actually
/// tear the work down.
public struct ToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// One transcript entry. The runner owns the transcript; the backend only
/// reads it and returns the next turn. Keeping tool results as transcript
/// entries (not side-channel state) is what lets the model retry after a
/// failed or timed-out tool call.
public enum AgentMessage: Sendable, Equatable {
    case user(String)
    case assistantText(String)
    case toolCall(ToolCall)
    case toolResult(callId: String, name: String, resultJSON: String)
}

/// What one backend call returns: either final text, or one tool call to
/// execute. The runner loops on `.toolCall` until text, budget, or error.
public enum ModelTurn: Sendable, Equatable {
    case text(String)
    case toolCall(ToolCall)
}

/// A model backend. `respond` receives the full transcript and the current
/// tool definitions on every turn, so stateless backends stay correct and
/// stateful ones (a `ChatSession` with a KV cache) can ignore the transcript
/// and use their own history.
public protocol ModelBackend: Sendable {
    func respond(to transcript: [AgentMessage], tools: [ToolDefinition]) async throws -> ModelTurn
}
