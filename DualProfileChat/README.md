# DualProfileChat

Routing one `LanguageModelSession` between **two local models** with WWDC26's
`DynamicProfile` (session 242) — all on-device, no Private Cloud Compute, works in airplane
mode. Apple's 242 demo routes on-device ↔ PCC; this routes small-local ↔ big-local.

- **fast** = Qwen3-0.6B (`mlboydaisuke/qwen3-0.6b-CoreAI-official`) — triage / easy turns
- **smart** = Qwen3-4B (`mlboydaisuke/qwen3-4b-CoreAI-official`) — hard reasoning

Both run behind Apple's `LanguageModelSession` via coreai-kit's `KitLanguageModel`, and both
download from the Hugging Face Hub on first run.

## Run

```bash
cd agent-demos/DualProfileChat
swift run -c release DualProfileChat <gate> [--fast <bundle>] [--smart <bundle>]
```

`<gate>` is one of:

| `<gate>` | shows |
|---|---|
| `g1` | `DynamicProfile` sanity on `SystemLanguageModel` (needs Apple Intelligence) |
| `g2` | small↔big switch via `.model`; switch latency, re-prefill, two-model memory |
| `g3` | **baton-pass**: a guided-generation router decides, fast triages / smart answers |
| `g4` | **phone-a-friend**: the parent consults a short-lived child session on the big model |
| `g5` | `historyTransform`, custom session properties, `toolCallingMode(.required)` |
| `g6` | route to the vision profile when a prompt carries an image (routing; see note) |
| `all` | g2–g6 (skips g1, which needs the system model) |

`--fast` / `--smart` (or `DUALPROFILE_FAST` / `DUALPROFILE_SMART`) accept either a local
bundle directory or a `catalog:<hf-repo>` id; defaults are the catalog models above.

## Notes

- `COREAI_CHUNK_THRESHOLD=1` is set automatically (required for S=1 decode bundles).
- Routing decisions are made with **guided generation** (a constrained boolean classification
  on the sequential engine), not a tool the model calls: tool-call output from small/thinking
  models is rejected by the framework with `GenerationError.decodingFailure` on the kit's
  upstream engine.
- `g6` checks routing by modality: a text-only prompt should stay on the fast model, and a
  prompt that carries an image should go to the vision profile. On the macOS 27 SDK the text
  turn is answered by the fast model. For the image turn the demo selects the vision profile,
  and the framework then refuses the prompt with `LanguageModelError.unsupportedCapability`
  (`.vision`), which the demo prints as "The model doesn't support the requested capability."
  Both profiles in `g6` use `KitLanguageModel`, which does not declare the vision capability.
  The image turn therefore gets no answer, the image prompt is not added to the session
  transcript, and the run reports `G6 PARTIAL`.
