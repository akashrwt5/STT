# Which configuration wins

One question, answered once: when the same number exists in more than one place,
which one does the running system actually use?

It used to be answered by reading code, and the answer was often "neither, there
is a third copy". `interrupt_threshold` was 0.68 in the pack, 0.68 in Python, and
0.75 in Swift, all three describing themselves as the same thing. The slot-attempt
budget was three independent `3`s. `routing.json` shipped a decision ladder no
engine implemented. This document exists so the next number does not do that.

Written against `pack-en-v1.0.48` and the trees at that time. Every claim is a
file you can go read; if one no longer matches, trust the code and fix this.

---

## The rule

**Content decides behaviour. Code decides mechanism. The host decides only what
the pack cannot express.**

Four tiers, and a value belongs to exactly one:

```
1. CONTENT SOURCE      language_packs/<lang>/platform.yaml      authored by a human
        │                (+ per-capability YAML under content/)
        │  nlu_compiler
        ▼
2. GENERATED PACK      nlu_schema.json      -> the reference Python engine
                       runtime/*.json       -> device runtimes (VoiceAIKit, Android)
        │
        ▼
3. RUNTIME CODE        fallbacks only, for a pack that omits the key
        │
        ▼
4. HOST CONFIG         VoiceIntentConfiguration — only what the format cannot carry
```

Tier 1 is the only place a person edits. Tiers 2 and 3 are consequences.

---

## Who owns what

| value | owner | reaches Python as | reaches Swift as |
|---|---|---|---|
| `confidence_threshold` 0.7 | `platform.yaml` | `nlu_schema.confidence_threshold` | `policies.thresholds.confidence` |
| `interrupt_threshold` 0.68 | `platform.yaml` | `nlu_schema.interrupt_threshold` | `policies.thresholds.interrupt` |
| `agreement_threshold` 0.5 | `platform.yaml` | `nlu_schema.agreement_threshold` | `policies.thresholds.agreement` *(unread — VIK-055)* |
| `oov_reject` / `oov_bypass` | `platform.yaml` | `nlu_schema.oov_*` | `policies.thresholds.oov_*` |
| `semantic_threshold` 0.4 | `platform.yaml` | `nlu_schema.semantic_threshold` | `policies.thresholds.semantic` *(unread — stage off)* |
| `max_slot_attempts` 3 | `platform.yaml` | `nlu_schema.max_slot_attempts` | `policies.limits.max_slot_attempts` |
| `semantic_rescue_enabled` | `platform.yaml` | `nlu_schema` | `cascade.json` → `stageEnabled(.semantic)` |
| confirmation policy | capability YAML | `nlu_schema.intents` | `policies.confirmation` |
| per-head temperature | fitted at build | `calibration.json` | `calibration.json[variant.temperatureKey]` |
| keywords / lexicons / responses | capability + language YAML | `nlu_schema` | `keywords/`, `lexicons/`, `capabilities/*/responses/` |

The two serialisations — `nlu_schema.json` and `runtime/policies.json` — are not
duplication. They are one source compiled for two runtimes that read different
files, emitted by the same build step, so they cannot drift.

---

## Where the PACK beats the host

A host may not turn on behaviour the pack was not measured with. The report card
that gates release (`meta/report_card.json` → `gates_passed`) was measured under
the pack's own settings, so overriding them invalidates the number that allowed
the pack to ship.

The live case is the semantic stage. `VoiceIntentConfiguration.loadsSemanticRescue`
exists, and when the pack disables the stage the request is **ignored, not
honoured** — `PackClassifierAdapter.loadStage3()` guards on
`pack.stageEnabled(.semantic)`. `PackCascade` says why in its own doc comment:

> The pack is authoritative over host configuration … a host asking for semantic
> rescue must not override a decision the pack's report card was measured under.

Same for every threshold: none is host-settable, by design.

## Where the HOST beats the pack

Only where the pack format has nowhere to put the value, and each case is a
recorded gap rather than a preference:

| host setting | why it is not in the pack |
|---|---|
| `fuzzyStopwords` | the format cannot carry it (VIK-007). English by default and wrong for any other language — it is what stops "the" matching the memory "three". The resolver logs an error when a non-English pack loads without one. |
| `trailingFunctionWords` | same shape: language-specific, no home in the format. `nil` means the built-in English set. |
| `commandSilence` / `slotAnswerSilence` | endpointing is a device/audio concern, not content |
| `trust` (`PackTrustPolicy`) | who the host is willing to trust cannot be asserted by the artifact being trusted |
| `audioSource`, `speaksPrompts`, `autoStopOnSilence` | application behaviour, not NLU |

If a value in this table ever gains a home in the pack format, it moves to tier 1
and the host setting becomes an override with an explicit reason — not a second
source of truth.

---

## What a fallback constant means

Both engines keep constants for values the pack owns. They mean **"this pack did
not carry the key"** — nothing else. They are never the live value, and reading
one instead of the pack's is the single most common way this system has broken.

Python marks them explicitly:

```python
# FALLBACK ONLY. The live value is CONTENT-OWNED (`interrupt_threshold` in
# platform.yaml) … read it from `self.interrupt_threshold`, not from here.
DEFAULT_INTERRUPT_THRESHOLD = 0.75
```

Swift takes the stricter line for values that must not be guessed:
`NLUEngine.init` requires `interruptThreshold` and `maxSlotAttempts` with **no
default at all**, so a caller cannot forget to pass the pack's value. That is the
same rule the file already states for its word lists — "NOTHING HERE DEFAULTS TO
ENGLISH ANY MORE" (VIK-001). A default is a value no language pack can override,
which is exactly how both of those got their wrong numbers.

**Rule of thumb:** if a constant in engine code has the same name as a pack field,
it is a fallback and reading it directly is a bug.

---

## Known violations, still open

Written down so they are not mistaken for the design.

- **`conf_gap_threshold` is read from the weights blob, not from policy.**
  `BundleDataLoader` reads `weights["conf_gap_threshold"] as? Double ?? 0.20`,
  directly beneath a comment saying "Thresholds come from the pack's policy table;
  the weights carry their own copy but policy is the contract." The code does the
  opposite of its comment, and `conf_gap_threshold` is in no policy table at all.
  (VIK-055)
- **The weights blob carries duplicate copies** of `conf_threshold`,
  `conf_gap_threshold` and `temperature`. Only the temperature is legitimately
  there (it is per-head, and `calibration.json` carries the authoritative one).
  The others are stale copies nothing should read.
- **`thresholds.agreement`, `thresholds.semantic` and `limits.session_timeout_s`**
  ship in every pack and are read by nothing in VoiceAIKit. (VIK-055)

---

## Adding a new tunable

1. Author it in `language_packs/<lang>/platform.yaml`.
2. Add it to **both** lists in `nlu_compiler/content_source.py` — `PLATFORM_KEYS`
   and the compiled layout. There is an assert between them precisely because
   `interrupt_threshold` was once accepted by one and dropped by the other,
   silently sending the engine back to its fallback.
3. Emit it into `runtime/policies.json` from the schema in
   `content_bundle.compile_policies` — read from `schema[...]`, never a literal.
   A literal there is how `max_slot_attempts` became a number nobody could change.
4. Read it in Python from `self.schema.get(...)`, with a `DEFAULT_*` constant as
   the pack-omits-the-key fallback only.
5. Read it in Swift from `pack.policies...`, passed into the engine's init. Prefer
   no default; if the value is optional, make its absence disable the behaviour
   rather than substitute a guess.
6. Never add a third copy. If a value appears to need one, the two runtimes are
   probably reading different files — which is fine — and the question is whether
   both come from the same build step. If they do not, that is the bug.

## Where things live

| | |
|---|---|
| authored content | `language_packs/<lang>/platform.yaml`, `content/capabilities/**` |
| compiled schema (Python) | `language_packs/<lang>/nlu_schema.json` |
| compiled policy (devices) | `<pack>/runtime/policies.json` |
| stage wiring | `<pack>/runtime/cascade.json` |
| calibration | `<pack>/models/intent/<lang>/calibration.json` |
| host settings | `VoiceIntentConfiguration` |
| trust / load policy | `PackTrustPolicy`, `PackLoadPolicy` |
