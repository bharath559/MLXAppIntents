# MLXAppIntents

A runtime that lets an on-device MLX model call your app's intents as
tools — with routing, validated structured arguments, and risk-gating.
Runtime first, macro later.

**Status:** v0.1 — core runtime, registry, runner, scripted tests, and a
deterministic example are implemented and green on Linux (see below).
The Apple-only `BridgedIntent` layer and the real MLX adapter are
written but **UNVERIFIED** — the M0 checklist must be confirmed in
Xcode 27 before shipping.

## What it is / is not

- It **is** a runtime: `IntentTool` (a Codable arguments/result seam),
  `IntentRegistry` (explicit, actor-isolated, type-erased dispatch),
  and `MLXAgentRunner` (the model -> tool -> model loop with approval,
  timeouts, bounded repair, and budgets).
- It **is not** a Siri replacement. Siri orchestrates via
  `@AppIntent(.tool)`; this package does not replace Siri's planner and
  cannot call another app's intents.
- It **is not** an MLX -> Foundation Models bridge. Apple already ships
  that: `MLXFoundationModels` in mlx-swift-lm bridges MLX models into
  `FoundationModels.LanguageModel`.
- It **is not** a macro package (yet). v0.1 conformance is written by
  hand; see "Macro later".

## Architecture

```
User prompt
  -> MLXAgentRunner (actor: one owner, one session)
    -> ModelBackend.respond(transcript, tools)   // MLX ChatSession, or scripted fake
      -> .text => final answer
      -> .toolCall => IntentRegistry.dispatch(name, argumentsJSON)
        -> IntentTool.init(arguments:) + run(arguments:)
        -> ResultValue encoded to JSON, fed back to the model
    -> approval gate, per-tool timeout, one bounded repair, budgets
  -> AgentResult { finalText, toolCalls, turns }
```

One schema, every runtime: a tool's `ToolDefinition` (name, description,
JSON Schema parameters) is the single definition the MLX `ToolSpec`
projection, the Foundation Models `Tool` projection, and the registry
all read.

## Routing rule

- **Intent extension (`perform()`, background, ~30s):** tiny Core AI
  model only (classifier / embedder / ranker, ANE, <200ms). Never load
  an LLM there.
- **App process:** Foundation Models system model first (no load,
  `@Generable` + `Tool`), MLX small model second (Qwen3 0.6–4B 4-bit
  via `MLXLanguageModel` / `ChatSession`, lazy load).
- **Legacy Core ML:** shim only. New custom models target Core AI.

## Quick start

```swift
import MLXAppIntents
import MLXAppIntentsTestKit

let registry = IntentRegistry()
try await registry.register(LookupRecipeIntent.self)
try await registry.register(AddToShoppingListIntent.self)

// `backend` is any ModelBackend — a real MLX ChatSession adapter
// (docs/mlx-adapter.md) or ScriptedModel for tests.
let runner = MLXAgentRunner(
    registry: registry,
    backend: ScriptedModel.calling(
        tool: "LookupRecipe",
        argumentsJSON: #"{"ingredient":"tomatoes"}"#,
        thenAnswering: "Make Tomato Soup."),
    approver: { _, risk in risk != .destructive }  // optional; destructive tools need one
)

let result = try await runner.run(prompt: "What can I cook with tomatoes?")
print(result.finalText)           // "Make Tomato Soup."
print(result.toolCalls[0].resultJSON)  // {"recipes":["Tomato Soup", ...]}
```

Run the deterministic example (no network, no weights):

```
swift run mlx-app-intents-example
```

## Design guarantees

- **Approval:** `.destructive` tools never execute without an approver
  returning `true`. No approver -> `approvalRequired`; approver says
  no -> `approvalDenied`. Money-moving / destructive actions go through
  this gate; `.readOnly` runs free, `.reversible` runs free by default.
- **Failures are fed back, not hidden:** unknown tool, invalid
  arguments (after one bounded repair that extracts the first `{...}`),
  tool failure, and tool timeout all become error tool-results in the
  transcript so the model can retry. A failed result is never presented
  as success.
- **Bounded:** `maxTurns` (default 8), `maxToolCalls` (default 16),
  per-tool timeout (default 10s), total timeout (default 60s).
  Timeouts are cancellation races (TypedStreamFM pattern) — timed-out
  work is cancelled, never orphaned. They require cooperative
  cancellation from the tool / backend.
- **Cancellation is not an error case:** cancelling the caller
  propagates `CancellationError`.

## Layout

```
Sources/MLXAppIntents/        # Errors, ToolSchema, IntentTool, IntentRegistry,
                              # ModelBackend, MLXAgentRunner, BridgedIntent (Apple-only)
Sources/MLXAppIntentsTestKit/ # ScriptedModel, FakeIntents (Lookup/Add/Delete)
Sources/mlx-app-intents-example/ # deterministic CLI demo
Tests/MLXAppIntentsTests/     # RegistryTests, RunnerTests — swift-testing
Examples/AppIntents/          # Xcode-only BridgedIntent example (UNVERIFIED)
docs/mlx-adapter.md           # ChatSession -> ModelBackend wiring sketch (UNVERIFIED)
```

## Macro later

v0.1 is manual on purpose. A `@BridgedIntent` macro would generate the
schema literal, `init(arguments:)`, and the `perform()` forwarding from
an intent's `@Parameter` declarations — but Swift macros are
additive-only, run sandboxed, and cannot see types: the macro sees
syntax text, not whether a parameter type is Codable or whether the
generated schema matches the real parameters. That verification has to
be a runtime test or a lint regardless. So the order is: prove the
runtime and the manual shape first (this package), then add
`MLXAppIntentsMacros` (declaration target + `.macro` plugin target,
following the `MLXHuggingFace` / `MLXHuggingFaceMacros` precedent in
mlx-swift-lm) in v0.2 to remove the boilerplate.

## M0 checklist — confirm in Xcode 27 before shipping

- [ ] `BridgedIntent` extension `perform()` satisfies `AppIntent` for a
      conforming struct (opaque `some IntentResult` in an extension).
- [ ] `LocalizedStringResource(stringLiteral:)` / `IntentDescription`
      shapes in `BridgedIntent.swift`.
- [ ] `Examples/AppIntents/RecipeIntents.swift` compiles in an Xcode app target.
- [ ] `docs/mlx-adapter.md`: `ChatSession` `ToolSpec` / `toolDispatch`
      signatures against mlx-swift-lm 3.32.x; `.toolCall` streaming event
      shape; `Generation.rejectedToolCall` mapping.
- [ ] Real on-device run: Qwen3-0.6B or Gemma3-1B 4-bit via the adapter,
      one tool call end-to-end, in the app process (never in `perform()`).

## Verified / not verified

- **Verified here (Linux, Swift 6.4.1):** `swift test` green — 18 tests
  in 2 suites (Registry: 6, Runner: 12): registry dispatch round-trips,
  duplicate/unknown/invalid-argument handling, runner loop, approval gate, max-turns budget, tool timeout
  feed-back, repair, cancellation, backend failure. `swift run
  mlx-app-intents-example` prints the demo answer.
- **Not verified:** everything Apple-only (`BridgedIntent`,
  `Examples/AppIntents/RecipeIntents.swift`) and the MLX adapter
  sketch (`docs/mlx-adapter.md`). Those need the M0 Xcode pass on
  Bharath's Mac — same pattern as TypedStreamFM's M0 checklist.
