# Apple Platform Options — Real-Time Answering & Semantic Understanding

**Date:** 31 July 2026 · **Basis:** WWDC26 (iOS/macOS 27, currently developer beta) + shipped iOS 26.x
**Audience:** Engineering, architecture review
**Related:** [ON_DEVICE_NLU_TECHNICAL_DETAILS.md](./ON_DEVICE_NLU_TECHNICAL_DETAILS.md) · [FM_SAMPLE_PLAN.md](./FM_SAMPLE_PLAN.md)

> **Status caveat that governs this whole document.** iOS 27 is in developer beta. Every API marked "27" below can change before GM in September. Nothing here should be scheduled into a release that ships before we have re-verified against the GM SDK.

---

## 0. The two answers, up front

**Q1 — "Siri answers 'what is the current gold price'. Can my app use that?"**

**No.** There is no public API, on any Apple platform, that lets a third-party app submit a natural-language question and receive Siri's answer. Siri's world-knowledge answering is a first-party service, and the developer-facing API Apple shipped in this area (Siri Extensions / App Intents / App Schemas) runs in the *opposite* direction — it lets your app expose capabilities *to* Siri, not consume Siri's answers.

What *is* available, and is the correct engineering substitute, is the Foundation Models framework as a **model slot + tool-calling runtime**. Apple gives you the orchestration (routing, structured output, tool loop); *you* supply the live data through a `Tool` you write. No Apple-provided model — on-device or Private Cloud Compute — has live internet knowledge. "Current gold price" is a data-source problem wearing an LLM costume.

**Q2 — "Is there another way to do semantic understanding?"**

**Yes, four credible ones**, in ascending order of ambition: `NLContextualEmbedding` (drop-in replacement for our bundled MiniLM, zero bundle cost), the Foundation Models on-device model with `@Generable` constrained decoding (already scoped in `FM_SAMPLE_PLAN.md`), a **custom LoRA adapter** trained on our existing ~10k utterances, and `SpotlightSearchTool` local RAG for the help/FAQ intent family. Each trades away something we currently have — and for a product adjacent to a regulated device category, **what we trade away is determinism and version-pinnability**, which is the crux of the decision, not accuracy.

---

## 1. Question 1 — Real-time / world-knowledge answering

### 1.1 What Siri actually does, and why it isn't reachable

Siri's LLM-backed answering (rebuilt in the iOS 26.4 → 27 cycle, marketed as "World Knowledge Answers") synthesises a response from live sources and requires connectivity, routing through Private Cloud Compute. It is an Apple service, not an SDK. There has never been an "ask Siri a question, get a string back" API, and SiriKit's domain model was explicitly built the other way round: your app *services* intents Siri recognises.

**iOS 27's Siri Extensions does not change this.** It lets AI assistant apps (Claude, Gemini, ChatGPT, Perplexity, et al.) plug in as providers *behind* Siri. Siri remains the orchestration layer. You cannot be a consumer of it from inside your app.

**The legitimate product move in this direction** is the inverse one, and it's cheap: adopt **App Intents + App Schemas** so our ~59 commands become available to Siri system-wide. Then a user who asks "what's the gold price" gets Siri's answer *from Siri*, and a user who says "turn up my hearing aids" reaches us — without us building or paying for a general-knowledge path at all. Worth costing separately; see WWDC26 sessions 240 and 344.

### 1.2 What you actually get: Foundation Models as a model slot

WWDC26 turned `LanguageModelSession` into a runtime backed by a `LanguageModel` protocol. One call site, four (soon five) backends:

| Backend | Type | Context | Cost | Offline | Notes |
|---|---|---|---|---|---|
| `SystemLanguageModel()` | on-device, ~3B | 4,096 (26.0) → 8,192 (27.0, newer HW) | free | **yes** | rebuilt this year; now accepts image attachments |
| `PrivateCloudComputeLanguageModel()` | Apple server model | 32,768 | free *if eligible* — see §1.4 | no | reasoning levels `.light/.moderate/.deep`; no API keys; per-user daily quota |
| `ClaudeLanguageModel` (`anthropics/ClaudeForFoundationModels`, beta) | Anthropic frontier | vendor | **you pay per token** | no | OAuth + Keychain handled by the package |
| `GeminiLanguageModel` (Firebase Apple SDK, preview) | Google frontier | vendor | **you pay per token** | no | |
| `CoreAILanguageModel` / `MLXLanguageModel` (`apple/coreai-models`) | your own open weights | model-dependent | free | **yes** | ANE / GPU; session demos 4-bit Qwen3 |

`@Generable` structured output, tool calling, streaming and Dynamic Profiles all work against the protocol, so backend choice is an init argument, not a rewrite. That is genuinely useful to us: it means the *same* FM classifier from `FM_SAMPLE_PLAN.md` can be benchmarked on-device vs. PCC vs. Claude without touching `NLUEngine`.

### 1.3 None of them know the gold price

This is the point people skip. All five backends are language models with a training cutoff. The built-in **system tools shipped in iOS 27 are `OCRTool`, `BarcodeReaderTool`, and `SpotlightSearchTool`** — Vision-backed and Spotlight-backed. **There is no Apple-provided web-search tool.** Live data enters the loop only through a `Tool` you implement:

```swift
struct SpotPriceTool: Tool {
    let description = "Look up the current spot price of a commodity or the current \
                       exchange rate for a currency pair. Use for any question about \
                       today's price, rate, or market value."

    @Generable
    struct Arguments {
        @Guide(description: "Commodity or currency symbol, e.g. XAU, XAG, BTC, USD")
        let symbol: String
        @Guide(description: "Quote currency, e.g. USD, EUR, DKK")
        let quote: String
    }

    func call(arguments: Arguments) async throws -> some PromptRepresentable {
        let quote = try await marketDataClient.spot(arguments.symbol, in: arguments.quote)
        // Return facts, not prose. The model narrates; the tool never guesses.
        return "\(arguments.symbol)/\(arguments.quote) = \(quote.value) as of \(quote.asOf.ISO8601Format()); source: \(quote.source)"
    }
}

let session = LanguageModelSession(
    model: PrivateCloudComputeLanguageModel(),
    tools: [SpotPriceTool(), WeatherTool(), /* ... */]
)
```

So the honest framing for the roadmap: **"real-time answering" is not an Apple-API problem, it is a data-contract problem.** Decide which live domains we are willing to be accountable for, buy or build a source for each, and let the model do routing + narration only.

If we want genuinely open-ended web answering with no per-domain source work, the only shortcut is a frontier backend whose *vendor* runs server-side web search (Anthropic's and Google's APIs both offer one) — verify whether the Swift packages surface it, because if they don't you're back to writing the tool. Either way that path is **metered, online-only, and non-deterministic** — i.e. exactly the properties §6 of the overview document argues against for anything but the fallback slot.

### 1.4 Eligibility gates — read before planning around PCC

Two hard gates, and the second one probably disqualifies us:

1. **Managed entitlement.** `com.apple.developer.private-cloud-compute` requires an application through Apple (`developer.apple.com/private-cloud-compute`). Approval is the long pole; the application is open now, so submit it regardless of decision — it costs nothing and unblocks evaluation.
2. **Free tier eligibility: App Store Small Business Program enrolment and under 2 million first-time downloads.** A Starkey-scale consumer app is very unlikely to qualify. Assume PCC is either unavailable or commercially different for us until Legal/Business confirms. **Do not build a plan whose cost model depends on free PCC.**

Also: PCC spends a **per-user daily quota** (higher with iCloud+), not a metered bill. Quota exhaustion is a UI state (`model.quotaUsage.isLimitReached`, `limitIncreaseSuggestion`), not an exception — Apple is explicit that it should be persistent UI, not an alert. For a hearing-aid companion, a feature that silently stops working at 6pm because the user hit a quota is a support-ticket generator; it must degrade to the existing cloud fallback, not to nothing.

### 1.5 The cheap, boring, first-party alternative

A large share of "real-time" questions users actually ask a hearing-aid app are not open-web questions. They are:

| Query class | First-party API | Cost | Offline |
|---|---|---|---|
| Weather now/forecast | **WeatherKit** | free tier, then metered | no |
| Time, date, timers, alarms | Foundation / `UNUserNotificationCenter` | free | yes |
| "Where's the nearest pharmacy", hours | **MapKit** `MKLocalSearch` | free | no |
| Calendar / next appointment | **EventKit** | free | yes |
| Steps, heart rate, sleep | **HealthKit** | free | yes |
| Battery, connectivity, device state | system APIs | free | yes |

These are deterministic, auditable, cheap, and mostly on-device. **Recommendation: classify the top-N out-of-scope utterances we're already logging in `unknown_data.csv`, and see what fraction is covered by that table before funding any LLM answering path.** My prior is that it's most of them, and that "current gold price" is a demo query rather than a user need.

---

## 2. Question 2 — Other routes to semantic understanding

Ordered by how much of the current architecture they disturb.

### Option A — `NLContextualEmbedding` replaces our bundled MiniLM

**What it is:** a BERT-family sentence encoder built into the OS since iOS 17, ANE-optimised, three script-grouped models (Latin ≈20 languages, Cyrillic 4, CJK 3).

**Why it's attractive for us specifically:** it deletes the single ugliest line in our technical details doc — *"Stage 3 fully loaded adds roughly 100 MB of `phys_footprint`, of which ~65 MB is a persistent floor."* An OS-provided encoder is shared, asset-downloaded rather than bundled, and removes 22 MB of app binary, the WordPiece vocab file, and our hand-written tokenizer (`SemanticEmbedder.swift`) — which is currently a *cross-platform parity liability*, because it must match `semantic.py` byte-for-byte forever.

**What it costs us — and this is the real decision:**

- **Version pinning is gone.** Apple can revise the encoder in a point release. Our 89.4% holdout number is measured against a checksummed 22 MB artifact we own. With `NLContextualEmbedding` the embedding space can shift under a linear head we trained offline, silently. For a product adjacent to a regulated device category, "which model was running" stops being answerable by our own version manifest. `NLContextualEmbedding` exposes a `revision` — **pin it, record it, and gate on it**, or don't take this option.
- **Assets are downloaded, not bundled.** `hasAvailableAssets` / `requestAssets` must be handled; first-run and offline-first-run are new states in a pipeline whose selling point is offline-first.
- **Language coverage must be verified per-language at runtime**, not assumed from the "20 Latin languages" headline. Danish specifically needs checking on device before we commit the multilingual roadmap to it.
- **Android parity breaks.** Our current MiniLM is portable by design (ONNX → Core ML *and* Android). `NLContextualEmbedding` is Apple-only, so this fork the codebase into two different Tier-3 semantic spaces with two different accuracy profiles. Given Android is explicitly on the roadmap, this is a strategic cost, not an implementation detail.

**Verdict:** run it as a **measured experiment against the 341-utterance holdout** — retrain the linear head on `NLContextualEmbedding` vectors, compare accuracy, latency, and `phys_footprint`. If it holds ≥89.4% and cuts the memory floor, it's a strong iOS-side win. Do not adopt it blind.

### Option B — Foundation Models on-device as the semantic tier

Already fully scoped in `FM_SAMPLE_PLAN.md`, and that plan is sound. Three updates to it in light of WWDC26:

1. **The Danish blocker is gone.** The plan states "Apple Intelligence doesn't cover Danish at all." That was true at WWDC25; **iOS 26.1 added Danish, Dutch, Norwegian, Portuguese (PT), Swedish, Turkish, Chinese (Traditional) and Vietnamese.** All four of our target languages (en/fr/de/da) are now covered. §5 of that plan should be revised — the multilingual exclusion is no longer a finding, it's stale.
2. **The context budget got easier.** `contextSize` is now readable at runtime (4,096 on 26.0, 8,192 on 27.0 for newer hardware) and `tokenCount(for:)` exists since iOS 26.4. `FMPromptBuilder`'s token assertion should read these rather than hard-code 4,096.
3. **The confidence-gating gap stands.** No logprobs, no calibrated confidence. Our whole Stage 4 design is threshold-based, and a `@Generable` enum always returns *something*. This remains the strongest argument for FM as a **fallback/OOS-rejection tier only**, never as a replacement for Tiers 1–2.

**The unchanged strategic risk:** Apple revs the on-device model on their schedule. Our accuracy number becomes a function of the user's OS build. The benchmark harness in that plan isn't a nice-to-have — it's the only thing that makes this option auditable.

### Option C — Custom LoRA adapter (`.fmadapter`)

The highest-upside, highest-maintenance option. Apple's Python adapter training toolkit lets us LoRA-fine-tune the on-device model on our ~10,000 labelled utterances, export a `.fmadapter` package, and ship it via **Background Assets** (out of the app binary).

- **Upside:** domain-specialised understanding with no bundled encoder, no tokenizer to maintain, no parity harness against a Python reimplementation, and plausibly better handling of the confusable pairs (`Help_HeartRate` vs `Help_HeartRateRecovery`) than either TF-IDF or a frozen MiniLM head.
- **The killer caveat:** an adapter is trained against a *specific base model version*. When Apple ships a new on-device model, the adapter must be retrained and re-shipped, or it stops loading. That is a recurring, unschedulable obligation tied to someone else's release calendar — for a product with medical-device adjacency and formal release gates, that obligation must be owned by a named team before anyone writes the training script.
- Also: Apple's own guidance is to try prompting + `@Generable` first and only train an adapter when measurements show it's necessary. We have not measured Option B yet. **Sequence: B, then C — never C first.**

### Option D — Keep the MiniLM architecture, improve it

Least glamorous, probably the best short-term ROI, and the only option that preserves cross-platform parity:

- **Swap the encoder.** MiniLM-L6-v2 is a 2021 model. `multilingual-e5-small` or `gte-small` are stronger at comparable size and would serve the fr/de/da roadmap from a single encoder instead of per-language work.
- **Attack the 100 MB footprint directly.** It is a Core ML/ANE execution artifact, not an inherent cost — try `MLComputeUnits` variations, a shorter `max_len` (our 64 is generous for ~60 short commands), and Apple's ANE-optimised transformer reference implementation. A measured 30 MB reduction here is worth more to this product than 1% holdout accuracy.
- **Distil.** With 10k labelled utterances over a closed 59-class set, a task-specific distilled encoder (2–4 layers) would likely hold accuracy at a fraction of the size. This is the classic right answer for a closed-domain classifier and we have the data for it.

### Option E — `SpotlightSearchTool` for the `Help_*` intent family

New in iOS 27, and a genuinely good fit for one specific slice of our problem. Donate our help/FAQ/how-to content to the **Core Spotlight** index; hand `SpotlightSearchTool` to a `LanguageModelSession`; the model writes the query, Spotlight runs it, the model answers over the results. **Local RAG with no embedding pipeline, no vector store, no server.**

Our intent catalogue contains a cluster of fine-grained `Help_*` intents that are (a) the hardest to classify, (b) semantically near-identical, and (c) really information-retrieval questions dressed up as classification. Turning that cluster from ~15 classification labels into one `Help` intent + Spotlight retrieval would *simplify the classifier* and probably raise overall holdout accuracy by removing our worst confusable pairs. **This is the most interesting idea in this document and the one I'd prototype first.**

### Option F — Measurement, not modelling

Two WWDC26 tools that map directly onto work we are already doing by hand:

- **Evaluations framework** (session 298) — datasets into Swift Testing, scores in Xcode's test report, `ModelJudgeEvaluator` for qualitative dimensions. Our 341-utterance holdout is already exactly a `ModelSample` dataset. This replaces the bespoke "Run Benchmark" button in `FM_SAMPLE_PLAN.md` §8 with a CI-gateable framework — which is also the missing piece in the "cross-platform conformance testing not yet wired into CI" line in the overview's status table.
- **Foundation Models instrument in Xcode 27** — visualises the tool-call loop, time-to-first-token, tokens/sec per request. Necessary if we go anywhere near Options B/C/E.

---

## 3. Recommendation

| # | Action | Effort | Risk | Why now |
|---|---|---|---|---|
| 1 | **Classify our logged out-of-scope utterances** against the §1.5 first-party API table | 1 day | none | Determines whether the entire "real-time answering" workstream is even needed |
| 2 | **Prototype Option E** (`Help_*` → Core Spotlight + `SpotlightSearchTool`) | 3–5 days | low | Simplifies the classifier, attacks our worst confusable pairs, no vendor cost |
| 3 | **Apply for the PCC entitlement** | 1 hour | none | Approval is the long pole; applying costs nothing and doesn't commit us |
| 4 | **Execute `FM_SAMPLE_PLAN.md` (Option B)**, with the three §2-B corrections | 4–5 days | low | It's already scoped, isolated, and disposable; produces the data for every later decision |
| 5 | **Option A experiment**: retrain the semantic head on `NLContextualEmbedding`, measure vs. 89.4% and vs. the 100 MB footprint | 3 days | low | Potentially deletes 22 MB + our tokenizer parity liability |
| 6 | **Option D memory work** on the existing MiniLM path | 2–3 days | low | Independent of everything above; benefits production today |
| 7 | Adopt **App Intents / App Schemas** so our commands reach Siri | separate scoping | med | The correct answer to "can we be like Siri" is "be reachable from Siri" |
| — | **Option C (LoRA adapter)** | — | **high** | **Do not start until #4 produces numbers.** Recurring retrain obligation tied to Apple's release calendar |
| — | **Frontier-model backend (Claude/Gemini) for open web answering** | — | **high** | Metered, online-only, non-deterministic. Only ever as the fallback exit — and our existing cloud fallback already occupies that slot |

**The single sentence version:** Apple gave us a much better *runtime* this year, not a source of truth — so the answer to Q1 is "build the data contract, not the model," and the answer to Q2 is "measure Options A/B/E against the 341-utterance holdout before changing anything in production."

---

## 4. Open items to verify before this document is actionable

1. **PCC eligibility** — does Starkey qualify for the free tier (App Store Small Business Program + <2M first-time downloads)? Almost certainly not; needs a Business/Legal answer, and it invalidates the cost model of several options above if the answer is no.
2. **`NLContextualEmbedding` Danish support** — verify on device via `hasAvailableAssets`, not from the "20 Latin languages" marketing line.
3. **Whether `ClaudeForFoundationModels` / `GeminiLanguageModel` surface vendor server-side web search**, or whether we'd be writing that tool ourselves anyway.
4. **`NLContextualEmbedding` revision pinning semantics** — can we hard-fail on an unexpected revision? If not, Option A is incompatible with our auditability claim.
5. **GM re-verification in September.** Everything labelled iOS 27 here is beta.
6. **Medical-adjacency review** of any generative answering path. A hearing-aid companion narrating a hallucinated health fact is a materially different risk class from a misclassified volume command. Whatever we build, generative answers about health should be routed to deterministic sources or refused — this needs a written policy before code.

---

## Sources

- [What's new in the Foundation Models framework — WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)
- [Build with the new Apple Foundation Model on Private Cloud Compute — WWDC26 session 319](https://developer.apple.com/videos/play/wwdc2026/319/)
- [Meet the Evaluations framework — WWDC26 session 298](https://developer.apple.com/videos/play/wwdc2026/298/)
- [Build intelligent Siri experiences with App Schemas — WWDC26 session 240](https://developer.apple.com/videos/play/wwdc2026/240/)
- [Code-along: Make your app available to Siri — WWDC26 session 344](https://developer.apple.com/videos/play/wwdc2026/344/)
- [WWDC26 Apple Intelligence guide — Apple Developer](https://developer.apple.com/wwdc26/guides/apple-intelligence/)
- [Foundation Models — Apple Developer Documentation](https://developer.apple.com/documentation/FoundationModels)
- [Loading and using a custom adapter with Foundation Models](https://developer.apple.com/documentation/foundationmodels/loading-and-using-a-custom-adapter-with-foundation-models)
- [Foundation Models adapter training toolkit — Apple Developer](https://developer.apple.com/apple-intelligence/foundation-models-adapter/)
- [NLContextualEmbedding — Apple Developer Documentation](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding)
- [Foundation Models, Year Two: From On-Device API to General LLM Runtime — Ivan Magda](https://ivanmagda.dev/posts/wwdc26-foundation-models-year-two/)
- [iOS 26.1 brings Apple Intelligence to these eight new languages — 9to5Mac](https://9to5mac.com/2025/11/11/ios-26-1-brings-apple-intelligence-to-these-eight-new-languages/)
- [iOS 27 Siri Third-Party AI Assistants Explained — Gadget Hacks](https://apple.gadgethacks.com/news/ios-27-siri-third-party-ai-assistants-explained-apples-strategy/)
- [Apple Outlines Major AI and Developer Tool Updates at 2026 Platforms State of the Union — MacRumors](https://www.macrumors.com/2026/06/09/apple-outlines-major-ai-and-developer-tool-updates/)
