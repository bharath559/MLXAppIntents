import MLXAppIntents

/// A deterministic `ModelBackend` for tests and the example app.
/// Zero network, zero model weights: `respond` pops the next scripted
/// turn from an actor-isolated queue.
///
/// The queue is actor-isolated (not a lock, not a mutable struct field)
/// so `ScriptedModel` stays `Sendable` under Swift 6 strict concurrency.
public struct ScriptedModel: ModelBackend, Sendable {
    private let state: ScriptState

    public init(turns: [ModelTurn]) {
        self.state = ScriptState(turns: turns, repeatTurn: nil, failureDetail: nil, hangs: false)
    }

    /// Answers with the given text on the first (only) turn.
    public static func answering(_ text: String) -> ScriptedModel {
        ScriptedModel(turns: [.text(text)])
    }

    /// Calls one tool, then answers. `id` defaults to `"call-1"`.
    public static func calling(
        tool name: String, argumentsJSON: String, thenAnswering text: String, id: String = "call-1"
    ) -> ScriptedModel {
        ScriptedModel(turns: [
            .toolCall(ToolCall(id: id, name: name, argumentsJSON: argumentsJSON)),
            .text(text),
        ])
    }

    /// Calls the same tool forever. The runner must stop it with
    /// `maxTurns` / `maxToolCalls` — used by the budget tests.
    public static func repeatingCall(tool name: String, argumentsJSON: String, id: String = "call-1") -> ScriptedModel {
        ScriptedModel(
            turns: [],
            repeatTurn: .toolCall(ToolCall(id: id, name: name, argumentsJSON: argumentsJSON)))
    }

    /// Every `respond` throws `backendFailed` with the given detail.
    public static func failing(_ detail: String) -> ScriptedModel {
        ScriptedModel(turns: [], failureDetail: detail)
    }

    /// Every `respond` sleeps until cancelled. Used by the cancellation
    /// test: cancelling the runner task must surface `CancellationError`.
    public static func hanging() -> ScriptedModel {
        ScriptedModel(turns: [], hangs: true)
    }

    private init(turns: [ModelTurn], repeatTurn: ModelTurn? = nil, failureDetail: String? = nil, hangs: Bool = false) {
        self.state = ScriptState(
            turns: turns, repeatTurn: repeatTurn, failureDetail: failureDetail, hangs: hangs)
    }

    public func respond(to transcript: [AgentMessage], tools: [ToolDefinition]) async throws -> ModelTurn {
        try await state.next()
    }
}

private actor ScriptState {
    private var turns: [ModelTurn]
    private var index = 0
    private let repeatTurn: ModelTurn?
    private let failureDetail: String?
    private let hangs: Bool

    init(turns: [ModelTurn], repeatTurn: ModelTurn?, failureDetail: String?, hangs: Bool) {
        self.turns = turns
        self.repeatTurn = repeatTurn
        self.failureDetail = failureDetail
        self.hangs = hangs
    }

    func next() async throws -> ModelTurn {
        if let failureDetail {
            throw MLXAppIntentsError.backendFailed(detail: failureDetail)
        }
        if hangs {
            // Cancellation-cooperative: Task.sleep throws CancellationError
            // when the caller cancels, which is exactly what the test asserts.
            try await Task.sleep(for: .seconds(3600))
        }
        if let repeatTurn {
            return repeatTurn
        }
        guard index < turns.count else {
            throw MLXAppIntentsError.backendFailed(detail: "script exhausted")
        }
        defer { index += 1 }
        return turns[index]
    }
}
