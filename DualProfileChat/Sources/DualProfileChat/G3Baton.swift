// G3Baton.swift — model-decided routing between two local models (the reliable,
// tool-free form of WWDC26 242's baton-pass).
//
// 242's baton-pass uses a tool: the active model calls it to flip a route variable. On
// the kit's upstream engine that path is unreliable — small/thinking models emit tool-call
// JSON the framework rejects with GenerationError.decodingFailure ("failed to parse
// generated content"), independent of the argument schema (verified with required,
// optional, and empty arguments). See DUAL_PROFILE_STATE.md.
//
// The reliable equivalent keeps the *model* as the decider but uses a plain (tool-free)
// classification respond to make the routing call, then routes the real answer through the
// DynamicProfile. The shared transcript and the "small triages, big answers" behavior are
// preserved; only the mechanism of the decision changes from a tool call to a plain
// classification.

import CoreAIKit
import Foundation
import FoundationModels

/// One shared-transcript session whose active model follows `router`.
///
/// Both bundles are Qwen3 thinking models, so the expert profile budgets for reasoning:
/// the 4B answering "prove √2 is irrational" spends ~360 tokens inside `<think>` before the
/// proof, so its `maximumResponseTokens` is 1024 (at the original 384 the answer was
/// truncated mid-word — measured on device). The fast profile keeps a tight 192 since its
/// turns are short. NB: Qwen3's `/no_think` soft switch is NOT a usable mitigation here —
/// on these kit bundles it makes even the 0.6B emit content the framework can't decode
/// (GenerationError.decodingFailure), so giving thinking room is the reliable fix.
struct BatonProfile: LanguageModelSession.DynamicProfile {
    let router: Router
    let fast: KitLanguageModel
    let smart: KitLanguageModel

    var body: some LanguageModelSession.DynamicProfile {
        if router.route == .smart {
            Profile {
                Instructions(
                    "You are the EXPERT model in a two-model team. Start your answer with "
                    + "[EXPERT]. Answer thoroughly but in at most 6 sentences.")
            }
            .model(smart)
            .maximumResponseTokens(1024)
        } else {
            Profile {
                Instructions(
                    "You are the fast assistant in a two-model team. Start your answer "
                    + "with [FAST]. Answer in at most 2 sentences.")
            }
            .model(fast)
            .maximumResponseTokens(192)
        }
    }
}

enum G3Baton {
    static func run(options: Options) async throws {
        banner("G3 — baton-pass: the model decides which local model answers")

        let fast = try await loadModel(label: "fast", bundlePath: options.fastBundle)
        let smart = try await loadModel(label: "smart", bundlePath: options.smartBundle)
        // A DEDICATED router executor + engine. The router uses GUIDED generation, which
        // runs on the SEQUENTIAL engine (one logits step per token); `fast` answers on the
        // default PIPELINED engine. They must NOT share an executor: the kit keys executors
        // by `modelID` ALONE, so loading the router from the same bundle path would collide
        // with `fast` — the cache would hand both sessions whichever engine was created
        // first, and two sessions on one engine corrupt its KV bookkeeping (garbled output /
        // decodingFailure). A distinct `#router` modelID gives the router its own executor
        // and its own sequential engine, leaving `fast`'s pipelined engine untouched.
        let routerModel = RouterModel(
            try await loadModel(
                label: "router", bundlePath: options.fastBundle, engineVariant: .sequential,
                modelIDOverride: options.fastBundle + "#router"))
        warm(fast)
        warm(smart)

        let router = Router()
        let session = LanguageModelSession(
            profile: BatonProfile(router: router, fast: fast.model, smart: smart.model))

        let prompts = [
            "Hi! What's 2+2?",
            "Prove rigorously that the square root of 2 is irrational.",
            "Thanks! And what's 3+3?",
        ]

        var rows: [(prompt: String, hard: Bool, producedBySmart: Bool, total: Double)] = []
        for prompt in prompts {
            // 1) A small router model decides the route (tool-free classification).
            let verdict = try await routerModel.classify(prompt)
            router.set(verdict.hard ? .smart : .fast)
            print(
                "    [route] router classified as "
                    + "\(verdict.hard ? "HARD → smart" : "SIMPLE → fast") "
                    + "in \(fmt(verdict.seconds)) (\"\(verdict.raw.prefix(20))\")")
            // 2) The routed model answers, sharing the one transcript.
            let turn = try await runTurn(session: session, prompt: prompt)
            printTurn(verdict.hard ? "→ expert" : "→ fast", prompt: prompt, turn)
            rows.append(
                (prompt, verdict.hard, producedBy(turn.newEntries, smart), turn.totalSeconds))
        }

        dumpTranscript(session)

        // Proof: the easy turns were answered by fast, the hard turn by smart, and the
        // route in each case matched the producing model.
        let easyOnFast = rows.filter { !$0.hard }.allSatisfy { !$0.producedBySmart }
        let hardOnSmart = rows.filter { $0.hard }.allSatisfy { $0.producedBySmart }
        let sawBoth = rows.contains { $0.producedBySmart } && rows.contains { !$0.producedBySmart }
        let pass = easyOnFast && hardOnSmart && sawBoth
        gateResult(
            "G3 \(pass ? "PASS" : "FAIL") — model-decided routing over one shared "
                + "transcript: "
                + rows.map {
                    "\"\($0.prompt.prefix(14))…\"→\($0.producedBySmart ? "smart" : "fast")"
                }.joined(separator: ", ")
                + "; easy→fast=\(easyOnFast), hard→smart=\(hardOnSmart). "
                + "(Tool-call baton-pass blocked by kit decodingFailure — see STATE.)")
    }
}
