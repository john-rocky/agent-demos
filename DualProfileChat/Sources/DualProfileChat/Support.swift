// Support.swift — CLI options, timing, memory and transcript helpers shared by the gates.

import Darwin
import Foundation
import FoundationModels

// MARK: - CLI options

struct Options {
    var fastBundle: String
    var smartBundle: String

    // Defaults are the kit's official catalog models (download once, reproducible for
    // anyone). Both are plain Qwen3 transformers, which the upstream pipelined engine
    // (coreai-kit's dependency) runs cleanly.
    //
    // Two classes of local bundle were tried and rejected for the default:
    //   * qwen3.5 (e.g. qwen3_5_0_8b_*) is a HYBRID (GDN) model — its graph declares 4
    //     KV states (key/value/conv/rec); the upstream engine expects 2 and throws at
    //     load. (The 4-state path is a local engine patch, not in the kit's URL dep.)
    //   * qwen3_vl_* DECODE bundles declare 4 per-token inputs (image_embeds/…); the
    //     engine accepts at most 2 and throws — so VL routing needs an own executor.
    //   * qwen3_0_6b_dynamic loads but emits garbage (dynamic-ids issue) — use the
    //     official static bundle instead.
    static let defaultFast = "catalog:mlboydaisuke/qwen3-0.6b-CoreAI-official"
    static let defaultSmart = "catalog:mlboydaisuke/qwen3-4b-CoreAI-official"

    /// Flags: `--fast <bundle-dir>` / `--smart <bundle-dir>`; env fallbacks
    /// `DUALPROFILE_FAST` / `DUALPROFILE_SMART`; defaults assume the repo layout
    /// (run from the package directory).
    static func parse(_ arguments: ArraySlice<String>) -> Options {
        let env = ProcessInfo.processInfo.environment
        var fast = env["DUALPROFILE_FAST"] ?? defaultFast
        var smart = env["DUALPROFILE_SMART"] ?? defaultSmart
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--fast": if let value = iterator.next() { fast = value }
            case "--smart": if let value = iterator.next() { smart = value }
            default: break
            }
        }
        return Options(fastBundle: fast, smartBundle: smart)
    }
}

// MARK: - Timing

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

struct Stopwatch {
    let start = ContinuousClock.now
    var seconds: Double { (ContinuousClock.now - start).seconds }
}

func fmt(_ seconds: Double) -> String { String(format: "%.2f s", seconds) }

// MARK: - Memory

/// `phys_footprint` and resident set size (RSS) of this process in MB, from one
/// `task_info` call. Returns (-1, -1) on failure.
private func taskMemoryMB() -> (footprint: Double, rss: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return (-1, -1) }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.resident_size) / 1_048_576)
}

/// `phys_footprint` of this process in MB — the number Xcode's memory gauge reports. NOTE
/// it EXCLUDES clean, file-backed mmapped pages, so it does NOT count the model weights
/// (~2.4 GB for these 4-bit qwen3 bundles, mapped read-only): true resident size is larger
/// (see `residentSizeMB()`). What phys_footprint DOES capture is dirty memory — KV cache,
/// activations, Metal buffers — which is why it grows from load to generation, NOT because
/// weights are being "touched in". Read it as the working set, not total RAM.
func physFootprintMB() -> Double { taskMemoryMB().footprint }

/// Resident set size (RSS) in MB — includes the clean, file-backed mmapped weight pages
/// `phys_footprint` omits, so for these bundles RSS ≈ weights + dirty working set: the
/// fuller picture of what the model occupies in RAM.
func residentSizeMB() -> Double { taskMemoryMB().rss }

func printMemory(_ label: String) {
    let m = taskMemoryMB()
    print(
        "  [mem] \(label): footprint \(String(format: "%.0f", m.footprint)) MB (dirty), "
            + "RSS \(String(format: "%.0f", m.rss)) MB (incl. mmapped weights)")
}

// MARK: - Turns

struct TurnMetrics {
    let content: String
    /// Time to the first visible response delta (includes settle + re-prefill + any
    /// reasoning tokens, which stream to a separate channel).
    let firstDeltaSeconds: Double?
    let totalSeconds: Double
    let usage: LanguageModelSession.Usage?
    let newEntries: [Transcript.Entry]
}

/// Streams one turn and reports latency + usage + the entries the turn produced.
func runTurn(
    session: LanguageModelSession,
    prompt: String,
    options: GenerationOptions = GenerationOptions()
) async throws -> TurnMetrics {
    let watch = Stopwatch()
    var firstDelta: Double?
    var last: LanguageModelSession.ResponseStream<String>.Snapshot?
    let stream = session.streamResponse(to: prompt, options: options)
    for try await snapshot in stream {
        if firstDelta == nil, !snapshot.content.isEmpty { firstDelta = watch.seconds }
        last = snapshot
    }
    return TurnMetrics(
        content: last?.content ?? "",
        firstDeltaSeconds: firstDelta,
        totalSeconds: watch.seconds,
        usage: last?.usage,
        newEntries: last.map { Array($0.transcriptEntries) } ?? [])
}

func printTurn(_ label: String, prompt: String, _ metrics: TurnMetrics) {
    print("\n> [\(label)] \(prompt)")
    print(metrics.content.isEmpty ? "  (no response text)" : metrics.content)
    var line = "  [turn] total \(fmt(metrics.totalSeconds))"
    if let first = metrics.firstDeltaSeconds { line += ", first delta \(fmt(first))" }
    if let usage = metrics.usage {
        line +=
            " | in \(usage.input.totalTokenCount) tok"
            + " (cached \(usage.input.cachedTokenCount))"
            + ", out \(usage.output.totalTokenCount) tok"
        if usage.output.reasoningTokenCount > 0 {
            line += " (reasoning \(usage.output.reasoningTokenCount))"
        }
    }
    if let producer = responseProducer(of: metrics.newEntries) {
        line += " | answered by: \(modelLabel(forID: producer))"
    }
    print(line)
}

// MARK: - Transcript inspection

/// The FULL `modelID` path of the model that produced the (last) response entry, from the
/// metadata KitExecutor attaches to every entry it emits. Returns the full path (not just
/// the last component) so proof checks can match a model by `.contains(bundleName)` — the
/// HF cache layout ends every bundle in a shared `…/<rev>/macos` variant dir, so the last
/// component alone ("macos") does not distinguish two catalog models.
func responseProducer(of entries: some Sequence<Transcript.Entry>) -> String? {
    var producer: String?
    for entry in entries {
        if case .response(let response) = entry,
            let id = response.metadata["modelID"] as? String
        {
            producer = id
        }
    }
    return producer
}

/// Whether the (last) response in these entries was produced by the given model — matches
/// the model's distinguishing bundle name anywhere in the producer's full id path.
func producedBy(_ entries: some Sequence<Transcript.Entry>, _ model: LoadedModel) -> Bool {
    guard let producer = responseProducer(of: entries) else { return false }
    return producer.contains(model.bundleName)
}

/// Short label for the model that produced the (last) response, for display.
func producerLabel(of entries: some Sequence<Transcript.Entry>) -> String {
    responseProducer(of: entries).map(modelLabel(forID:)) ?? "?"
}

/// A short, human-readable label for a model id path. For HF-cache bundles ending in a
/// generic `macos`/`ios` variant dir, uses the model-name component above it; otherwise
/// the last path component.
func modelLabel(forID id: String) -> String {
    let components = URL(fileURLWithPath: id).pathComponents
    guard let last = components.last else { return id }
    if (last == "macos" || last == "ios"), components.count >= 3 {
        // …/<name>/<rev>/<variant> → the name two levels up.
        return components[components.count - 3]
    }
    return last
}

func describe(_ entry: Transcript.Entry) -> String {
    switch entry {
    case .instructions: return "instructions"
    case .prompt: return "prompt"
    case .reasoning: return "reasoning"
    case .toolCalls(let calls): return "toolCalls(\(calls.map(\.toolName).joined(separator: ",")))"
    case .toolOutput: return "toolOutput"
    case .response(let response):
        if let id = response.metadata["modelID"] as? String {
            return "response[\(modelLabel(forID: id))]"
        }
        return "response"
    @unknown default: return "(unknown)"
    }
}

func dumpTranscript(_ session: LanguageModelSession, label: String = "transcript") {
    print("\n  [\(label)] \(session.transcript.count) entries:")
    for entry in session.transcript {
        print("    - \(describe(entry))")
    }
}

func banner(_ title: String) {
    print("\n=== \(title) ===")
}

func gateResult(_ line: String) {
    print("\nGATE-RESULT: \(line)")
}
