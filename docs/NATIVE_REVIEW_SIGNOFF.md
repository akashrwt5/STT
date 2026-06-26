# Native Review Sign-Off — Multilingual NLU (Phase 1)

Phase 2 implementation is blocked until all three language sections below show **APPROVED** status.

---

## French (fr)

**Reviewer name:** ___________________________
**Review date:** ___________________________

### Checklist

- [ ] `nlu_schema.fr.json` — fulfillment strings are natural French
- [ ] `nlu_schema.fr.json` — slot prompts are natural French
- [ ] `nlu_schema.fr.json` — `affirmative` and `negative` lists are complete and idiomatic
- [ ] `nlu_schema.fr.json` — follow-up `yes` / `no` lists are correct
- [ ] `nlu_entities.fr.json` — entity synonyms are accurate and culturally appropriate
- [ ] `nlu_lexicon.fr.json` — `uncertain` phrases sound natural to a native speaker
- [ ] `nlu_lexicon.fr.json` — `no_idioms` list correctly excludes false positives
- [ ] `nlu_lexicon.fr.json` — `carrier_phrases` patterns strip common filler correctly
- [ ] `nlu_lexicon.fr.json` — `decimal_hour_idioms` objects `{"phrase":...,"minutes":...}` are correct (e.g., "et quart" → +15, "moins le quart" → -15, "et demie" → +30)
- [ ] P0-6 regex `\b(\d{1,2})h(\d{2})?\b` correctly captures French written clock times ("9h", "15h30")
- [ ] Phase 2 datetime grammar fields are ready to specify (or gaps noted below)

**Notes / corrections:**

```
(free text)
```

**Status:** NEEDS REVIEW

---

## German (de)

**Reviewer name:** ___________________________
**Review date:** ___________________________

### Checklist

- [ ] `nlu_schema.de.json` — fulfillment strings are natural German
- [ ] `nlu_schema.de.json` — slot prompts are natural German
- [ ] `nlu_schema.de.json` — `affirmative` and `negative` lists are complete and idiomatic
- [ ] `nlu_schema.de.json` — follow-up `yes` / `no` lists are correct
- [ ] `nlu_entities.de.json` — entity synonyms are accurate and culturally appropriate
- [ ] `nlu_lexicon.de.json` — `uncertain` phrases sound natural to a native speaker
- [ ] `nlu_lexicon.de.json` — `carrier_phrases` patterns strip common filler correctly
- [ ] `nlu_lexicon.de.json` — `decimal_hour_idioms` string array is correct: `["Viertel nach", "halb", "Viertel vor", "dreiviertel"]`
- [ ] **CRITICAL**: Confirm "halb drei" = 2:30 (counts DOWN — subtract 30 min from named hour, not add)
- [ ] **CRITICAL**: Confirm "dreiviertel drei" = 2:45 (same count-down convention)
- [ ] P0-6 regex `\b(\d{1,2})\.(\d{2})\b` correctly captures German decimal clock times ("15.30", "9.00")
- [ ] P0-6 regex `\b(\d{1,2})h(\d{2})?\b` correctly captures German written clock times where applicable
- [ ] Phase 2 datetime grammar fields are ready to specify (or gaps noted below)

**Notes / corrections:**

```
(free text)
```

**Status:** NEEDS REVIEW

---

## Danish (da)

**Reviewer name:** ___________________________
**Review date:** ___________________________

### Checklist

- [ ] `nlu_schema.da.json` — fulfillment strings are natural Danish
- [ ] `nlu_schema.da.json` — slot prompts are natural Danish
- [ ] `nlu_schema.da.json` — `affirmative` and `negative` lists are complete and idiomatic
- [ ] `nlu_schema.da.json` — follow-up `yes` / `no` lists are correct
- [ ] `nlu_entities.da.json` — entity synonyms are accurate and culturally appropriate
- [ ] `nlu_lexicon.da.json` — `uncertain` phrases sound natural to a native speaker
- [ ] `nlu_lexicon.da.json` — `carrier_phrases` patterns strip common filler correctly
- [ ] `nlu_lexicon.da.json` — `decimal_hour_idioms` string array is correct ("kvart i", "halv", "kvart over")
- [ ] **CRITICAL**: Confirm "halv tre" = 2:30 (same count-down convention as German "halb")
- [ ] P0-6 regex `\b(\d{1,2})\.(\d{2})\b` correctly captures Danish decimal clock times ("15.30", "9.00")
- [ ] Phase 2 datetime grammar fields are ready to specify (or gaps noted below)

**Notes / corrections:**

```
(free text)
```

**Status:** NEEDS REVIEW

---

## Phase 2 Gate

Phase 2 implementation is blocked until all three language sections above show **APPROVED** status.

Once all three are approved, update this file by changing each `**Status:** NEEDS REVIEW` line to `**Status:** APPROVED — <reviewer> <date>` and open the Phase 2 implementation PR.
