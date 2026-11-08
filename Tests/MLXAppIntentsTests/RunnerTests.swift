import Testing
import Foundation
@testable import MLXAppIntents
import MLXAppIntentsTestKit

/// A tool that never returns (until cancelled). Used by the timeout test:
/// the runner must feed the timeout back to the model, not hang.
private struct HangingIntent: IntentTool {
    struct Arguments: Codable, Sendable {}
    struct ResultValue: Codable, Sendable, Equatable { let done: Bool }

    static let toolName = "HangingTool"
    static let toolDescription = "A tool that hangs, for timeout tests."
    static let toolParameters = ToolParameters()
    static let risk: IntentRisk = .readOnly

    init(arguments: Arguments) {}
    func run(arguments: Arguments) async throws -> ResultValue {
        try await Task.sleep(for: .seconds(30))
        return ResultValue(done: true)
    }
}

private func makeRegistry() async throws -> IntentRegistry {
    let registry = IntentRegistry()
    try await registry.register(LookupRecipeIntent.self)
    try await registry.register(AddToShoppingListIntent.self)
    try await registry.register(DeleteShoppingListIntent.self)
    try await registry.register(HangingIntent.self)
    return registry
}

@Suite("Runner")
struct RunnerTests {
    @Test("scripted model calls one tool, then answers")
    func singleToolThenAnswer() async throws {
        let registry = try await makeRegistry()
        let backend = ScriptedModel.calling(
            tool: "LookupRecipe",
            argumentsJSON: #"{"ingredient":"tomatoes"}"#,
            thenAnswering: "Make Tomato Soup.")
        let runner = MLXAgentRunner(registry: registry, backend: backend)
        let result = try await runner.run(prompt: "What can I cook with tomatoes?")
        #expect(result.finalText == "Make Tomato Soup.")
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls[0].call.name == "LookupRecipe")
        #expect(result.toolCalls[0].resultJSON.contains("Tomato Soup"))
        #expect(result.turns == 2)
    }

    @Test("multi-turn: two tools, then an answer")
    func twoTools() async throws {
        let registry = try await makeRegistry()
        let backend = ScriptedModel(turns: [
            .toolCall(ToolCall(id: "c1", name: "LookupRecipe", argumentsJSON: #"{"ingredient":"eggs"}"#)),
            .toolCall(ToolCall(id: "c2", name: "AddToShoppingList", argumentsJSON: #"{"item":"eggs"}"#)),
            .text("Shakshuka — eggs added to your list."),
        ])
        let runner = MLXAgentRunner(registry: registry, backend: backend)
        let result = try await runner.run(prompt: "Cook with eggs and shop for them.")
        #expect(result.toolCalls.count == 2)
        #expect(result.toolCalls.map(\.call.name) == ["LookupRecipe", "AddToShoppingList"])
        #expect(result.finalText.contains("Shakshuka"))
        #expect(result.turns == 3)
    }

    @Test("unknown tool is fed back and the model retries with a real tool")
    func unknownToolFedBack() async throws {
        let registry = try await makeRegistry()
        let backend = ScriptedModel(turns: [
            .toolCall(ToolCall(id: "c1", name: "NoSuchTool", argumentsJSON: "{}")),
            .toolCall(ToolCall(id: "c2", name: "LookupRecipe", argumentsJSON: #"{"ingredient":"tomatoes"}"#)),
            .text("Tomato Soup it is."),
        ])
        let runner = MLXAgentRunner(registry: registry, backend: backend)
        let result = try await runner.run(prompt: "What can I cook?")
        #expect(result.finalText == "Tomato Soup it is.")
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls[0].call.name == "LookupRecipe")
    }

    @Test("destructive tool with no approver throws approvalRequired and never executes")
    func approvalRequired() async throws {
        let registry = try await makeRegistry()
        let backend = ScriptedModel.calling(
            tool: "DeleteShoppingList",
            argumentsJSON: #"{"item":"eggs"}"#,
            thenAnswering: "Deleted.")
        let runner = MLXAgentRunner(registry: registry, backend: backend)
        await #expect(throws: MLXAppIntentsError.approvalRequired(tool: "DeleteShoppingList")) {
            try await runner.run(prompt: "Delete eggs.")
        }
    }

    @Test("approver returning false throws approvalDenied")
    func approvalDenied() async throws {
        let registry = try await makeRegistry()
        let backend = ScriptedModel.calling(
            tool: "DeleteShoppingList",
            argumentsJSON: #"{"item":"eggs"}"#,
            thenAnswering: "Deleted.")
        let runner = MLXAgentRunner(registry: registry, backend: backend) { _, _ in false }
        await #expect(throws: MLXAppIntentsError.approvalDenied(tool: "DeleteShoppingList")) {
            try await runner.run(prompt: "Delete eggs.")
        }
    }

    @Test("approver returning true executes the destructive tool")
    func approvalGranted() async throws {
        let registry = try await makeRegistry()
        let backend = ScriptedModel.calling(
            tool: "DeleteShoppingList",
            argumentsJSON: #"{"item":"eggs"}"#,
            thenAnswering: "Deleted eggs.")
        let runner = MLXAgentRunner(registry: registry, backend: backend) { _, risk in
            risk == .destructive
        }
        let result = try await runner.run(prompt: "Delete eggs.")
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls[0].resultJSON.contains("true"))
        #expect(result.finalText == "Deleted eggs.")
    }

    @Test("model that keeps calling tools hits maxTurnsExceeded")
    func maxTurnsExceeded() async throws {
        let registry = try await makeRegistry()
        let backend = ScriptedModel.repeatingCall(
            tool: "LookupRecipe", argumentsJSON: #"{"ingredient":"tomatoes"}"#)
        let runner = MLXAgentRunner(
            registry: registry, backend: backend,
            policy: MLXAgentRunner.RunnerPolicy(maxTurns: 3))
        await #expect(throws: MLXAppIntentsError.maxTurnsExceeded(turns: 3)) {
            try await runner.run(prompt: "Keep cooking.")
        }
    }

    @Test("a hanging tool times out, is fed back, and the model still answers")
    func toolTimeoutFedBack() async throws {
        let registry = try await makeRegistry()
        let backend = ScriptedModel(turns: [
            .toolCall(ToolCall(id: "c1", name: "HangingTool", argumentsJSON: "{}")),
            .text("That tool timed out, but here is a recipe anyway."),
        ])
        let runner = MLXAgentRunner(
            registry: registry, backend: backend,
            policy: MLXAgentRunner.RunnerPolicy(toolTimeout: .milliseconds(50)))
        let result = try await runner.run(prompt: "Use the hanging tool.")
        #expect(result.finalText == "That tool timed out, but here is a recipe anyway.")
        #expect(result.toolCalls.isEmpty)
    }

    @Test("cancelling the run propagates CancellationError")
    func cancellationPropagates() async throws {
        let registry = try await makeRegistry()
        let runner = MLXAgentRunner(registry: registry, backend: ScriptedModel.hanging())
        let task = Task { try await runner.run(prompt: "Hello?") }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("invalid arguments get one bounded repair: JSON extracted from surrounding text")
    func invalidArgumentsRepaired() async throws {
        let registry = try await makeRegistry()
        let backend = ScriptedModel.calling(
            tool: "LookupRecipe",
            argumentsJSON: #"Here is the call: {"ingredient": "tomatoes"} thanks"#,
            thenAnswering: "Tomato Soup.")
        let runner = MLXAgentRunner(registry: registry, backend: backend)
        let result = try await runner.run(prompt: "What can I cook with tomatoes?")
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls[0].resultJSON.contains("Tomato Soup"))
        #expect(result.finalText == "Tomato Soup.")
    }

    @Test("unrepairable arguments are fed back and the model still answers")
    func invalidArgumentsFedBack() async throws {
        let registry = try await makeRegistry()
        let backend = ScriptedModel(turns: [
            .toolCall(ToolCall(id: "c1", name: "LookupRecipe", argumentsJSON: "not json at all")),
            .text("I could not parse that, but here is a salad."),
        ])
        let runner = MLXAgentRunner(registry: registry, backend: backend)
        let result = try await runner.run(prompt: "What can I cook?")
        #expect(result.finalText == "I could not parse that, but here is a salad.")
        #expect(result.toolCalls.isEmpty)
    }

    @Test("a failing backend surfaces as backendFailed")
    func backendFailure() async throws {
        let registry = try await makeRegistry()
        let runner = MLXAgentRunner(registry: registry, backend: ScriptedModel.failing("boom"))
        await #expect(throws: MLXAppIntentsError.backendFailed(detail: "boom")) {
            try await runner.run(prompt: "Hello?")
        }
    }
}
