# MLX adapter — UNVERIFIED wiring sketch

> **Status: UNVERIFIED.** This document is a wiring sketch only. It has
> not been compiled against mlx-swift-lm 3.32.x, and no mlx-swift-lm
> dependency is in `Package.swift` in v0.1. Confirm every signature in
> Xcode 27 against the mlx-swift-lm release you pin before shipping.

## Goal

Adapt an MLX `ChatSession` to the `ModelBackend` protocol, so
`MLXAgentRunner` can drive a real on-device model:

```swift
// Sketch — signatures to confirm against mlx-swift-lm 3.32.x.
import MLXLLM
import MLXLMCommon

public final class MLXChatBackend: ModelBackend, @unchecked Sendable {
    private let session: ChatSession

    public init(container: ModelContainer) {
        // Confirm: ChatSession's tool initializer shape in 3.32.x.
        // Known shape (3.31.x, from community references):
        //   ChatSession(container, instructions:tools:toolDispatch:)
        // where `tools: [ToolSpec]` and `toolDispatch` receives a
        // `ToolCall` and returns a `String` result.
        self.session = ChatSession(container)
    }

    public func respond(
        to transcript: [AgentMessage], tools: [ToolDefinition]
    ) async throws -> ModelTurn {
        // 1. Project each ToolDefinition to a ToolSpec (name, description,
        //    JSON-schema parameters). Confirm ToolSpec's initializer and
        //    whether it takes the schema as a JSON string or a dictionary.
        // 2. Drive the session's streaming generation; map the stream's
        //    `.toolCall` event to `ModelTurn.toolCall` and accumulated
        //    text to `ModelTurn.text`.
        // 3. Do NOT execute tools inside the backend: the runner owns
        //    dispatch, approval, timeouts, and repair. The backend only
        //    returns the next turn.
        fatalError("unimplemented — see M0 checklist in README")
    }
}
```

## Mapping notes (to confirm)

- **ToolSpec projection:** `ToolDefinition.parameters` is already a JSON
  Schema object (`type: "object"`, `properties`, `required`). The
  adapter's job is format conversion, not schema invention.
- **Dialects:** Gemma and Qwen emit tool calls in different formats;
  mlx-swift-lm's `ToolCallProcessor` / model-specific parsers do the
  parsing. If a model family cannot emit a parseable tool call, the
  adapter should surface that as `backendFailed`, not silently fall
  back to free text — the runner's repair loop only repairs *arguments*,
  not a missing tool call.
- **Multi-turn:** the runner replays tool results through the transcript
  on every turn. A stateful `ChatSession` keeps its own history; the
  adapter must decide whether to feed the runner's transcript back into
  the session or trust the session's internal history, and document the
  choice. Feeding both risks double-counting tool results.
- **Rejected tool calls:** `Generation.rejectedToolCall` exists in
  mlx-swift-lm. The adapter should map a rejection to a fed-back error
  tool-result (same as an unknown tool), not a throw.
- **Model choice for the example:** Qwen3-0.6B / 1.7B 4-bit or
  Gemma3-1B 4-bit via `LLMRegistry` (`mlx-community` on Hugging Face).
  A 4B model is the ceiling for a phone; never load it inside an
  `AppIntent.perform()` — the runner runs in the app process only.
- **Alternative backend:** `MLXFoundationModels` (`MLXLanguageModel`
  behind a `LanguageModelSession`) already bridges MLX to Foundation
  Models with guided generation and tool calling. If that path proves
  more reliable than raw `ChatSession` tool calling, adapt
  `LanguageModelSession` to `ModelBackend` instead — the runner does
  not care which backend produces the turn.

## What v0.1 deliberately does not do

- No mlx-swift-lm dependency, so the package stays Linux-testable.
- No model loading, downloading, or weight management.
- No `ChatSession` code claiming to compile.
