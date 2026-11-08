/// Risk tier of an intent. The runner's approval policy is driven by this,
/// not by the tool's name or by prompt text.
///
/// - `readOnly`: no state changes. Runs free.
/// - `reversible`: state changes that can be undone (add to a list, save a
///   draft). Runs free by default; a host may still require approval via its
///   own approver policy, but the runner does not force it.
/// - `destructive`: state changes that cannot be undone, or money-moving
///   actions (delete, file a dispute, freeze a card, send a payment).
///   The runner refuses to execute these without an approver, and refuses
///   when the approver returns `false`. See `MLXAgentRunner`.
public enum IntentRisk: String, Codable, Sendable, Equatable {
    case readOnly
    case reversible
    case destructive

    /// Only `.destructive` forces approval in the runner.
    public var requiresApproval: Bool {
        self == .destructive
    }
}

/// Platform-neutral core protocol — deliberately NOT `AppIntent`, so the
/// runtime, registry, and runner compile and test on Linux with zero model
/// weights and zero Apple frameworks.
///
/// The `Arguments` / `ResultValue` Codable seam is the whole bridge:
/// - Intent -> model: `toolParameters` (JSON Schema) describes `Arguments`.
/// - Model -> intent: a tool-call JSON string decodes to `Arguments`,
///   the intent is constructed with `init(arguments:)`, `run` executes,
///   and `ResultValue` encodes back to a JSON string for the model.
///
/// An `AppIntent` wrapper over this protocol is `BridgedIntent`
/// (Apple-only, `#if canImport(AppIntents)`). Keep the logic here.
public protocol IntentTool: Sendable {
    associatedtype Arguments: Codable & Sendable
    associatedtype ResultValue: Codable & Sendable

    static var toolName: String { get }
    static var toolDescription: String { get }
    static var toolParameters: ToolParameters { get }
    static var risk: IntentRisk { get }

    init(arguments: Arguments)
    func run(arguments: Arguments) async throws -> ResultValue
}

extension IntentTool {
    /// The `ToolDefinition` the model sees, derived from the static metadata.
    public static var toolDefinition: ToolDefinition {
        ToolDefinition(name: toolName, description: toolDescription, parameters: toolParameters)
    }
}
