# Prompt: NLU pack contract requests from the iOS client (VoiceIntentKit)

> Copy everything below the line into the Python `nlu-compiler` repo session.

---

## Context

You are working on the Python `nlu-compiler` that produces `pack-<lang>-v<version>` NLU bundles. I am the iOS client team. We are refactoring **VoiceIntentKit** (a Swift Package) to be fully data-driven: it will ship **zero static resources** and derive 100% of its behaviour from a pack loaded at runtime, including OTA hot-swap.

Reference pack I audited: `pack-en-v1.0.26` — `format_version 3.0`, `compiler_version "nlu-compiler 1.0.0-content"`, `min_runtime_contract 1`, `git_commit 2b3519d1`.

**Decisions already made on our side, so you know what we will and won't consume:**

- We bind **exclusively to the v3 normalized surface** — `capabilities/`, `runtime/`, `lexicons/`, `keywords/`, `entities/`, `models/`, `telemetry/`, `integrity/`.
- We will **not** consume the flattened root `nlu_schema.json` / `nlu_entities.json`, except for one temporary stopgap (item A5).
- We adopt your dotted intent taxonomy (`activity.aerobics.query`) as-is and treat intent labels as opaque strings.
- We do the structure→string flattening **on device, after language selection**. Please do not add more pre-flattened, language-inlined outputs.

**Verification I already ran against `pack-en-v1.0.26`, so you can trust the findings below:**

- `integrity/manifest.sha256`: 61 entries, **61/61 hashes match**, 0 failures.
- `bundle.json.checksums_root == sha256(integrity/manifest.sha256)` — **matches**.
- v3 referential integrity is **clean**: 75/75 response keys resolve, 0 orphan strings, 57/57 action keys resolve, 4/4 slot entity refs resolve.
- Root shim vs v3 intent sets are identical (57 each), 0 action mismatches.

The v3 surface is well built. Everything below is either a genuine gap or a question — not a redesign request.

**Since the first draft of this document we read your compiler**, which answered several of our own questions and corrected one of our asks. Those items are struck through and kept in place rather than deleted, so you can see what we withdrew and why:

- **A4 retracted** — the two temperatures are deliberately separate (Review-F5 B8); we had asked you to unify them, which would have reintroduced a known blocker.
- **A5 implemented by us** — `runtime/guards.json` and the `uncertain_confirm` relocation are done in your repo; please review rather than build.
- **B1 answered** — `content_bundle.py` is unambiguously one-pack-per-language.
- **B6 (a) and (b) answered** — `build.py` shows the signature covers `manifest.sha256 ⊕ bundle.json`.

---

## Section A — Blockers

These block specific iOS work packages. Ordered by severity.

### A1. `models/semantic_head/shared/head.json` is declared but absent

`bundle.json` declares:

```json
"semantic_head": { "shared": { "artifact": "models/semantic_head/shared/head.json", "format": "json", ... } }
```

The file does not exist in the pack. Only `SemanticHead.mlpackage` ships, and only the `.mlpackage` is listed in `integrity/manifest.sha256`.

**Ask:** either emit `head.json`, or drop the `artifact`/`format` keys and let `coreml_artifact` stand alone. Our loader validates every declared artifact path and currently fails closed on this.

### A2. No MiniLM embedder artifact or vocab anywhere in the pack

`bundle.json` declares `"embedder_id": "minilm-l6-v2"`, but the pack contains **no embedder model and no vocab file** (I searched for any file matching `*vocab*` — zero hits). Today VoiceIntentKit ships `MiniLMEmbedder.mlpackage` + `minilm-vocab.txt` statically; under zero-static-resources those are being deleted.

This is currently masked because `runtime/cascade.json` sets `semantic.enabled = false`, so Stage 3 never loads. But it means **semantic rescue can never be re-enabled** by flipping that flag — the artifacts won't exist.

**Ask:** decide and document one of:

1. Ship the embedder + vocab in the pack (adds ~15–20 MB; needs a story for not duplicating it across language packs), **or**
2. Define it as a host-supplied shared asset, and add a `required_runtime_features` entry like `"embedder:minilm-l6-v2"` so we can fail closed when the host hasn't provisioned it.

We prefer (2), but we need it explicit either way. Please don't leave `enabled: false` as the de-facto answer.

### A3. `datetime_grammar` is missing the keys non-English date parsing needs

`lexicons/en.json → datetime_grammar` ships: `am_pm`, `articles`, `clock_idioms`, `day_anchors`, `quantifiers`, `relative_markers`, `relative_units`, `strip`, `time_of_day`.

Our existing (hand-authored) `fr`/`de`/`da` language data additionally requires:

| Key | Shape | Why |
|---|---|---|
| `weekdays` | `{"Monday": ["lundi","lun"], ...}` | resolve named days |
| `months` | `{"January": ["janvier","janv"], ...}` | resolve absolute dates |
| `numbers_0_to_31` | `{"7": ["sept"], ...}` | spelled-out numerals |
| `ordinals_1_to_31` | `{"1": ["premier","1er"], ...}` | "le premier mars" |
| `clock_hour_markers` | `["h","heures"]` | spaced clock forms ("18 h") — must stay distinct from `relative_units.hour` so duration words (de `Stunden`, da `timer`) aren't misread as clock time |
| `decimal_hour_idioms` | `[{"phrase":"halb","minutes":-30}, {"phrase":"midi","hour":12}]` | `halb drei`, `moins le quart`, `et quart` |
| `time_format` | `"12h"` \| `"24h"` | disambiguates bare hours |
| `conjunction` | `"Uhr"` \| `"og"` \| `"et"` | hour-minute joiner |

Without these, date/time slot filling regresses to English-only. **This blocks our entity-extraction delocalisation work package entirely** — it is the single largest item on our side and we cannot start it until the shape is agreed.

**Ask:** extend `datetime_grammar` with the above, for every language you emit. If you'd rather restructure than extend, propose a shape and we'll adapt — we just need one shape that covers all eight concerns.

### A4. ~~Temperature is ambiguous~~ — RETRACTED, but the pack drops the warning label

**We were wrong.** An earlier draft asked you to unify `calibration.json`'s `0.653712` with `intent_classifier_weights.json`'s `0.76546`. Reading the source `calibration.json` in your repo, the two are *deliberately* different and carry an explicit note:

> *"Confidence calibration for the SERVER/ONNX featurizer... The iOS/device temperature is fit separately against pruned device logits — the two calibrate different featurizers and must NOT be unified (Review-F5 blocker B8)."*

Unifying them would reintroduce a known blocker. Withdrawn — apologies for the noise.

**The narrower real issue:** the pack's copy of `models/intent/en/calibration.json` is a reduced projection that keeps `temperature` but strips `_note`, `provenance`, and `temperature_int8`. So a device-facing artifact ships the **server** temperature with nothing marking it as the server's, in a file path (`models/intent/<lang>/`) that reads as device-scoped.

**Ask:** either carry `_note` through into the pack, or name the fields unambiguously — `temperature_server` / `temperature_device` / `temperature_int8`. Related: the pack ships `model_int8.tflite` but **not** `temperature_int8` (0.649641), so anyone using the int8 model applies the wrong temperature.

### A5. `help_marker_guard` has no v3 home

Four keys exist **only** in the root shim `nlu_schema.json` and appear in no other file in the pack. Having inspected them, three need no action:

| Key | Value in `pack-en-v1.0.26` | Status |
|---|---|---|
| `semantic_rescue_enabled` | `false` | **Redundant** — `runtime/cascade.json` already says `semantic.enabled: false`. No action. |
| `polarity_guards` | `[]` | **Empty.** No action. |
| `uncertain_confirm` | 14 intents + 3 scalars | **93% covered** — the 14-intent list is byte-identical to `policies.confirmation`'s `when_ambiguous` set. |
| `help_marker_guard` | marker regex + 11 redirects | **Genuinely orphaned.** |

`help_marker_guard` is behavioural, not a tuning knob. It maps help-phrased utterances away from commands:

```json
{ "markers": "(how\\s+(to|do\\s+i|does|can\\s+i|is|would\\s+i)\\b)|(\\bguide\\b)|...",
  "pairs": { "device.volume.increase": "help.volume.show",
             "reminders.task.create":  "help.reminder.show", ... } }
```

Without it, 11 command intents fire on questions — a user asking *"how do I turn up the volume?"* actually gets the volume turned up.

**Status: IMPLEMENTED — please review rather than build.** We have made this change in your repo rather than asking you to schedule it, since it was blocking us and the compiler made it a small, contained edit. Four files:

| File | Change |
|---|---|
| `spec/bundle/3.0/guards.schema.json` | **new** — schema for the section |
| `packages/buildtime/nlu_compiler/validator.py` | +1 line, schema mapping (unmapped files hard-fail stage 1, so this was mandatory) |
| `packages/buildtime/nlu_compiler/content_bundle.py` | `compile_guards()`, `compile_confirm_responses()`, policies thresholds, driver wiring, docstring |
| `spec/bundle/3.0/policies.schema.json` | +2 threshold properties |

Placement, and the reasoning we would like you to challenge:

1. **`runtime/guards.json`**, not `runtime/routing.json`. Routing decides what to do when confidence is *low*; a guard fires regardless of confidence. Folding one into the other makes both harder to reason about. The file carries `help_marker` (markers + pairs) and `polarity` (emitted empty, so populating it later is content rather than a format change).
2. **`uncertain_confirm`'s two scalars → `policies.thresholds`** as `uncertain_confirm_below` / `uncertain_confirm_floor`. The intent list is *not* duplicated — `policies.confirmation` already carries it as the `when_ambiguous` set. `confirmation` says which intents; these say when.
3. **`cancel_message` → `capabilities/sys/responses/<lang>.json`** as `sys.confirm.cancelled`. It is text a user hears, and responses are the only per-language surface in the format — left in a policy table, a French pack would have shipped an English cancellation.
4. **`semantic_rescue_enabled` — no change.** `compile_cascade` already reads the same schema key. Confirmed redundant.
5. **`format_version` NOT bumped.** The validator resolves schemas from `spec/bundle/{format_version}/`, so 3.0 → 3.1 means duplicating the whole schema directory for an additive section. Old clients ignore `guards.json`; we detect it by presence. Overrule us if you want an explicit signal — the cheaper lever is a `required_runtime_features` entry, but that makes old clients *refuse* the pack, which is right only if guards are mandatory.

Verification on our side: build clean with **zero new coverage gaps** (the marker regex passes your portable-subset check), validator **0 errors**, packaged `.nlu` has `guards.json` in `manifest.sha256` with all hashes passing, `checksums_root` binding, and **ed25519 signature verifying**. Diff against `pack-en-v1.0.26` is exactly `+runtime/guards.json`, `+2` threshold keys, `+1` response key — everything else byte-identical, all 11 redirect pairs carried. `tests/test_content_bundle.py` 13/13; full suite 425 passed with 4 failures we could not have caused (2 from a sklearn version we installed, 2 in `packages/runtime` datetime tests our buildtime/spec-only change cannot reach).

We did **not** touch the root shim — `content_bundle.py:626` copies it deliberately under ADR-005 and the engine still reads those keys from it. Retiring it is B7.

### A6. The `open` entity flag does not survive into v3

`entities/shared/content.json` carries `type` and `fuzzy` per entity. The
flattened root shim carries a third that v3 does not:

```json
// nlu_entities.json
"remind": { "type": "enum", "fuzzy": true, "open": true }
// entities/shared/content.json
"remind": { "type": "list", "fuzzy": true }
```

`open` means the value list is a hint rather than a closed set, so a free-text
answer is acceptable. On our side it drives two behaviours: accepting the raw
utterance when structured extraction returns nil, and deriving a topic from the
first utterance so a reminder can be created in one turn instead of two.

Without it, `pack-en`'s `remind` entity reads as closed and the only reminders
that can be created are the six canned values in the gazetteer — "remind me to
call the plumber" cannot fill its own `name` slot. The failure is silent: the
slot re-prompts, then falls back.

This is the **only** remaining thing we cannot derive from v3 for the entity
work package. We have it as a host-supplied parameter today, which means the
correct value lives in application code rather than in the pack — exactly the
inversion this refactor exists to remove.

**Status: IMPLEMENTED — please review rather than build.** It was a projection
fix, as suspected. Two files:

| File | Change |
|---|---|
| `spec/bundle/3.0/entities.schema.json` | `+ "open": {"type":"boolean","default":false}` |
| `packages/buildtime/nlu_compiler/content_bundle.py` | `compile_entities` emits `"open": bool(spec.get("open"))` |

`additionalProperties: false` meant the schema change was mandatory, not
cosmetic — emitting the key alone would have failed stage 1. Verified: emitted
entities validate against the registry, `remind.open == true`, and an unknown
key is still rejected.

### A7. `dynamic_source` does not identify which builtin

Both dynamic entities declare identically:

```json
"sys.date_time":      { "type": "dynamic", "dynamic_source": "runtime.builtin" },
"sys.number_integer": { "type": "dynamic", "dynamic_source": "runtime.builtin" }
```

`runtime.builtin` tells us the runtime resolves it. It does not tell us *what*
to resolve it as, and a date parser and an integer parser are not
interchangeable — routing one to the other fills a slot with a well-formed value
of the wrong kind, which is worse than not filling it.

So the only signal is the entity id, which means ids carry semantics the format
does not acknowledge. A pack that renamed `sys.date_time` would break date
slots on device with no error anywhere.

**Status: IMPLEMENTED — please review rather than build.**
`compile_entities` now maps `sys.date-time → runtime.builtin.datetime` and
`sys.number-integer → runtime.builtin.integer`, and prints a warning (not an
error) when a builtin has no mapping, since an unmapped one is still legitimately
dynamic. No schema change: `stableId` already permits dotted segments.

**Still needed from you:** publish the vocabulary of builtin sources and the rule
for adding one, so we can decide whether an unknown builtin should be a refusal
or a degraded load. Same question as B5.

### A8. `lexicons/en.json → carriers` is missing a phrase the app has shipped for months

The pack lists five carrier patterns. The app's `defaultCarriers` has six. The
missing one:

```
^\s*set(?:\s+up)?\s+(?:an?\s+)?(?:reminder|alarm)\b\s*(?:to|about|for\s+(?!\d))?\s*
```

Carriers are stripped to expose a free-text topic, so the effect is:

| utterance | topic derived |
|---|---|
| "remind me to go to the airport" | `go to the airport` ✅ |
| "set a reminder to go to the airport" | `set a reminder to go to the airport` ❌ |

The second stores the whole utterance as the reminder's name. No error, no
re-prompt — a reminder that simply reads back wrong.

This is not a phrasing nobody thought of. It is in our git history
(`6572a90 fix: extend set-reminder carrier to also strip 'set an alarm'`), so
the app-side fix was made and never travelled upstream into your lexicon.

**Correction to the above, after reading your compiler: nobody forgot it.**
`language_packs/en/platform.yaml` has all six. `compile_lexicon` runs each
carrier through `portable_regex.check_pattern`, and this one contains
`for\s+(?!\d)` — negative lookahead, which `_FORBIDDEN` rejects by design. So it
has been dropped into a `gaps` line on **every build ever made**, while
`engine.py::_DEFAULT_CARRIERS` kept it. The reference and the bundles have been
disagreeing on ordinary input since the format was introduced. This is not an
iOS problem; it is a divergence between your two release trains.

**Status: IMPLEMENTED — please review rather than build.** Four files:

| File | Change |
|---|---|
| `language_packs/en/platform.yaml` | carrier rewritten without the `for` branch |
| `language_packs/en/nlu_schema.json` | same (one line; formatting untouched) |
| `packages/runtime/nlu_engine/engine.py` | `_DEFAULT_CARRIERS` matched to it |
| `packages/runtime/nlu_engine/engine.py` | `_build_leading_connector` → `^(?:…)(?:\s+|$)` |

Dropping the `for` branch rather than rewriting the guard: a leading "for" is
removed by `leading_connectors` one step later, so it was redundant. Verified
identical on 10/11 reminder utterances and **better** on the other two — today
"set a reminder for 5pm" creates a reminder literally named `"for"`, because
`^(?:…)\s+` cannot match a connector with nothing after it. The `$` fixes that.

**We also made a dropped carrier a BUILD FAILURE** rather than a coverage-gap
line (`compile_lexicon`). A carrier changes what the runtime extracts — it is not
metadata, and demoting it to a log entry is the reason this survived. Please push
back if you would rather it stayed a warning, but then it needs to reach whoever
consumes the bundle, not just whoever runs the build.

**Still worth doing on your side:** diff the app's historical carrier fixes
against every language you emit. If English drifted while people were working in
English, fr/de/da have drifted further and nobody will notice until a native
speaker uses the product.

### A9. There is no "uncertainty cues" table, and `negation_cues` is not one

We need to distinguish three answers to a yes/no confirmation: yes, no, and
*neither* ("not sure", "maybe", "I don't know") — the third re-asks rather than
guessing.

The pack has `affirmative`, `negative` and `negation_cues`. We initially read
`negation_cues` as the third list. It is not: it is words that NEGATE, and seven
of the twelve entries in your own `negative` list contain one as a substring
(`cancel`, `stop`, `don't`, `never mind`…). Wired that way, the words a user
says to cancel were classified as "neither", and the engine re-asked the same
question with no way out. We now pass an empty list, which is correct but means
"I don't know" is read as a decline.

Note that `spec/bundle/3.0/lexicons.schema.json` **already declares an
`uncertainty` property** — `compile_lexicon` simply never populates it. So the
format anticipated this and the compiler did not follow.

**Ask:** populate `uncertainty` from content, or drop the property from the
schema and confirm the contract is two-valued so we can stop looking for it.
Either answer is workable; a declared-but-never-emitted field is the worst of
the three, because it reads like a promise.

---

## Section B — Contract questions (answers needed, may need no code change)

### B1. ~~Is a pack per-language or multi-language?~~ — ANSWERED from your source

Settled by reading `content_bundle.py`: **one pack per language.** `--lang` is singular, `bundle_id = f"pack-{lang}-v{version}"`, and `languages` is constructed with exactly one key. The maps and `<lang>.json` filenames are real headroom, but nothing ever populates a second entry. No answer needed.

We also over-weighted this. Measured on `pack-en-v1.0.26`, **97% of the pack is language-specific** (4,843,224 bytes, dominated by the intent models) against **3% language-neutral** (134,896 bytes). Four packs duplicate ~405 KB total — noise next to ~4.8 MB of models per language, and per-language packs mean a monolingual user downloads 5 MB instead of 20 MB. The current model is the right one.

**Two small things that follow from it, and these we would like answered:**

1. `models/semantic_head/shared/` is 89,785 bytes labelled `shared`, but every per-language pack carries its own copy. Are those bytes **identical across packs**? If they can drift, a scope named `shared` would be silently per-language, and we would be caching it wrong.
2. `entities/shared/content.json` values are language-keyed (`{"en": [...]}`) but in a per-language pack that map only ever has one key. Confirm we should read `values[<pack language>]` and treat a missing key as a hard error — we do not want to guess when a `pack-fr` entity carries only an `"en"` list.

### B2. Which CoreML artifact should iOS load?

The pack ships both, undocumented:

- `IntentClassifier.mlpackage` — 302,634 bytes
- `IntentClassifier_full.mlpackage` — 1,078,062 bytes

`bundle.json` declares them as `coreml_artifact` and `coreml_full_artifact` respectively.

**Ask:** what distinguishes them — quantization, vocab size, label coverage? Which is the production iOS default, and what is the intended use of the other? If it's a size/accuracy tradeoff, please publish per-artifact accuracy in `meta/report_card.json` so we can choose on evidence rather than filename.

### B3. `telemetry/schema.json` defines enums but no events

The file contains only four enum lists (`lifecycle` 7, `outcome` 5, `routing_reason` 4, `stages` 4) and a version. ADD §6 requires us to emit `NLUEvent` conforming to this schema, but there is no event shape to conform to — no field names, types, or required/optional markers.

**Ask:** either publish the event schema (field names + types + which enum each field draws from), or confirm the contract is enums-only and the client owns the envelope. We need to know before we design `NLUEvent`, because changing an emitted telemetry shape after launch is expensive.

### B4. No locale / BCP-47 mapping anywhere in the pack

The pack speaks language codes (`en`). `SFSpeechRecognizer` / `SpeechAnalyzer` need BCP-47 (`en-US`). There is no `locale` key anywhere in `bundle.json`.

Right now that mapping is hardcoded in Swift, which is exactly the kind of language-specific code we're deleting. It also isn't always 1:1 — `en` → `en-US` vs `en-GB` is a product decision, not a lookup.

**Ask:** add a locale hint per language, e.g. `"languages": {"en": {"status": "full", "locales": ["en-US", "en-GB"], "default_locale": "en-US"}}`.

### B5. `required_runtime_features` vocabulary

Currently `[]`. We intend to **fail closed** on any entry we don't recognise — refusing to load rather than silently degrading.

**Ask:** confirm that's the intended semantics, and publish the vocabulary of possible values plus the rule for introducing new ones (does a new feature require a `min_runtime_contract` bump?).

### B6. Integrity chain — (a) and (b) ANSWERED from your source, (c) still open

`build.py` settles both: the signature is `key.sign(sha_table + manifest_bytes)` — ed25519 over **`manifest.sha256` concatenated with the canonical `bundle.json`**, not over the manifest alone as we had assumed — and `checksums_root = sha256(manifest.sha256)` is the intended binding for `bundle.json`, which is excluded from the hash table by design. We verified all three steps end-to-end against a pack built from your compiler: 58/58 hashes, root binds, signature verifies.

One clarification worth pinning: canonicalisation is load-bearing. `canonical_json` sorts keys, uses `(",",":")` separators, NFC-normalises strings, and appends `\n`. A client that re-serialises `bundle.json` before hashing will fail verification for reasons that look like corruption. We treat both files as **opaque bytes** and never re-encode — confirm that is the intended contract.

**Still needed (c):** how does the ed25519 public key for `key_id` reach the client, and what is the rotation story? `build.py`'s docstring says a production runtime "categorically refuses dev-signed artifacts (channel + signing-key id)" per ADR-005 Part 11, with production signing gated behind ND-8. We will implement that refusal — confirm the rule is exactly *`channel != "production"` **or** `key_id == "dev-key-golden"` ⇒ refuse*, and say whether the production key is pinned in the SDK or host-supplied. We'd prefer host-supplied, so rotation doesn't require an SDK release.

### B7. Can the root shim be retired?

Once we're fully on v3, is anyone else consuming root `nlu_schema.json` / `nlu_entities.json`? If not, retiring them removes ~18 KB and, more importantly, removes a second representation that can drift from v3.

**Ask:** confirm, and if yes give us a target version for removal.

---

## Section C — Hygiene

### C1. 56% of the pack is bytes iOS never reads

| File | Size | Read by iOS? |
|---|---|---|
| `model.onnx` | 1,478,675 | no |
| `model.tflite` | 1,076,952 | no |
| `model_int8.tflite` | 270,920 | no |
| `labels.pkl` | 1,403 | no (Python pickle) |
| **Total dead weight** | **2,827,950** | **56% of a 5,009,150-byte pack** |

This is downloaded over cellular on every OTA update.

**Ask:** support platform-scoped packs or a slicing mechanism — e.g. `pack-en-v1.0.26-ios` containing only CoreML + JSON, or a manifest-driven variant selector so the CDN can serve a subset. Signature and `checksums_root` need to cover the sliced form, so this is a compiler change, not something we can do client-side.

Separately: `labels.pkl` is a Python pickle being shipped to mobile clients. It duplicates `labels.json` and should not be in a client artifact at all.

### C2. `.DS_Store` files are shipped

Four present: `./.DS_Store`, `models/.DS_Store`, `models/intent/.DS_Store`, `models/intent/en/.DS_Store`. They're correctly excluded from `manifest.sha256`, but they shouldn't be in the pack. Add an exclusion to the packaging step.

### C3. Entity ID separator is inconsistent between surfaces

- v3 `entities/shared/content.json`: `sys.date_time`, `sys.number_integer` (underscore)
- root shim `nlu_entities.json`: `sys.date-time`, `sys.number-integer` (hyphen)

Harmless once we normalise at load, but it will bite whoever forgets. Please pick one — we'd suggest the v3 underscore form — and make the shim match while it still exists.

### C4. Pack delivery format

Our ADD assumes the host downloads and extracts an `nlu.zip`. Please confirm: is the archive's top-level directory the `pack-<lang>-v<version>` folder itself, or are the contents at the archive root? What compression? Is there a size or file-count ceiling we should design the extractor against?

---

## Definition of done

We're unblocked when:

1. **A1 and A2** are resolved in a published pack — the missing `head.json` and the absent embedder/vocab. A2 in particular needs a decision, not just a file.
2. **A3** has an agreed `datetime_grammar` shape. This is the largest item on our side and blocks our entire entity-delocalisation work package; nothing else on this list gates as much iOS work.
3. **A4** is a small labelling fix, not a blocker.
4. **A5** is reviewed and merged (or corrected — we may have placed something wrong).
5. **B2, B3, B6(c)** are answered in writing; B2 and B3 need no code change if current behaviour is intentional.
6. **C1** has a decision, not necessarily an implementation — we need to know whether to design for sliced packs.

Everything else is either answered or non-blocking. If A3 is going to take a while, tell us early: we can reorder our work packages around it, but only if we know before we start.

Please push back on anything here that's wrong or that we've misread. The v3 surface is clean and well built; these are gaps at the edges, not architectural objections.
