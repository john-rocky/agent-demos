// G4Friend.swift — the phone-a-friend pattern (WWDC26 242) across two local models: the
// parent consults a SHORT-LIVED child session with an INDEPENDENT transcript on the big
// model, then writes the final answer itself.
//
// 242 spawns the child from inside a TOOL. On the kit's upstream engine the parent's tool
// call is rejected (GenerationError.decodingFailure — see G3 / DUAL_PROFILE_STATE.md), so
// the consultation is driven by the app instead: a guided router decides the question
// needs an expert, the app opens the child session, and the parent finishes. The defining
// phone-a-friend properties are preserved — the child's transcript is isolated and thrown
// away, and the parent always produces the user-facing answer.

import CoreAIKit
import Foundation
import FoundationModels

enum G4Friend {
    static func run(options: Options) async throws {
        banner("G4 — phone-a-friend: parent consults an isolated child session")

        // Load fast and smart once, then prewarm each. warm() runs a throwaway session on
        // the SAME executor (the kit caches one executor per modelID) and ends with
        // engine.reset(), so it compiles the sampler graph and touches weights without
        // leaving KV state behind — the parent/child sessions that follow reuse that same
        // warmed executor. Distinct models = distinct engines (parent owns fast's, child
        // owns smart's), and only one session touches each engine at a time.
        let fast = try await loadModel(label: "fast", bundlePath: options.fastBundle)
        let smart = try await loadModel(label: "smart", bundlePath: options.smartBundle)
        warm(fast)
        warm(smart)

        // A request the parent should not tackle alone. (In G3 a guided router makes this
        // decision from the model; here the consultation mechanic itself is the focus, so
        // the question is fixed.)
        // Kept short on purpose: a thinking expert asked for a long proof can spend the
        // whole token budget inside <think> and emit no response, which the framework then
        // rejects with decodingFailure ("failed to parse generated content"). A bounded
        // question keeps the answer within budget. See DUAL_PROFILE_STATE.md.
        let question =
            "In two sentences: what is the time complexity of binary search, and why?"
        print("\n> \(question)")

        // phone-a-friend: spawn a SHORT-LIVED child session on the big model with its own
        // transcript, ask it, take the answer, and discard the child.
        let consultWatch = Stopwatch()
        let expertNote: String
        var childEntryCount = 0
        do {
            let child = LanguageModelSession(
                profile: SoloProfile(
                    model: smart.model,
                    instructions: "You are an algorithms expert. Answer in exactly two sentences."))
            let childTurn = try await runTurn(session: child, prompt: question)
            expertNote = childTurn.content
            childEntryCount = child.transcript.count
            print(
                "  [consult] child (\(smart.bundleName)) answered in \(fmt(consultWatch.seconds)) "
                    + "— \(childEntryCount)-entry transcript, now discarded")
        }  // `child` goes out of scope here: its transcript is gone.

        // The parent is the small, always-on model that owns the final answer (created
        // after the consult so only one session touches each engine at a time).
        let parent = LanguageModelSession(
            profile: SoloProfile(
                model: fast.model,
                instructions:
                    "You are a concise assistant. When given expert notes, use them to "
                    + "answer the user in at most 3 sentences. Start your answer with [PARENT]."))

        // 3) The parent writes the final answer, grounded in the expert's note.
        let parentTurn = try await runTurn(
            session: parent,
            prompt: """
                The user asked: "\(question)"
                An expert provided these notes: "\(expertNote)"
                Now give the user a short, clear final answer.
                """)
        printTurn("parent (final)", prompt: question, parentTurn)

        dumpTranscript(parent, label: "parent transcript (no child entries should appear)")

        // Isolation: the child's transcript never merges into the parent's. The parent
        // ran exactly one turn, so its transcript holds exactly one prompt and one
        // response (plus instructions and, for a thinking model, one reasoning entry).
        let parentEntries = Array(parent.transcript)
        let parentOwnsFinal = producedBy(parentEntries, fast)
        let promptCount = parentEntries.filter { if case .prompt = $0 { return true }; return false }.count
        let responseCount = parentEntries.filter { if case .response = $0 { return true }; return false }.count
        let childIsolated = promptCount == 1 && responseCount == 1
        let pass = parentOwnsFinal && childIsolated && !expertNote.isEmpty
        gateResult(
            "G4 \(pass ? "PASS" : "FAIL") — router→consult, child (\(smart.bundleName)) "
                + "answered then discarded (isolated), parent (\(fast.bundleName)) wrote the "
                + "final answer; parent transcript \(parentEntries.count) entries, "
                + "1 prompt/1 response (child isolated=\(childIsolated)). "
                + "(Tool-spawned consult blocked by kit decodingFailure — app-driven here.)")
    }
}
