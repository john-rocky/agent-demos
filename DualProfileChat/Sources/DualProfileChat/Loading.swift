// Loading.swift — model loading, warmup, and the shared route state.

import CoreAIKit
import Foundation
import FoundationModels
import Synchronization

struct LoadedModel {
    let model: KitLanguageModel
    let label: String
    let bundleName: String
    let loadSeconds: Double
}

/// Loads a model from either a local bundle directory or a Hugging Face catalog id.
/// A `catalog:<repo>` argument (e.g. `catalog:mlboydaisuke/qwen3-0.6b-CoreAI-official`)
/// downloads the official bundle via the kit's `ModelStore`, so the demo is reproducible
/// without any local exports. A plain path loads a bundle directory directly.
func loadModel(
    label: String, bundlePath: String, engineVariant: EngineVariant = .auto,
    modelIDOverride: String? = nil
) async throws -> LoadedModel {
    let watch = Stopwatch()
    let model: KitLanguageModel
    let name: String
    if bundlePath.hasPrefix("catalog:") {
        let repo = String(bundlePath.dropFirst("catalog:".count))
        name = URL(fileURLWithPath: repo).lastPathComponent
        let lastPct = Mutex<Int>(-1)
        model = try await KitLanguageModel(
            model: ModelID(repo), engineVariant: engineVariant, modelID: modelIDOverride
        ) {
            progress in
            let pct = Int(progress.fraction * 100)
            let shouldPrint = lastPct.withLock { stored -> Bool in
                if pct >= stored + 10 {
                    stored = pct
                    return true
                }
                return false
            }
            if shouldPrint {
                print("    [\(label) download] \(pct)% \(progress.currentFile)")
            }
        }
    } else {
        let url = URL(fileURLWithPath: bundlePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DemoError.bundleNotFound(label: label, path: url.path)
        }
        name = url.standardizedFileURL.lastPathComponent
        model = try await KitLanguageModel(
            bundleAt: url, engineVariant: engineVariant, modelID: modelIDOverride)
    }
    let loaded = LoadedModel(
        model: model, label: label, bundleName: name, loadSeconds: watch.seconds)
    print(
        "  [load] \(label) = \(loaded.bundleName) in \(fmt(loaded.loadSeconds))"
            + " (footprint \(String(format: "%.0f MB", physFootprintMB())))")
    return loaded
}

/// Compiles the sampler graph and touches the weights through a throwaway session, so
/// the first measured turn isn't paying one-time costs. The engine is left reset.
func warm(_ loaded: LoadedModel) {
    let watch = Stopwatch()
    let session = LanguageModelSession(model: loaded.model)
    session.prewarm(promptPrefix: nil)
    print("  [warm] \(loaded.label) prewarmed in \(fmt(watch.seconds))")
}

// MARK: - Model-driven routing decision (tool-free)

struct Verdict {
    let hard: Bool
    let raw: String
    let seconds: Double
}

/// The router's classification, produced by GUIDED generation so the verdict is a clean
/// boolean rather than free text a thinking model muddles with its reasoning.
@Generable
struct RouterDecision {
    @Guide(description: "Whether the request needs the deep/expert model. Set true if it "
        + "asks to prove, derive, explain in depth, write or debug code, or requires "
        + "multi-step reasoning or specialized knowledge — any request containing 'prove', "
        + "'derive', 'rigorous', or 'explain why' is true. Set false only for greetings, "
        + "basic arithmetic like 2+2, or a single short fact.")
    var needsExpert: Bool
}

/// A small router model that classifies each request with a TOOL-FREE, GUIDED respond —
/// the reliable way to get a model-made routing decision on the kit. Two kit realities
/// shape this:
///   * Tool-call arguments from these models are frequently rejected with
///     `GenerationError.decodingFailure`, so a tool-driven router is out.
///   * Guided generation runs on the SEQUENTIAL engine (one logits step per token), which
///     has no over-generation pump — so it sidesteps the D1 over-generation that corrupts
///     KV across plain-`respond` turns, and the constrained output can't leak the model's
///     `<think>` reasoning into the verdict.
/// One session owns the engine for its lifetime (see the engine-ownership note below).
final class RouterModel {
    private let session: LanguageModelSession
    let model: LoadedModel

    init(_ model: LoadedModel) {
        self.model = model
        // A plain session (matching the kit's GuidedDemo) — one session owns the engine.
        self.session = LanguageModelSession(
            model: model.model,
            instructions:
                "You are a router for a two-model team. Decide whether a request needs a "
                + "deep/expert model or can be handled by a small fast one.")
    }

    func classify(_ question: String) async throws -> Verdict {
        let watch = Stopwatch()
        let response = try await session.respond(
            to: "Classify this request for routing. Request: \"\(question)\"",
            generating: RouterDecision.self)
        return Verdict(
            hard: response.content.needsExpert,
            raw: "needsExpert=\(response.content.needsExpert)",
            seconds: watch.seconds)
    }
}

/// A one-model session expressed as a single-profile DynamicProfile. Prefer this over the
/// plain `LanguageModelSession(model:instructions:)` initializer: on these kit bundles the
/// plain initializer's first respond fails with a framework-level decodingFailure, whereas
/// the profile path is reliable (G2/G3). Same single-model behavior, one engine owner.
struct SoloProfile: LanguageModelSession.DynamicProfile {
    let model: KitLanguageModel
    let instructions: String
    var body: some LanguageModelSession.DynamicProfile {
        Profile { Instructions(instructions) }
            .model(model)
    }
}

enum DemoError: Error, LocalizedError {
    case bundleNotFound(label: String, path: String)
    case toolFailure(String)

    var errorDescription: String? {
        switch self {
        case .bundleNotFound(let label, let path):
            return "\(label) bundle not found at \(path) — pass --\(label) <bundle-dir> "
                + "or set DUALPROFILE_\(label.uppercased())."
        case .toolFailure(let message):
            return message
        }
    }
}

// MARK: - Route state

enum Route: String, Sendable {
    case fast, smart
}

/// The variable that controls which profile is active (WWDC26 242's baton-pass
/// ingredient #2). Tools flip it; the profile body reads it on every re-evaluation.
final class Router: Sendable {
    private let state: Mutex<Route>

    init(_ initial: Route = .fast) {
        state = Mutex(initial)
    }

    var route: Route { state.withLock { $0 } }

    func set(_ route: Route) {
        state.withLock { $0 = route }
        print("    [router] route -> \(route.rawValue)")
    }
}

/// Thread-safe counter for observing how often a profile body is re-evaluated.
final class Counter: Sendable {
    private let state = Mutex<Int>(0)
    @discardableResult
    func increment() -> Int { state.withLock { $0 += 1; return $0 } }
    var value: Int { state.withLock { $0 } }
}
