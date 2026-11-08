import Foundation
import MLXAppIntents
import MLXAppIntentsTestKit

/// `swift run mlx-app-intents-example`
///
/// Deterministic demo of the v0.1 runtime: a scripted model (standing in
/// for a real MLX backend — see docs/mlx-adapter.md) calls the fake
/// `LookupRecipeIntent`, gets canned recipes, and answers. No network,
/// no model weights, no Apple frameworks.
@main
struct MLXAppIntentsExample {
    static func main() async throws {
        let registry = IntentRegistry()
        try await registry.register(LookupRecipeIntent.self)
        try await registry.register(AddToShoppingListIntent.self)

        let backend = ScriptedModel(turns: [
            .toolCall(ToolCall(
                id: "call-1", name: "LookupRecipe",
                argumentsJSON: #"{"ingredient":"tomatoes"}"#)),
            .toolCall(ToolCall(
                id: "call-2", name: "AddToShoppingList",
                argumentsJSON: #"{"item":"tomatoes"}"#)),
            .text("You can make Tomato Soup, Bruschetta, or Shakshuka — tomatoes are on your shopping list."),
        ])
        let runner = MLXAgentRunner(registry: registry, backend: backend)

        let result = try await runner.run(prompt: "What can I cook with tomatoes?")
        print("Answer: \(result.finalText)")
        print("Turns: \(result.turns)")
        for call in result.toolCalls {
            print("Tool: \(call.call.name) -> \(call.resultJSON)")
        }
    }
}
