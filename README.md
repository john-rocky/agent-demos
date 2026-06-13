# agent-demos

Demos for the OS 27 agentic APIs (Foundation Models framework) running **entirely on
third-party local models** from the Core AI zoo, via
[coreai-kit](https://github.com/john-rocky/coreai-kit)'s `KitLanguageModel` provider.

| Demo | What it shows |
|---|---|
| [DualProfileChat](DualProfileChat/) | `DynamicProfile` routing between a small local model (Qwen3-0.6B) and a big local model (Qwen3-4B) inside ONE `LanguageModelSession` — baton-pass, phone-a-friend, history transforms, session properties, tool-calling modes. Apple's demo routes on-device ↔ Private Cloud Compute; this routes small-local ↔ big-local, fully offline. |

Each demo is a standalone SPM package; see its README for usage.
