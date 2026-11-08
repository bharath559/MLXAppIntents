// UNVERIFIED / Xcode-only — not a SwiftPM target, not compiled on Linux.
// A real `BridgedIntent` example for an Xcode app target. Needs the M0
// check in the README: whether the protocol-extension `perform()` in
// BridgedIntent.swift satisfies `AppIntent`, and the exact
// `LocalizedStringResource` / `IntentDescription` shapes.
//
// The intent's `@Parameter` is the Siri / Shortcuts surface; `arguments`
// is the same input as a Codable struct for the MLX runner; `run` is the
// shared logic. Never load an MLX model inside `perform()` — the runner
// lives in the app process; `perform()` runs in the background (~30s).

#if canImport(AppIntents)
import AppIntents
import MLXAppIntents

struct FindRecipeIntent: BridgedIntent {
    struct Arguments: Codable, Sendable {
        let ingredient: String
    }

    struct ResultValue: Codable, Sendable {
        let recipes: [String]
    }

    static let toolName = "FindRecipe"
    static let toolDescription = "Find recipes that use a given ingredient."
    static let toolParameters = ToolParameters(
        properties: ["ingredient": ToolProperty(type: "string", description: "An ingredient on hand.")],
        required: ["ingredient"])
    static let risk: IntentRisk = .readOnly

    @Parameter(title: "Ingredient")
    var ingredient: String

    var arguments: Arguments { Arguments(ingredient: ingredient) }

    init() {}

    init(arguments: Arguments) {
        self.ingredient = arguments.ingredient
    }

    func run(arguments: Arguments) async throws -> ResultValue {
        // Real implementation: query the app's on-device recipe store
        // (or a tiny Core AI embedder) — not an LLM load in perform().
        ResultValue(recipes: ["Tomato Soup", "Bruschetta", "Shakshuka"])
    }
}
#endif
