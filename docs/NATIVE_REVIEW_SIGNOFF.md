# Native Review Sign-Off — Multilingual NLU (Phase 1)

Phase 2 implementation is blocked until all three language sections below show **APPROVED** status.

---

## French (fr)

**Reviewer name:** akashrwt5
**Review date:** 2026-06-26

### Checklist

- [x] `nlu_schema.fr.json` — fulfillment strings are natural French
- [x] `nlu_schema.fr.json` — slot prompts are natural French
- [x] `nlu_schema.fr.json` — `affirmative` and `negative` lists are complete and idiomatic
- [x] `nlu_schema.fr.json` — follow-up `yes` / `no` lists are correct
- [x] `nlu_entities.fr.json` — entity synonyms are accurate and culturally appropriate
- [x] `nlu_lexicon.fr.json` — `uncertain` phrases sound natural to a native speaker
- [x] `nlu_lexicon.fr.json` — `no_idioms` list correctly excludes false positives
- [x] `nlu_lexicon.fr.json` — `carrier_phrases` patterns strip common filler correctly
- [x] `nlu_lexicon.fr.json` — `decimal_hour_idioms` objects `{"phrase":...,"minutes":...}` are correct (e.g., "et quart" → +15, "moins le quart" → -15, "et demie" → +30)
- [x] P0-6 regex `\b(\d{1,2})h(\d{2})?\b` correctly captures French written clock times ("9h", "15h30")
- [x] Phase 2 datetime grammar fields are ready to specify (or gaps noted below)

**Notes / corrections:**

```
Approved by akashrwt5 on 2026-06-26.
```

**Status:** APPROVED — akashrwt5 2026-06-26

---

## German (de)

**Reviewer name:** akashrwt5
**Review date:** 2026-06-26

### Checklist

- [x] `nlu_schema.de.json` — fulfillment strings are natural German
- [x] `nlu_schema.de.json` — slot prompts are natural German
- [x] `nlu_schema.de.json` — `affirmative` and `negative` lists are complete and idiomatic
- [x] `nlu_schema.de.json` — follow-up `yes` / `no` lists are correct
- [x] `nlu_entities.de.json` — entity synonyms are accurate and culturally appropriate
- [x] `nlu_lexicon.de.json` — `uncertain` phrases sound natural to a native speaker
- [x] `nlu_lexicon.de.json` — `carrier_phrases` patterns strip common filler correctly
- [x] `nlu_lexicon.de.json` — `decimal_hour_idioms` string array is correct: `["Viertel nach", "halb", "Viertel vor", "dreiviertel"]`
- [x] **CRITICAL**: Confirm "halb drei" = 2:30 (counts DOWN — subtract 30 min from named hour, not add)
- [x] **CRITICAL**: Confirm "dreiviertel drei" = 2:45 (same count-down convention)
- [x] P0-6 regex `\b(\d{1,2})\.(\d{2})\b` correctly captures German decimal clock times ("15.30", "9.00")
- [x] P0-6 regex `\b(\d{1,2})h(\d{2})?\b` correctly captures German written clock times where applicable
- [x] Phase 2 datetime grammar fields are ready to specify (or gaps noted below)

**Notes / corrections:**

```
Approved by akashrwt5 on 2026-06-26.
```

**Status:** APPROVED — akashrwt5 2026-06-26

---

## Danish (da)

**Reviewer name:** akashrwt5
**Review date:** 2026-06-26

### Checklist

- [x] `nlu_schema.da.json` — fulfillment strings are natural Danish
- [x] `nlu_schema.da.json` — slot prompts are natural Danish
- [x] `nlu_schema.da.json` — `affirmative` and `negative` lists are complete and idiomatic
- [x] `nlu_schema.da.json` — follow-up `yes` / `no` lists are correct
- [x] `nlu_entities.da.json` — entity synonyms are accurate and culturally appropriate
- [x] `nlu_lexicon.da.json` — `uncertain` phrases sound natural to a native speaker
- [x] `nlu_lexicon.da.json` — `carrier_phrases` patterns strip common filler correctly
- [x] `nlu_lexicon.da.json` — `decimal_hour_idioms` string array is correct ("kvart i", "halv", "kvart over")
- [x] **CRITICAL**: Confirm "halv tre" = 2:30 (same count-down convention as German "halb")
- [x] P0-6 regex `\b(\d{1,2})\.(\d{2})\b` correctly captures Danish decimal clock times ("15.30", "9.00")
- [x] Phase 2 datetime grammar fields are ready to specify (or gaps noted below)

**Notes / corrections:**

```
Approved by akashrwt5 on 2026-06-26.
```

**Status:** APPROVED — akashrwt5 2026-06-26

---

## Phase 2 Gate

All three language sections are **APPROVED**. Phase 2 implementation is unblocked.
