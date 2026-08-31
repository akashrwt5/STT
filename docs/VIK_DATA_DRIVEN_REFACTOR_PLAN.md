# VoiceAIKit — Data-Driven Refactor Plan

**Target:** VoiceAIKit consumes `pack-<lang>-v<version>` bundles produced by the Python NLU compiler, with zero static resources and zero language-specific Swift.
**Reference:** `VoiceAIKit_Architecture.md` (the ADD)
**Baseline audited:** `feature/claude/multilingual-nlu-status-check-s7ggcw-Base/VAIKit-refactoring` @ 7,096 LOC Swift, against `VoiceAIKit/Sources/pack-en-v1.0.26` (format_version 3.0, runtime contract 1)

---

## 1. Where we actually stand

**VoiceAIKit is not data-driven today. It is manifest-driven within a statically-linked resource set.** Those are different things, and the gap is the whole project.

The existing `LanguagePack` / `LanguagePackRegistry` / `LocalizationLoader` layer is real, well-built abstraction — it means adding a language requires no Swift edits. But every path it resolves terminates in `Bundle.module`, at build time, from resources committed into the SPM. The package cannot read a pack it did not compile against.

Measured findings:

| # | Finding | Evidence | Severity |
|---|---|---|---|
| F1 | Nothing reads the pack | 0 occurrences of `capabilities`, `workflows`, `responses`, `cascade`, `policies`, `routing`, `compileModel`, `updateBundle`, `NLUEvent`, `CryptoKit` across all Swift | Blocker |
| F2 | All 17 resource lookups go through `Bundle.module` | `IntentClassifierService:135`, `SemanticEmbedder:41`, `SemanticClassifier:37`, `NLUSchema:96`, `EntityExtractor:66`, `LocalizationLoader:142`, `LanguagePackRegistry:53` | Blocker |
| F3 | `NLULexicon` cannot decode the pack's lexicon, and fails silently | Pack ships `carriers`/`datetime_grammar`; `NLULexicon` expects `carrier_phrases`/`weekdays`/`months`/`numbers_0_to_31`. Every field decodes `try? … ?? []`, so a pack lexicon yields an **all-empty struct**, and `NLUEngineFactoryProvider:60-62` then substitutes `NLUEngine.defaultUncertain/defaultNoIdioms/defaultCarriers` — hardcoded English. No throw, no log. | **Critical** |
| F4 | English is the structural base, not a peer | `LocalizationLoader:19,50` short-circuit on `language != "en"`; other languages are string patches merged onto English via `mergeOverlay` | Blocker |
| F5 | Label taxonomy incompatible | VIK/app use `Cmd.*` (60 labels). Pack uses dotted (`activity.aerobics.query`, 57). 68 `Cmd.*` refs in app, ~20 in VIK (`IntentResult.swift:59-125`) | Blocker |
| F6 | Three `fatalError`s on missing resources | `NLUSchema:99,104`, `IntentClassifierService:163`, `NLUEngineFactoryProvider:32` | Blocker for OTA |
| F7 | Static `Resources/` ≈ 29 MB in the SPM | `Package.swift` declares 12 resource rules; ADD §7 mandates zero | High |
| F8 | Bundled schema is a 3-intent stub | `Resources/nlu_schema.json` has `reminders.add`, `Cmd.MemoryChange`, `Cmd.SendMessage`; pack has 57 | High |
| F9 | `EntityExtractor` is 890 lines of hardcoded English | `weekdays` literal at :238, `tomorrow`/`tonight`/`noon` at :306-343, `timePatterns` at :766 | High |
| F10 | Host config overrides pack policy | `loadsSemanticRescue` defaults `true`; pack's `runtime/cascade.json` sets `semantic.enabled = false` for en-1.0.26 | Medium |
| F11 | Temperature is ambiguous in the pack | `calibration.json` → `0.653712`; `intent_classifier_weights.json` → `0.76546`. VIK reads the weights key | Medium |

### What the pack gives us that we are throwing away

The compiler emits two surfaces. Root `nlu_schema.json` / `nlu_entities.json` is a **lossy, English-inlined back-compat shim**; the v3 tree is the real contract.

| | root shim | v3 surface |
|---|---|---|
| Intents | 57 | 57 — **identical set, 0 action mismatches** |
| Fulfillment | English string inlined | response key → `capabilities/*/responses/<lang>.json` |
| Slot prompts | English string inlined, `MemoryName` | prompt key, `memory_name` |
| Entity values | flat English list | language-keyed `{"en": [...]}` |
| Lexicon | 3 keys | 8 keys — **shim loses `contractions` (50) and all of `datetime_grammar`** |
| Keyword rules | 32, untiered, 4 with empty regex | 37, `tier` 1/2 — **shim loses 9 rules** incl. exact anchors `^mute$`, `^find my phone$` |
| Confirmation policy | absent | 57-intent `never`/`when_ambiguous` map |

**Binding to the shim cannot produce a multi-language SDK**, because response text, slot prompts, and entity values are inlined English. We bind to v3.

### Decisions taken

| Decision | Choice |
|---|---|
| Pack surface | **v3 only**, with a one-key stopgap. See §1.1 — on inspection only `help_marker_guard` is genuinely orphaned; the other three are redundant, empty, or 93% duplicated in v3. |
| Taxonomy | Adopt pack labels internally; VIK never interprets a label. Data-driven alias applied **only at the facade edge**, opt-in, so the app's 68 `Cmd.*` refs keep working. |
| Cold start | **Strict zero resources.** VIK ships no models or JSON. No pack ⇒ typed throw, never a silent English fallback. |
| Scope | Full ADD in this phase, delivered as eight stacked, individually-reviewable work packages. |

### 1.1 The four root-only keys, resolved

These are **present in the pack**, but only inside the root `nlu_schema.json` shim — confirmed absent from every other JSON file in the bundle. Inspecting their contents collapses the problem to one key:

| Key | Contents in `pack-en-v1.0.26` | v3 equivalent | Action |
|---|---|---|---|
| `semantic_rescue_enabled` | `false` | `runtime/cascade.json` → `semantic.enabled = false` — **same value** | **Redundant.** Drop. Use `cascade.json`. |
| `polarity_guards` | `[]` | none | **Empty.** Nothing to port. Forward-declared hook; ignore until a pack populates it. |
| `uncertain_confirm` | 14 intents + `below_confidence 0.91`, `confirm_floor 0.55`, `cancel_message` | `runtime/policies.json` → `confirmation: when_ambiguous` is the **identical 14-intent set** | **93% covered.** Only the two scalars are missing. `cancel_message` is user-facing English and belongs in a responses catalog, not policies. |
| `help_marker_guard` | 1 marker regex + 11 intent→help redirects (`device.volume.increase` → `help.volume.show`) | **none** | **Genuinely orphaned.** Real disambiguation behaviour — "how do I turn up the volume" must route to help, not fire the command. |

So the stopgap is not "read four keys from root". It is:

- **Read `help_marker_guard` from root**, behind a single clearly-marked `LegacyShimSection` type we delete when §5.5 lands.
- **Read two scalars** (`below_confidence`, `confirm_floor`) from root; take the intent list from `policies.json`.
- Ignore `semantic_rescue_enabled` and `polarity_guards` entirely.

One consequence worth stating: `help_marker_guard` is a *behavioural* guard, not a tuning knob. Without it, 11 command intents misfire on help-phrased utterances. It must be in the v3 contract before we can drop the shim — this is §5.5, and it is not optional cleanup.

---

## 2. Trust chain — verified working

Confirmed empirically against `pack-en-v1.0.26`; implement exactly this order, and **verify before parsing anything**:

1. ed25519 verify `integrity/signature.sig` (64 bytes, `key_id: dev-key-golden`) over `integrity/manifest.sha256`.
2. Assert `bundle.json.checksums_root == sha256(integrity/manifest.sha256)` — **verified: matches**.
3. Verify all 61 manifest entries — **verified: 61/61 hashes match, 0 failures**.

Note: `bundle.json` itself is **not** in the manifest. It is bound only through `checksums_root`, so step 2 is what protects it. Do not skip it.

**Required input:** the ed25519 public key for `dev-key-golden` is not in the pack. Needs a distribution mechanism (pinned in VIK, or host-supplied at init). Recommend host-supplied `PackTrustPolicy` so key rotation does not require an SDK release.

---

## 3. Target architecture

Per ADD §7, with the domains the ADD names and subfolders where it is silent.

```text
VoiceAIKit/
├── Package.swift                        // NO resources block
└── Sources/VoiceAIKit/
    ├── Facade/
    │   ├── VoiceIntentSession.swift     // + updateBundle(url:), telemetryStream
    │   ├── VoiceIntentTypes.swift       // VoiceLanguage becomes a plain code+locale
    │   ├── VoiceIntentError.swift       // NEW — typed, replaces every fatalError
    │   └── IntentLabelAlias.swift       // NEW — opt-in, data-driven Cmd.* bridge
    ├── Audio/                            // unchanged, already language-neutral
    ├── NLU/
    │   ├── NLUEngine.swift              // all word-lists injected, no static defaults
    │   ├── IntentClassifierService.swift// takes ClassifierArtifacts, no Bundle
    │   ├── SemanticEmbedder.swift       // takes injected model+vocab URLs
    │   ├── EntityExtractor.swift        // driven by DateTimeGrammar (see WP5)
    │   └── KeywordMatcher.swift         // tiered rules from keywords/<lang>.json
    └── Data/                             // NEW — the whole data layer
        ├── NLUBundle.swift              // 1:1 with bundle.json
        ├── PackIntegrity.swift          // ed25519 + sha256 chain
        ├── BundleDataLoader.swift       // parse → ResolvedPack
        ├── ResolvedPack.swift           // immutable in-memory runtime model
        ├── PackSections.swift           // capabilities/runtime/lexicon/keyword decoders
        └── CoreMLCompiler.swift         // compileModel(at:) + Caches persistence
```

Deleted outright: `LanguagePack.swift`, `LanguagePackRegistry.swift`, `LocalizationLoader.swift`, `ClassifierBundle.swift`, `NLUSchema.swift`, `NLULexicon.swift`, and all of `Resources/`.

### Core types

```swift
// Version negotiation the ADD omits but the pack provides — enforce it.
public let VIKRuntimeContract = 1

public struct NLUBundle: Sendable, Decodable {   // bundle.json
    let bundleID: String, formatVersion: String, contentVersion: Int, channel: String
    let checksumsRoot: String
    let engineCompat: EngineCompat               // min/max_tested_runtime_contract
    let languages: [String: LanguageStatus]      // "en" -> .full
    let capabilities: [String: CapabilityRef]
    let models: ModelCatalog
    let telemetrySchemaVersion: Int
    let signatureInfo: SignatureInfo
    let requiredRuntimeFeatures: [String]        // MUST fail closed on unknown entries
}

// Fully resolved, language-bound, immutable. Nothing downstream touches the filesystem.
public struct ResolvedPack: Sendable {
    let manifest: NLUBundle
    let language: String
    let intents: [String: IntentDefinition]      // workflows.json ∪ capability.json actions
    let responses: [String: String]              // response key -> string, this language
    let entities: [String: EntityDefinition]     // language-resolved from shared/content.json
    let lexicon: PackLexicon                     // v3 shape, incl. contractions + datetime_grammar
    let keywordRules: [KeywordRule]              // tiered, with guards
    let policies: Policies                       // thresholds, limits, per-intent confirmation
    let cascade: CascadeConfig                   // stage enablement — authoritative over host config
    let routing: RoutingConfig                   // reprompt/give_up ladder
    let classifier: ClassifierArtifacts          // compiled .mlmodelc URL, weights, labels, calibration
    let telemetrySchema: TelemetrySchema
}
```

Two invariants worth stating in code, because both are violated today:

- **`ResolvedPack` is the only source of runtime behaviour.** No Swift constant may supply a word list, threshold, prompt, or regex. If the pack lacks it, we throw — we do not default.
- **VIK never interprets an intent label.** Labels are opaque strings routed by pack data. This is what makes `Cmd.*` removable and the next taxonomy change free.

---

## 4. Work packages

Ordered; each is independently reviewable and leaves the build green.

### WP0 — Contract lock (no code)
Freeze runtime contract v1. File the §5 asks with the Python team. Vendor `pack-en-v1.0.26` into `Tests/Fixtures/` as the golden pack. Agree pubkey distribution.

### WP1 — Data layer, shipped dark
`NLUBundle`, `PackIntegrity`, `PackSections`, `BundleDataLoader`, `ResolvedPack`, `VoiceIntentError`. Nothing wired into the engine; zero behaviour change. Fully unit-tested against the fixture pack: 61/61 checksum verification, `checksums_root` binding, `engine_compat` range rejection, unknown `required_runtime_features` fail-closed, missing-language rejection.
*Exit:* `BundleDataLoader.load(url:language:)` returns a populated `ResolvedPack` for the fixture, in tests only.

### WP2 — CoreML compilation and cache
`CoreMLCompiler` as an actor. `MLModel.compileModel(at:)` returns a temp URL the system reclaims — move the result into `Caches/VoiceAIKit/<bundleID>/<artifactSHA>/`. Key the cache on artifact SHA from the manifest, not path, so OTA invalidates correctly. Serialise concurrent compiles of the same artifact. Purge non-active bundle IDs. Compile off the main actor; expect seconds on first launch.
*Exit:* cold compile + warm cache-hit benchmarks on device; ANE warm-up dummy inference per ADD §4.

### WP3 — Classifier and stage cutover
`IntentClassifierService.init(artifacts:)` — no `Bundle`, no `fatalError`. Same for `SemanticEmbedder` / `SemanticClassifier`. `CascadeConfig` gates stages, overriding `VoiceIntentConfiguration.loadsSemanticRescue` (F10): with en-1.0.26, Stage 3 must not load. Validate `cascade.tfidf.output.dim == labels.count` (57) and fail closed on mismatch. Resolve F11 by pinning `calibration.json` as authoritative and logging when the weights key disagrees.

### WP4 — Engine cutover, static resources deleted
Replace `NLUEngineFactoryProvider` with `PackEngineFactory(pack: ResolvedPack)`. Delete `LocalizationLoader`, `LanguagePackRegistry`, `LanguagePack`, `ClassifierBundle`, `NLUSchema`, `NLULexicon`. Remove `NLUEngine.defaultUncertain/defaultNoIdioms/defaultCarriers` — injected or throw (fixes F3 at the root). Strip the `resources:` block and `Resources/` from `Package.swift` (F7). `VoiceIntentSession.init` now requires a pack URL and throws.
*Exit:* SPM checkout drops ~29 MB; no `Bundle.module` reference remains.

### WP5 — Entity extraction delocalisation ⚠️ largest risk
`EntityExtractor` (890 lines) is the deepest English coupling and the ADD does not address it. Introduce `DateTimeGrammar` decoded from `lexicons/<lang>.json → datetime_grammar` (`am_pm`, `articles`, `clock_idioms`, `day_anchors`, `quantifiers`, `relative_markers`, `relative_units`, `strip`, `time_of_day`) plus `contractions`. Replace literal weekday/anchor/period tables and the `timePatterns` regex array with grammar-compiled matchers.
*Note:* the pack's `datetime_grammar` shape differs from the existing `fr`/`de`/`da` overlay shape (`weekdays`, `months`, `numbers_0_to_31`, `ordinals_1_to_31`, `clock_hour_markers`). Either the compiler adds those keys or we lose date parsing for non-English. **This is a §5 blocker, not an implementation detail.** Gate with the existing `ExtractDateTimeMultilingualTests`.

### WP6 — Label boundary and alias
Strip `Cmd.*` from `IntentResult.swift:59-125`. SF Symbol and display-name mapping is presentation, not NLU — move to the host app or a pack-supplied `ui` section. Add `IntentLabelAlias`, a data table applied only on the way out of `VoiceIntentSession`, defaulted on so the app is untouched. Replace the `"Default Fallback Intent"` / `"OUT_OF_SCOPE"` literals (`NLUEngine:171,280`, `SemanticClassifier:95`, `IntentClassifierService:108`) with the pack's `sys.oos.fallback`.

### WP7 — Telemetry (ADD §6)
`NLUEvent` conforming to `telemetry/schema.json` v1 — enums are fixed and small: `lifecycle` (7), `outcome` (5), `routing_reason` (4), `stages` (4). Emit stage timings, decision trace, both confidence scores, OOS flags. Expose `session.telemetryStream`. Validate emitted enum values against the pack's schema at init and fail closed on drift.

### WP8 — OTA hot-swap (ADD §5)
`VoiceIntentSession.updateBundle(url:)`. Verify → resolve → compile in the background off the active session. Atomic swap of the engine reference under actor isolation. Emit `lifecycle` telemetry at each step. Retain the previous `ResolvedPack` until the first successful classification on the new one, then release — that gives us `rolled_back` for free. Never mutate an in-flight turn.

### WP9 — Verification
Non-negotiable, because this refactor changes classification inputs:
- **Parity harness:** run the pack's 342-row holdout through pre- and post-refactor pipelines; diff label + confidence per row. Target: zero label regressions, confidence delta within calibration tolerance.
- Regenerate `coreml_golden_fixtures.json` against pack artifacts.
- Negative-path suite: tampered file, bad signature, wrong `checksums_root`, `engine_compat` out of range, unknown `required_runtime_features`, missing language, corrupt `.mlpackage`. **Every one must throw a typed error — none may fall back to English.**
- Report-card gate: assert loaded pack's `report_card_summary.gates_passed`; refuse `channel: dev` packs in release builds.

---

## 5. Open items for the Python compiler team

Ordered by blocking severity.

1. **`models/semantic_head/shared/head.json` is declared in `bundle.json` but absent from the pack.** Only the `.mlpackage` ships. Either emit it or drop the `artifact` key.
2. **No MiniLM embedder artifact and no vocab file anywhere in the pack**, despite `embedder_id: minilm-l6-v2`. Under strict zero-static-resources, Stage 3 becomes unrunnable — currently masked because `cascade.json` disables semantic, but it blocks ever re-enabling it. Decide: ship the embedder + vocab in the pack, or define it as a host-supplied shared asset.
3. **`datetime_grammar` lacks `weekdays`, `months`, `numbers_0_to_31`, `ordinals_1_to_31`, `clock_hour_markers`** present in our existing fr/de/da overlays. Without them, non-English date parsing regresses (WP5).
4. **Temperature conflict:** `calibration.json` `0.653712` vs `intent_classifier_weights.json` `0.76546`. Which is authoritative?
5. **Give `help_marker_guard` a v3 home** (see §1.1). It is the only genuinely orphaned key and it drives real routing — 1 marker regex + 11 intent→help redirects. Suggested: `runtime/guards.json`, or a `guards` block in `runtime/routing.json` since it is a routing decision. Also add `uncertain_confirm`'s two scalars (`below_confidence`, `confirm_floor`) to `policies.thresholds`, and move `cancel_message` into a responses catalog so it localises. `semantic_rescue_enabled` and `polarity_guards` need no action — redundant and empty respectively. Bump `format_version` when done; that lets us delete the shim reader.
6. **ed25519 public key distribution** for `key_id`, plus rotation story.
7. **Confirm root `nlu_schema.json` / `nlu_entities.json` can be retired** once we are on v3, so packs stop carrying two representations.
8. `bundle.json` is not covered by `manifest.sha256` — confirm `checksums_root` is the intended binding, and confirm what `signature.sig` signs.

---

## 6. Risks

| Risk | Mitigation |
|---|---|
| Taxonomy migration silently changes routing | WP9 parity harness on the 342-row holdout, gated in CI before WP6 merges |
| First-launch CoreML compile adds seconds | WP2 benchmarks; host seeds a pack in its own bundle and pre-compiles during onboarding |
| Silent English fallback survives somewhere | WP9 negative-path suite asserts *throw*, never fallback; grep gate in CI for `?? []` on pack-derived fields |
| WP5 datetime regression for fr/de/da | Blocked on §5 item 3; do not merge WP5 until the compiler emits the missing grammar keys |
| Pack and SDK version drift in the field | `engine_compat` enforced at load; refuse and report rather than degrade |

---

## 7. Immediate next steps

1. Commit `pack-en-v1.0.26` — 64 staged files currently exist on no branch and are your only unbacked-up work.
2. Revert the `IntentClassifier-xyz` edit in `STT/STT/Services/IntentClassifierService.swift:121`, which currently forces the CoreML lookup to fail and silently degrades to the TF-IDF fallback.
3. Send §5 to the Python team — items 1–3 gate WP3 and WP5.
4. Start WP0/WP1 in parallel; they need nothing from the Python team.
