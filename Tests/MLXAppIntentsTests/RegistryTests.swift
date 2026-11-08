import Testing
import Foundation
@testable import MLXAppIntents
import MLXAppIntentsTestKit

@Suite("Registry")
struct RegistryTests {
    @Test("register then dispatch round-trips arguments and result")
    func roundTrip() async throws {
        let registry = IntentRegistry()
        try await registry.register(LookupRecipeIntent.self)
        let json = try await registry.dispatch(
            name: "LookupRecipe", argumentsJSON: #"{"ingredient":"tomatoes"}"#)
        let result = try JSONDecoder().decode(
            LookupRecipeIntent.ResultValue.self, from: Data(json.utf8))
        #expect(result.recipes == ["Tomato Soup", "Bruschetta", "Shakshuka"])
    }

    @Test("duplicate registration throws")
    func duplicateThrows() async throws {
        let registry = IntentRegistry()
        try await registry.register(LookupRecipeIntent.self)
        await #expect(throws: MLXAppIntentsError.invalidToolCall(
            detail: "duplicate tool name 'LookupRecipe'")) {
            try await registry.register(LookupRecipeIntent.self)
        }
    }

    @Test("dispatch to an unknown tool throws unknownTool")
    func unknownToolThrows() async throws {
        let registry = IntentRegistry()
        await #expect(throws: MLXAppIntentsError.unknownTool(name: "Nope")) {
            try await registry.dispatch(name: "Nope", argumentsJSON: "{}")
        }
    }

    @Test("argument JSON that does not match the schema throws invalidArguments")
    func invalidJSONThrows() async throws {
        let registry = IntentRegistry()
        try await registry.register(LookupRecipeIntent.self)
        // `ingredient` is required; an empty object does not decode.
        await #expect(throws: MLXAppIntentsError.self) {
            try await registry.dispatch(name: "LookupRecipe", argumentsJSON: "{}")
        }
        do {
            _ = try await registry.dispatch(name: "LookupRecipe", argumentsJSON: "{}")
            Issue.record("expected invalidArguments, dispatch succeeded")
        } catch let error as MLXAppIntentsError {
            guard case .invalidArguments(let tool, _) = error else {
                Issue.record("expected invalidArguments, got \(error)")
                return
            }
            #expect(tool == "LookupRecipe")
        }
    }

    @Test("schema validate catches an empty name and a required key with no property")
    func schemaValidation() throws {
        let emptyName = ToolDefinition(
            name: "", description: "x", parameters: ToolParameters())
        #expect(throws: MLXAppIntentsError.self) { try emptyName.validate() }

        let missingRequired = ToolDefinition(
            name: "T", description: "x",
            parameters: ToolParameters(properties: [:], required: ["nope"]))
        #expect(throws: MLXAppIntentsError.self) { try missingRequired.validate() }

        let good = LookupRecipeIntent.toolDefinition
        try good.validate()
        #expect(try good.jsonString().contains("\"LookupRecipe\""))
    }

    @Test("toolDefinitions lists registered tools, sorted by name")
    func listsTools() async throws {
        let registry = IntentRegistry()
        try await registry.register(AddToShoppingListIntent.self)
        try await registry.register(LookupRecipeIntent.self)
        let names = await registry.toolDefinitions().map(\.name)
        #expect(names == ["AddToShoppingList", "LookupRecipe"])
        #expect(await registry.risk(of: "DeleteShoppingList") == nil)
    }
}
