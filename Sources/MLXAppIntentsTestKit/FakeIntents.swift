import MLXAppIntents

/// Fake intents for tests and the example app. Canned, deterministic,
/// no I/O. Their schemas are real `ToolParameters` matching their
/// `Arguments` keys — the registry dispatch round-trip tests exercise them.
public struct LookupRecipeIntent: IntentTool {
    public struct Arguments: Codable, Sendable {
        public let ingredient: String
        public init(ingredient: String) { self.ingredient = ingredient }
    }

    public struct ResultValue: Codable, Sendable, Equatable {
        public let recipes: [String]
        public init(recipes: [String]) { self.recipes = recipes }
    }

    public static let toolName = "LookupRecipe"
    public static let toolDescription = "Find recipes that use a given ingredient."
    public static let toolParameters = ToolParameters(
        properties: ["ingredient": ToolProperty(type: "string", description: "An ingredient on hand.")],
        required: ["ingredient"])
    public static let risk: IntentRisk = .readOnly

    private let arguments: Arguments
    public init(arguments: Arguments) { self.arguments = arguments }

    public func run(arguments: Arguments) async throws -> ResultValue {
        switch arguments.ingredient.lowercased() {
        case "tomatoes":
            return ResultValue(recipes: ["Tomato Soup", "Bruschetta", "Shakshuka"])
        case "eggs":
            return ResultValue(recipes: ["Shakshuka", "Frittata"])
        default:
            return ResultValue(recipes: ["Garden Salad", "Stir Fry"])
        }
    }
}

public struct AddToShoppingListIntent: IntentTool {
    public struct Arguments: Codable, Sendable {
        public let item: String
        public init(item: String) { self.item = item }
    }

    public struct ResultValue: Codable, Sendable, Equatable {
        public let added: Bool
        public init(added: Bool) { self.added = added }
    }

    public static let toolName = "AddToShoppingList"
    public static let toolDescription = "Add an item to the shopping list."
    public static let toolParameters = ToolParameters(
        properties: ["item": ToolProperty(type: "string", description: "The item to add.")],
        required: ["item"])
    /// Reversible (undoable), so tests and the example can run it without
    /// an approver. Nothing money-moving is ever `.reversible` by default.
    public static let risk: IntentRisk = .reversible

    private let arguments: Arguments
    public init(arguments: Arguments) { self.arguments = arguments }

    public func run(arguments: Arguments) async throws -> ResultValue {
        guard !arguments.item.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MLXAppIntentsError.invalidArguments(
                tool: Self.toolName, detail: "item must not be empty")
        }
        return ResultValue(added: true)
    }
}

public struct DeleteShoppingListIntent: IntentTool {
    public struct Arguments: Codable, Sendable {
        public let item: String
        public init(item: String) { self.item = item }
    }

    public struct ResultValue: Codable, Sendable, Equatable {
        public let deleted: Bool
        public init(deleted: Bool) { self.deleted = deleted }
    }

    public static let toolName = "DeleteShoppingList"
    public static let toolDescription = "Delete an item from the shopping list."
    public static let toolParameters = ToolParameters(
        properties: ["item": ToolProperty(type: "string", description: "The item to delete.")],
        required: ["item"])
    /// Destructive: the runner refuses to execute this without an approver
    /// returning `true`. Used by the approval tests.
    public static let risk: IntentRisk = .destructive

    private let arguments: Arguments
    public init(arguments: Arguments) { self.arguments = arguments }

    public func run(arguments: Arguments) async throws -> ResultValue {
        ResultValue(deleted: true)
    }
}
