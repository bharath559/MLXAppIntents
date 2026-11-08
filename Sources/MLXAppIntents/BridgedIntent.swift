// UNVERIFIED — needs an Xcode 27 check (see README, M0 checklist).
// This file is fully inside `#if canImport(AppIntents)` and contributes
// nothing to the Linux build. Do not claim the shapes below compile until
// the M0 pass confirms them on a Mac:
//
// 1. Whether a protocol-extension `perform()` satisfies `AppIntent`'s
//    requirement for a conforming struct (an extension default may not
//    satisfy an opaque `some IntentResult` requirement the way a
//    concrete implementation does).
// 2. `LocalizedStringResource(stringLiteral:)` as used for `title`.
// 3. Whether `IntentDescription(toolDescription)` is the right
//    initializer shape for the `description` property.
// 4. Whether `.result(dialog:)` accepts the `"\(result)"` string for a
//    Codable `ResultValue` (a real implementation should format the
//    result into a user-facing dialog, not interpolate the struct).
//
// The platform-neutral contract lives in `IntentTool`; this file is only
// the thin App Intents projection of it. The runner must NOT load an LLM
// inside `perform()`: `perform()` runs in the background (~30s) and the
// runner lives in the app process. See README, "Routing rule".

#if canImport(AppIntents)
import AppIntents

/// An `AppIntent` that is also a bridged tool for the MLX agent runner.
///
/// The intent's `@Parameter` properties are the Siri / Shortcuts surface;
/// `arguments` is the same inputs as a Codable struct, and `run` is the
/// logic both surfaces share. `perform()` delegates to `run` so the
/// intent and the model tool can never drift apart.
public protocol BridgedIntent: AppIntent, IntentTool {
    /// The Codable arguments for this run, built from the intent's
    /// `@Parameter` properties. The conforming type provides this —
    /// a macro (v0.2) will generate it; in v0.1 it is written by hand.
    var arguments: Arguments { get }
}

extension BridgedIntent {
    public static var title: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: toolName)
    }

    public static var description: IntentDescription? {
        IntentDescription(toolDescription)
    }

    public func perform() async throws -> some IntentResult {
        let result = try await run(arguments: arguments)
        return .result(dialog: "\(result)")
    }
}
#endif
