// DualProfileChat — DynamicProfile routing across two LOCAL models (all on-device).
//
// Usage:
//   swift run DualProfileChat <gate> [--fast <bundle>] [--smart <bundle>]
//   gate ∈ { g1, g2, g3, g4, g5, g6, all }
//
// g1 uses SystemLanguageModel (needs Apple Intelligence). g2–g6 use zoo bundles via
// coreai-kit's KitLanguageModel; defaults assume the repo layout (run from this
// package dir). COREAI_CHUNK_THRESHOLD=1 is set automatically for S=1 decode bundles.

import Foundation

setenv("COREAI_CHUNK_THRESHOLD", "1", 1)

let arguments = CommandLine.arguments.dropFirst()
let gate = arguments.first ?? "all"
let options = Options.parse(arguments.dropFirst())

func runGate(_ name: String) async throws {
    switch name {
    case "g1": try await G1System.run()
    case "g2": try await G2Switch.run(options: options)
    case "g3": try await G3Baton.run(options: options)
    case "g4": try await G4Friend.run(options: options)
    case "g5": try await G5Lifecycle.run(options: options)
    case "g6": try await G6Vision.run(options: options)
    default:
        print("unknown gate '\(name)' — use g1|g2|g3|g4|g5|g6|all")
        exit(64)
    }
}

do {
    if gate == "all" {
        // g1 needs Apple Intelligence; skip it in `all` and run the local-model gates.
        for name in ["g2", "g3", "g4", "g5", "g6"] {
            try await runGate(name)
        }
    } else {
        try await runGate(gate)
    }
} catch {
    print("\nERROR: \(error.localizedDescription)")
    exit(1)
}
