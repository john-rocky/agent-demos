// G2Switch.swift — two LOCAL models behind ONE LanguageModelSession via the `.model`
// modifier. Instructions are identical in both branches so the only variable is the
// model; measures switch latency (= full re-prefill of the shared transcript on the
// newly active engine), per-turn usage, and the two-models-resident footprint.

import CoreAIKit
import Foundation
import FoundationModels

struct SwitchProfile: LanguageModelSession.DynamicProfile {
    static let sharedInstructions =
        "You are a helpful, concise assistant. Answer in at most two sentences."

    let router: Router
    let fast: KitLanguageModel
    let smart: KitLanguageModel

    var body: some LanguageModelSession.DynamicProfile {
        if router.route == .smart {
            Profile { Instructions(Self.sharedInstructions) }
                .model(smart)
                .maximumResponseTokens(384)
        } else {
            Profile { Instructions(Self.sharedInstructions) }
                .model(fast)
                .maximumResponseTokens(256)
        }
    }
}

enum G2Switch {
    static func run(options: Options) async throws {
        banner("G2 — small-local ↔ big-local switching via .model")

        printMemory("baseline")
        let fast = try await loadModel(label: "fast", bundlePath: options.fastBundle)
        let memoryAfterFast = physFootprintMB()
        let smart = try await loadModel(label: "smart", bundlePath: options.smartBundle)
        let memoryAfterBoth = physFootprintMB()
        warm(fast)
        warm(smart)
        printMemory("after both models warmed")

        let router = Router()
        let session = LanguageModelSession(
            profile: SwitchProfile(router: router, fast: fast.model, smart: smart.model))

        // Turn 1 — fast model.
        let prompt1 = "In two sentences, what is a hash map?"
        let turn1 = try await runTurn(session: session, prompt: prompt1)
        printTurn("fast", prompt: prompt1, turn1)

        // Turn 2 — switch to the big model mid-session. It must re-prefill the whole
        // shared transcript; the prompt is answerable only from turn 1's content.
        router.set(.smart)
        let prompt2 =
            "Based on your previous answer, name one concrete situation where that data "
            + "structure is the WRONG choice, and why."
        let turn2 = try await runTurn(session: session, prompt: prompt2)
        printTurn("smart (switched)", prompt: prompt2, turn2)

        // Turn 3 — back to the fast model; same shared-transcript test in reverse.
        router.set(.fast)
        let prompt3 = "Summarize our whole conversation so far in one sentence."
        let turn3 = try await runTurn(session: session, prompt: prompt3)
        printTurn("fast (switched back)", prompt: prompt3, turn3)

        printMemory("after all turns (weights now resident)")
        dumpTranscript(session)

        let labels = [turn1, turn2, turn3].map { producerLabel(of: $0.newEntries) }
        let proof =
            producedBy(turn1.newEntries, fast) && producedBy(turn2.newEntries, smart)
            && producedBy(turn3.newEntries, fast)
        gateResult(
            "G2 \(proof ? "PASS" : "FAIL") — one session, three turns answered by "
                + "[\(labels.joined(separator: " | "))]; "
                + "memory fast \(String(format: "%.0f", memoryAfterFast)) MB → both "
                + "\(String(format: "%.0f", memoryAfterBoth)) MB → after turns "
                + "\(String(format: "%.0f", physFootprintMB())) MB; "
                + "switch-turn first-delta \(turn2.firstDeltaSeconds.map(fmt) ?? "n/a") "
                + "(re-prefill of \(turn2.usage?.input.totalTokenCount ?? -1) tok), "
                + "switch-back first-delta \(turn3.firstDeltaSeconds.map(fmt) ?? "n/a") "
                + "(re-prefill of \(turn3.usage?.input.totalTokenCount ?? -1) tok)")
    }
}
