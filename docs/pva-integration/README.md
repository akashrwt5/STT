# PVA Voice Understanding — Provider Abstraction

**Programme:** Decouple Personal Voice Assistant from Dialogflow and enable on-device intent classification via VoiceAIKit
**Owner:** Feature Architect · **Status:** Draft for review · **Last updated:** 31 July 2026

---

## What this is

PVA today sends every utterance to Dialogflow and cannot function offline. This document set defines the architecture that lets PVA run intent understanding through **either** Dialogflow **or** VoiceAIKit (on-device), selected by remote configuration, with no change to PVA business logic or intent handlers.

## Read this first — one paragraph

We introduce a provider-neutral contract, `VoiceUnderstandingProvider`, that PVA depends on instead of `PvaProxyService`. Two adapters implement it: one wrapping today's Dialogflow gRPC stream, one wrapping VoiceAIKit. **The app keeps microphone ownership** (hearing-aid mic is non-negotiable) and pushes audio into whichever provider is active. **VoiceAIKit owns multi-turn dialogue on the on-device path**, with three explicit carve-outs — text-to-speech, the non-device fallback chain, and Push-to-Talk — which remain app-owned in both providers. Provider selection resolves once at app launch and is immutable for the process lifetime.

## Reading guide

| # | Document | Answers | Primary audience |
|---|---|---|---|
| 1 | [**ADR-0001** — Voice Understanding Provider abstraction](./ADR-0001-voice-understanding-provider-abstraction.md) | *Why this shape, and what we rejected* | Architecture review board, staff+ engineers |
| 2 | [**HLD** — Voice Understanding](./HLD-voice-understanding.md) | *How the system fits together, today and after* | Engineering, QA, new joiners |
| 3 | [**SPEC** — Voice Understanding Provider](./SPEC-voice-understanding-provider.md) | *The normative contract every provider must satisfy* | Implementers of either adapter |
| 4 | [**PLAN** — Migration & Rollout](./PLAN-migration-and-rollout.md) | *What we change, in what order, and how we roll back* | Engineering leads, release management |
| 5 | [**PLAN** — Test Strategy](./PLAN-test-strategy.md) | *How we prove behaviour didn't drift* | QA, engineering, regulatory reviewers |

If you have fifteen minutes: read the ADR, then §3 and §7 of the HLD.
If you are implementing an adapter: the SPEC is normative; everything else is context.

## Decisions already taken

These are settled inputs to the design, recorded here so reviewers don't relitigate them in comments. Full rationale lives in ADR-0001 §4.

| Decision | Choice | ADR ref |
|---|---|---|
| Microphone ownership | **App.** PVA keeps `PVARecorderFactory` / `PVAAidRecorder`; audio is pushed into the provider | D1 |
| Speech recognition ownership | **Provider.** Dialogflow does cloud ASR; VoiceAIKit does `SpeechAnalyzer` ASR | D2 |
| Multi-turn dialogue ownership | **Provider, with a carve-out matrix.** Kit owns slot filling / confirmation / interruption on-device | D3 |
| Text-to-speech | **App, always.** Providers emit prompt *text*; they never speak | D4 |
| Non-device fallback (CMS → GenAI → Wolfram) | **App, always.** Provider signals `unresolved`; it never terminates the turn itself | D5 |
| Push-to-Talk dialogue | **App, always.** Declared as an app-owned intent family in provider capabilities | D6 |
| Provider selection granularity | **Resolved once at app launch**, immutable for the process | D7 |
| Rollout control | Remote config with a kill-switch to Dialogflow; no partial-session switching | D7 |

## Open questions

Tracked here rather than scattered through the documents. Each blocks a specific phase.

| # | Question | Blocks | Owner |
|---|---|---|---|
| Q1 | Does `PVAAidRecorder` expose a stable PCM format, and at what sample rate/bit depth? | Phase 2 | iOS |
| Q2 | What is the exact Dialogflow parameter type surface in use today (`[String: Any]` inhabitants)? | Phase 1 | iOS |
| Q3 | Is a Danish/French/German on-device rollout in scope for v1, or English-only? | Phase 4 | Product |
| Q4 | Does the analytics contract permit logging classification stage/confidence per turn? | Phase 3 | Privacy / Legal |
| Q5 | Which release train carries this, and does it require a regulatory change assessment? | Phase 5 | Regulatory |

## Document conventions

- Diagrams are Mermaid, rendered inline by GitHub/GitLab and most IDEs.
- The SPEC uses RFC 2119 keywords (**MUST**, **SHOULD**, **MAY**) with their normative meaning. No other document in this set is normative.
- Swift shown in the ADR and HLD is illustrative. Only the SPEC's signatures are binding.
- Class and file names match the Engage codebase (`Engage/Engage/Services/PersonalVoiceAssistant`) and the VoiceAIKit package as of this date.
