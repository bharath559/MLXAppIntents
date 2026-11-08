/// Errors thrown by MLXAppIntents.
///
/// All cases carry plain `String` / `Int` payloads so the enum stays
/// `Equatable` — tests can assert the exact error, not just its type.
/// A failed or timed-out tool result is never presented as success: the
/// runner feeds those failures back to the model as error tool-results
/// (see `MLXAgentRunner`), and only approval, budget, backend, and
/// cancellation failures escape `run(prompt:)` as throws.
public enum MLXAppIntentsError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownTool(name: String)
    case invalidArguments(tool: String, detail: String)
    case toolFailed(tool: String, detail: String)
    case approvalRequired(tool: String)
    case approvalDenied(tool: String)
    case maxTurnsExceeded(turns: Int)
    case toolTimeout(tool: String)
    case invalidToolCall(detail: String)
    case backendFailed(detail: String)

    public var description: String {
        switch self {
        case .unknownTool(let name):
            return "unknown tool '\(name)'"
        case .invalidArguments(let tool, let detail):
            return "invalid arguments for tool '\(tool)': \(detail)"
        case .toolFailed(let tool, let detail):
            return "tool '\(tool)' failed: \(detail)"
        case .approvalRequired(let tool):
            return "tool '\(tool)' requires approval, but no approver was provided"
        case .approvalDenied(let tool):
            return "tool '\(tool)' was denied by the approver"
        case .maxTurnsExceeded(let turns):
            return "agent exceeded max turns (\(turns))"
        case .toolTimeout(let tool):
            return "tool '\(tool)' timed out"
        case .invalidToolCall(let detail):
            return "invalid tool call: \(detail)"
        case .backendFailed(let detail):
            return "model backend failed: \(detail)"
        }
    }
}
