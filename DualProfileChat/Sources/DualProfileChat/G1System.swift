// G1System.swift — DynamicProfile ground truth on SystemLanguageModel: profile
// switching, body re-evaluation cadence, lifecycle modifier order, transcript
// continuity. No zoo models involved.

import Foundation
import FoundationModels
import Synchronization

enum G1Mode: String, Sendable {
    case engineer, poet
}

final class G1Coordinator: Sendable {
    private let state = Mutex<G1Mode>(.engineer)
    let bodyEvals = Counter()

    var mode: G1Mode { state.withLock { $0 } }
    func set(_ mode: G1Mode) {
        state.withLock { $0 = mode }
        print("    [coordinator] mode -> \(mode.rawValue)")
    }
}

struct TwoFaceProfile: LanguageModelSession.DynamicProfile {
    let coordinator: G1Coordinator

    var body: some LanguageModelSession.DynamicProfile {
        let mode = coordinator.mode
        // DIAGNOSTIC ONLY: G1 exists to observe body re-evaluation cadence, so the body
        // counts its own evaluations and logs. A production DynamicProfile body must stay
        // PURE — it can re-run on any session change — and this counter/print is the sole
        // acceptable exception precisely because measuring the cadence is the point here.
        let evals = coordinator.bodyEvals.increment()
        let _ = print("    [profile] body evaluated #\(evals), mode = \(mode.rawValue)")
        if mode == .poet {
            Profile {
                Instructions("You are a poet. Respond ONLY with a single haiku. No prose.")
            }
            .temperature(0.9)
            .onActivate { print("    [lifecycle] poet onActivate") }
            .onDeactivate { print("    [lifecycle] poet onDeactivate") }
            .onPrompt { _ in print("    [lifecycle] poet onPrompt") }
            .onResponse { _ in print("    [lifecycle] poet onResponse") }
        } else {
            Profile {
                Instructions(
                    "You are a terse systems engineer. Answer in exactly one short technical sentence."
                )
            }
            .temperature(0.1)
            .onActivate { print("    [lifecycle] engineer onActivate") }
            .onDeactivate { print("    [lifecycle] engineer onDeactivate") }
            .onPrompt { _ in print("    [lifecycle] engineer onPrompt") }
            .onResponse { _ in print("    [lifecycle] engineer onResponse") }
        }
    }
}

enum G1System {
    static func run() async throws {
        banner("G1 — DynamicProfile sanity on SystemLanguageModel")

        let system = SystemLanguageModel.default
        guard case .available = system.availability else {
            print("SystemLanguageModel unavailable: \(system.availability)")
            print("G1 needs Apple Intelligence enabled; the local-model gates (G2+) do not.")
            exit(2)
        }
        print("  SystemLanguageModel: available")

        let coordinator = G1Coordinator()
        let session = LanguageModelSession(profile: TwoFaceProfile(coordinator: coordinator))

        let turn1 = try await runTurn(session: session, prompt: "What is a mutex?")
        printTurn("engineer", prompt: "What is a mutex?", turn1)

        coordinator.set(.poet)
        let turn2 = try await runTurn(session: session, prompt: "Same question again, please.")
        printTurn("poet", prompt: "Same question again, please.", turn2)

        coordinator.set(.engineer)
        let turn3 = try await runTurn(
            session: session,
            prompt: "In one sentence: what form was your previous answer in, and was it accurate?")
        printTurn(
            "engineer", prompt: "In one sentence: what form was your previous answer in…", turn3)

        dumpTranscript(session)
        print("\n  body evaluations for 3 turns: \(coordinator.bodyEvals.value)")

        let poemish = turn2.content.contains("\n")
        gateResult(
            "G1 \(poemish ? "PASS" : "CHECK-OUTPUT") — 2-profile switch on SystemLanguageModel; "
                + "body evals = \(coordinator.bodyEvals.value) for 3 turns; "
                + "transcript entries = \(session.transcript.count)")
    }
}
