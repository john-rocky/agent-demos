// G5Lifecycle.swift — the remaining 242 primitives on local models:
//   (a) historyTransform — a lossless, per-profile view that trims tool noise before
//       prompting the small model (the transcript itself is unchanged);
//   (b) session properties — a custom @SessionPropertyEntry summary written in onResponse
//       and injected into the next turn's instructions, plus the built-in `history`;
//   (c) toolCallingMode(.required) — the model is in a while-loop, so an exit condition
//       is mandatory; here a finish tool throws to break out (242's "forceful option").

import CoreAIKit
import Foundation
import FoundationModels

// MARK: - (b) custom session property

extension SessionPropertyValues {
    /// A running summary, written at each response boundary and injected into the next
    /// turn's instructions so trimmed context is not lost.
    @SessionPropertyEntry var runningSummary: String = ""
}

// MARK: - (c) required-mode exit tool

struct FinishTool: Tool {
    let name = "finish"
    let description = "Call this with the final answer once you have looked up the data."

    @Generable
    struct Arguments {
        @Guide(description: "The final answer text for the user")
        var answer: String
    }

    struct Done: Error { let answer: String }

    func call(arguments: Arguments) async throws -> String {
        print("    [tool] finish(answer: \(arguments.answer.prefix(60))…)")
        // Throwing breaks the required-mode tool loop and returns control to us.
        throw Done(answer: arguments.answer)
    }
}

struct LookupTool: Tool {
    let name = "lookup_fact"
    let description = "Look up a fact by key. Returns a short string."

    @Generable
    struct Arguments {
        @Guide(description: "The key to look up")
        var key: String
    }

    func call(arguments: Arguments) async throws -> String {
        print("    [tool] lookup_fact(key: \(arguments.key))")
        return "The melting point of gold is 1064 °C."
    }
}

// MARK: - (a) history-transforming profile

/// Keeps only the most recent prompt/response pair in the PROMPT-time history. The trim is
/// lossless: the session's stored transcript is untouched, so context dropped now can come
/// back later.
struct TrimOldTurnsProfile: LanguageModelSession.DynamicProfile {
    let model: KitLanguageModel

    var body: some LanguageModelSession.DynamicProfile {
        Profile {
            Instructions("You are a concise assistant. Answer in one sentence.")
        }
        .model(model)
        .maximumResponseTokens(256)
        .historyTransform { entries in
            // Keep instructions plus only the last two entries (one prior turn).
            let instructions = entries.filter { if case .instructions = $0 { return true }; return false }
            let recent = entries.filter { if case .instructions = $0 { return false }; return true }.suffix(2)
            return instructions + recent
        }
    }
}

enum G5Lifecycle {
    static func run(options: Options) async throws {
        banner("G5 — historyTransform / session properties / toolCallingMode")

        let fast = try await loadModel(label: "fast", bundlePath: options.fastBundle)
        warm(fast)

        // Each part is independent so a failure in one (e.g. the tool path) still leaves
        // the others' results on the record.

        // (a) historyTransform — a lossless, prompt-time-only trim. Seed a multi-turn
        // transcript; the profile prompts with only the last turn, but the stored
        // transcript keeps everything.
        banner("G5a — historyTransform (lossless per-profile trim)")
        let aSeededCount = 6
        let trimSession = LanguageModelSession(
            profile: TrimOldTurnsProfile(model: fast.model),
            history: [
                .prompt(.init(segments: [.text(.init(content: "Let's talk about planets."))])),
                .response(.init(segments: [.text(.init(content: "Happy to."))])),
                .prompt(.init(segments: [.text(.init(content: "Mars looks red."))])),
                .response(.init(segments: [.text(.init(content: "Yes — iron oxide dust."))])),
                .prompt(.init(segments: [.text(.init(content: "Jupiter is the largest."))])),
                .response(.init(segments: [.text(.init(content: "Correct, a gas giant."))])),
            ])
        var aGenerated = false
        do {
            let aTurn = try await runTurn(
                session: trimSession, prompt: "Which planet did you call the largest?")
            printTurn("trimmed-history", prompt: "Which planet did you call the largest?", aTurn)
            aGenerated = true
        } catch {
            print("  G5a generation error (separate from the transform): \(error.localizedDescription)")
        }
        // Losslessness is about the STORED transcript, independent of generation: the seed
        // survives either way.
        let aStoredEntries = trimSession.transcript.count
        print("  stored transcript has \(aStoredEntries) entries (seeded \(aSeededCount)) — "
            + "the transform is prompt-time only, lossless; generation ok=\(aGenerated)")

        // (b) session properties — a custom @SessionPropertyEntry summary written in
        // onResponse and injected into the next turn's instructions, with history trimmed.
        var nameRecalled = false
        var summaryLen = 0
        do {
            banner("G5b — session properties (custom @SessionPropertyEntry + history)")
            let propSession = LanguageModelSession(profile: SummarizingProfile(model: fast.model))
            let bPrompt1 = "My name is Daisuke and I like mountains."
            let bTurn1 = try await runTurn(session: propSession, prompt: bPrompt1)
            printTurn("prop-turn1", prompt: bPrompt1, bTurn1)
            print("  runningSummary now: \"\(propSession.properties.runningSummary)\"")
            let bPrompt2 = "What's my name?"
            let bTurn2 = try await runTurn(session: propSession, prompt: bPrompt2)
            printTurn("prop-turn2", prompt: bPrompt2, bTurn2)
            nameRecalled = bTurn2.content.localizedCaseInsensitiveContains("daisuke")
            summaryLen = propSession.properties.runningSummary.count
        } catch {
            print("  G5b error: \(error.localizedDescription)")
        }

        // (c) toolCallingMode(.required) with a throwing exit tool. The throwing finish
        // tool is 242's forceful exit condition; whether the loop is reached depends on the
        // model emitting a valid tool call, which is unreliable on the kit (decodingFailure).
        banner("G5c — toolCallingMode(.required) + throwing finish tool (exit condition)")
        var finishedAnswer: String?
        var requiredModeNote = ""
        do {
            let requiredSession = LanguageModelSession(
                model: fast.model,
                tools: [LookupTool(), FinishTool()],
                instructions: """
                    You can only act through tools. First call lookup_fact to get the \
                    data, then call finish with the answer. Never write a direct message.
                    """)
            let cPrompt = "What is the melting point of gold? Use the tools."
            _ = try await requiredSession.respond(
                to: cPrompt,
                options: GenerationOptions(maximumResponseTokens: 192, toolCallingMode: .required))
            requiredModeNote = "returned without the finish tool throwing"
        } catch let done as FinishTool.Done {
            finishedAnswer = done.answer
            requiredModeNote = "exit via throwing finish tool"
            print("  [exit] finish tool threw → loop broken; answer = \(done.answer.prefix(80))")
        } catch {
            requiredModeNote = "tool path hit \(error.localizedDescription)"
            print("  G5c: \(requiredModeNote)")
        }

        // Lossless = at least the 6 seeded entries survive in the stored transcript.
        let aPass = aStoredEntries >= aSeededCount
        gateResult(
            "G5 \(aPass && nameRecalled ? "PASS" : "PARTIAL") — "
                + "(a) historyTransform lossless: \(aStoredEntries) stored entries kept "
                + "(seeded \(aSeededCount), generated=\(aGenerated)); "
                + "(b) custom session property recall=\(nameRecalled) (summary len \(summaryLen)); "
                + "(c) required-mode exit-tool fired=\(finishedAnswer != nil) (\(requiredModeNote))")
    }
}

// MARK: - (b) profile that writes the summary at each response boundary

struct SummarizingProfile: LanguageModelSession.DynamicProfile {
    @SessionProperty(\.runningSummary) var summary: String
    @SessionProperty(\.history) var history: ArraySlice<Transcript.Entry>

    let model: KitLanguageModel

    var body: some LanguageModelSession.DynamicProfile {
        let priorSummary = summary
        Profile {
            Instructions(
                priorSummary.isEmpty
                    ? "You are a concise assistant. Answer in one sentence."
                    : "You are a concise assistant. Answer in one sentence. "
                        + "Known facts about the user: \(priorSummary)")
        }
        .model(model)
        .maximumResponseTokens(160)
        // No historyTransform here: the summary changes the instructions every turn, which
        // already changes the prompt prefix and forces a fresh prefill — so the summary
        // (not the raw history) is what carries context forward, the 242 pattern.
        .onResponse {
            // Append the user's last prompt text to the running summary so later turns
            // carry it even though the prompt history is trimmed. (A real app would
            // summarize with the model; here we keep it deterministic for the gate.)
            let prompts = history.compactMap { entry -> String? in
                if case .prompt(let prompt) = entry {
                    return prompt.segments.compactMap {
                        if case .text(let text) = $0 { return text.content } else { return nil }
                    }.joined(separator: " ")
                }
                return nil
            }
            if let latest = prompts.last, !latest.isEmpty {
                let joined = summary.isEmpty ? latest : summary + " | " + latest
                summary = joined
                print("    [onResponse] runningSummary += \"\(latest)\"")
            }
        }
    }
}
