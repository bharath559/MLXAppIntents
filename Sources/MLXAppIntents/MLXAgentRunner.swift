import Foundation

/// Internal: a single tool execution was cut off by its timeout.
/// Mapped to a fed-back error tool-result at the call boundary — never
/// surfaced directly as a throw from `run(prompt:)`.
private struct ToolCallTimedOut: Error, Sendable {}

/// The agent loop: model -> tool -> model, until final text, budget, or
/// a hard failure.
///
/// An actor so the registry, backend, and budget state are serialized:
/// the underlying model session is one-request-at-a-time and must have
/// exactly one owner.
///
/// Guarantees:
/// - Approval: a `.destructive` tool never executes without an approver
///   returning `true`. No approver -> `approvalRequired` thrown;
///   approver returns `false` -> `approvalDenied` thrown. Neither is
///   fed back to the model as a tool result.
/// - Failures are fed back: unknown tool, invalid arguments (after one
///   bounded repair), tool failure, and tool timeout all become error
///   tool-results in the transcript so the model can retry — the run
///   does not hang and does not present a failed result as success.
/// - Budgets: `maxTurns`, `maxToolCalls`, and `totalTimeout` are enforced;
///   exceeding them throws `maxTurnsExceeded` / `backendFailed`.
/// - Cancellation: `Task.checkCancellation()` runs every turn and the
///   backend / tool timeouts are cancellation races, so cancelling the
///   caller tears the run down with `CancellationError`.
/// - Timeouts require cooperative cancellation from the tool / backend
///   (a `Task.sleep`-based tool exits promptly; a tool parked in an
///   uninterruptible synchronous call cannot be unblocked — same limit
///   as TypedStreamFM's attempt timeout).
public actor MLXAgentRunner {
    public struct RunnerPolicy: Sendable {
        public var maxTurns: Int = 8
        public var maxToolCalls: Int = 16
        public var toolTimeout: Duration = .seconds(10)
        public var totalTimeout: Duration = .seconds(60)

        public init(
            maxTurns: Int = 8,
            maxToolCalls: Int = 16,
            toolTimeout: Duration = .seconds(10),
            totalTimeout: Duration = .seconds(60)
        ) {
            self.maxTurns = maxTurns
            self.maxToolCalls = maxToolCalls
            self.toolTimeout = toolTimeout
            self.totalTimeout = totalTimeout
        }

        public static var `default`: RunnerPolicy { RunnerPolicy() }
    }

    public struct ExecutedToolCall: Sendable {
        public let call: ToolCall
        public let resultJSON: String
        public let duration: Duration

        public init(call: ToolCall, resultJSON: String, duration: Duration) {
            self.call = call
            self.resultJSON = resultJSON
            self.duration = duration
        }
    }

    public struct AgentResult: Sendable {
        public let finalText: String
        public let toolCalls: [ExecutedToolCall]
        public let turns: Int

        public init(finalText: String, toolCalls: [ExecutedToolCall], turns: Int) {
            self.finalText = finalText
            self.toolCalls = toolCalls
            self.turns = turns
        }
    }

    private let registry: IntentRegistry
    private let backend: any ModelBackend
    private let policy: RunnerPolicy
    /// Approval hook: the v0.1 approval surface. Called only for tools
    /// whose risk `requiresApproval`. Return `false` to refuse execution.
    private let approver: (@Sendable (ToolCall, IntentRisk) async -> Bool)?

    public init(
        registry: IntentRegistry,
        backend: any ModelBackend,
        policy: RunnerPolicy = .default,
        approver: (@Sendable (ToolCall, IntentRisk) async -> Bool)? = nil
    ) {
        self.registry = registry
        self.backend = backend
        self.policy = policy
        self.approver = approver
    }

    public func run(prompt: String) async throws -> AgentResult {
        let deadline = ContinuousClock.now + policy.totalTimeout
        var transcript: [AgentMessage] = [.user(prompt)]
        var executed: [ExecutedToolCall] = []
        var toolCallAttempts = 0
        var turns = 0

        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw MLXAppIntentsError.backendFailed(detail: "total timeout exceeded")
            }
            guard turns < policy.maxTurns else {
                throw MLXAppIntentsError.maxTurnsExceeded(turns: turns)
            }
            turns += 1

            let turn = try await nextTurn(transcript: transcript, deadline: deadline)
            switch turn {
            case .text(let text):
                return AgentResult(finalText: text, toolCalls: executed, turns: turns)
            case .toolCall(let call):
                toolCallAttempts += 1
                guard toolCallAttempts <= policy.maxToolCalls else {
                    throw MLXAppIntentsError.maxTurnsExceeded(turns: turns)
                }
                transcript.append(.toolCall(call))
                let outcome = try await execute(call: call)
                if let done = outcome.executed {
                    executed.append(done)
                }
                transcript.append(
                    .toolResult(callId: call.id, name: call.name, resultJSON: outcome.resultJSON))
            }
        }
    }

    // MARK: - Backend turn, bounded by the remaining total timeout

    private func nextTurn(transcript: [AgentMessage], deadline: ContinuousClock.Instant) async throws -> ModelTurn {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else {
            throw MLXAppIntentsError.backendFailed(detail: "total timeout exceeded")
        }
        let backend = self.backend
        let tools = await registry.toolDefinitions()
        do {
            return try await withTimeout(remaining) {
                try await backend.respond(to: transcript, tools: tools)
            }
        } catch is ToolCallTimedOut {
            throw MLXAppIntentsError.backendFailed(detail: "total timeout exceeded")
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MLXAppIntentsError {
            throw error
        } catch {
            throw MLXAppIntentsError.backendFailed(detail: "\(error)")
        }
    }

    // MARK: - One tool call: approval, timeout, one repair, feed-back

    private struct ToolOutcome: Sendable {
        let resultJSON: String
        let executed: ExecutedToolCall?
    }

    private func execute(call: ToolCall) async throws -> ToolOutcome {
        guard let risk = await registry.risk(of: call.name) else {
            return ToolOutcome(resultJSON: errorJSON("unknown tool '\(call.name)'"), executed: nil)
        }

        if risk.requiresApproval {
            guard let approver else {
                throw MLXAppIntentsError.approvalRequired(tool: call.name)
            }
            let approved = await approver(call, risk)
            guard approved else {
                throw MLXAppIntentsError.approvalDenied(tool: call.name)
            }
        }

        let registry = self.registry
        let started = ContinuousClock.now
        do {
            let result = try await withTimeout(policy.toolTimeout) {
                try await registry.dispatch(name: call.name, argumentsJSON: call.argumentsJSON)
            }
            return ToolOutcome(
                resultJSON: result,
                executed: ExecutedToolCall(
                    call: call, resultJSON: result,
                    duration: ContinuousClock.now - started))
        } catch is ToolCallTimedOut {
            return ToolOutcome(
                resultJSON: errorJSON("tool '\(call.name)' timed out"),
                executed: nil)
        } catch let error as MLXAppIntentsError {
            switch error {
            case .invalidArguments:
                // ONE bounded repair: extract the first {...} object and
                // re-decode. If the repair succeeds, the call executes;
                // if not, the failure is fed back — never thrown.
                if let repaired = extractJSONObject(from: call.argumentsJSON),
                   repaired != call.argumentsJSON,
                   let result = try? await dispatchRepaired(
                       registry: registry, call: call, argumentsJSON: repaired,
                       started: started)
                {
                    return result
                }
                return ToolOutcome(resultJSON: errorJSON(error.description), executed: nil)
            case .toolFailed, .toolTimeout:
                return ToolOutcome(resultJSON: errorJSON(error.description), executed: nil)
            default:
                throw error
            }
        }
    }

    private func dispatchRepaired(
        registry: IntentRegistry, call: ToolCall, argumentsJSON: String, started: ContinuousClock.Instant
    ) async throws -> ToolOutcome {
        let result = try await withTimeout(policy.toolTimeout) {
            try await registry.dispatch(name: call.name, argumentsJSON: argumentsJSON)
        }
        return ToolOutcome(
            resultJSON: result,
            executed: ExecutedToolCall(
                call: call, resultJSON: result,
                duration: ContinuousClock.now - started))
    }

    private func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end
        else { return nil }
        return String(text[start...end])
    }

    private func errorJSON(_ message: String) -> String {
        // Hand-built, not encoded from a dictionary, so this can never
        // itself fail to encode. Quotes in the message are escaped.
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"error\":\"\(escaped)\"}"
    }

    // MARK: - Timeout race (TypedStreamFM pattern)

    /// Runs `operation`, cancelling it if `timeout` elapses first. The
    /// loser is always cancelled — timeouts never orphan work.
    /// Throws the internal `ToolCallTimedOut` marker; each call site
    /// maps it to its public error (tool timeout in `execute`, total
    /// timeout in `nextTurn`).
    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ToolCallTimedOut()
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }
}
