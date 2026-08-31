# Session handover — VoiceAIKit / IntentClassifier

**Written:** 21 August 2026 · **Branch:** `fix/ota-unification-and-concurrency` (STT), pushed to origin at `5a3305d`
**Replaces:** any earlier copy of this file. It is a snapshot, not a log — rewrite it, don't append.

---

## 1. The two repos and the two roles

| Repo | Path | Branch | Role to hold |
|---|---|---|---|
| **STT** (Swift/iOS) | `Starkey_Research/STT` | `fix/ota-unification-and-concurrency` | Principal iOS engineer |
| **IntentClassifier** (Python) | `Starkey_Research/STT-Python/IntentClassifier` | `feature/removeing_confirmation_code_APIVersion` | Principal Conversational AI Architect |

`VoiceAIKit` lives at `STT/VoiceAIKit` and is wired into `STT.xcodeproj` as an
`XCLocalSwiftPackageReference` (`project.pbxproj:648`). It is **not** a remote dependency.

The package is about to be linked into a second client app — **Engage / PVA** — to check
compatibility, **not to ship**. Its integration contract lives in `docs/pva-integration/`.

---

## 2. Standing instructions from Akash

These came up repeatedly. Treat them as binding.

- **Never commit or push until he asks.** He pushes himself, from Xcode.
- **Don't assume. Work on facts.** Verify what you don't know; never write code on speculation.
  He said this explicitly and it caught real errors — see §6.
- **Changes go inside the `VoiceAIKit` package** unless he says otherwise. App-side changes
  (`STT/`, `STT.xcodeproj`) need asking first, even when they are obviously correct.
- **One item at a time, and say what you're starting on before you start it.**
- He writes in Hinglish and expects replies in Hinglish. Technical terms stay in English.
- **Signing keys (B2) are deferred to production time.** Don't reopen it.
- When he says something is wrong, he is usually right and specific — read the code before
  defending an earlier answer.

---

## 3. Environment — read this before you try to build anything

**There is no Swift compiler reachable from this session.** Not in the cloud container, not on
the device VM. You cannot build, cannot run tests, cannot type-check. Write carefully, then ask
Akash to run it. Do not claim anything compiles.

**Package tests do not appear inside `STT.xcodeproj`.** Xcode does not expose a local package's
test targets from a host project — this is Xcode behaviour, not a config bug, and it cost this
session two wrong diagnoses. To run them:

```
# open STT/VoiceAIKit as its own Xcode project (File -> Open -> the folder with Package.swift)
# or:
cd STT/VoiceAIKit
xcodebuild test -scheme VoiceAIKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

**Two filesystems, no overlap.** `device_bash` runs on Akash's machine with his folders mounted;
the cloud `Bash` tool is a separate container. A file written by one is invisible to the other.
Everything in these two repos is reachable only through `device_bash`.

**`device_bash` cannot delete files.** `rm` fails with "Operation not permitted". Use `mv` into
`_to_delete/` and tell him. `git mv` works (rename is permitted); `git rm` does not.

**Git write operations need a lock workaround.** `.git/index.lock` and `.git/HEAD.lock` cannot be
unlinked, so git leaves them behind and the next command refuses to run. Park them first:

```bash
parklocks(){ for f in .git/index.lock .git/HEAD.lock; do [ -e "$f" ] && mv "$f" "$f.parked.$$" 2>/dev/null; done; }
parklocks; git add ...; parklocks; git commit ...
```

The `unable to unlink '.git/objects/../tmp_obj_*'` warnings are noise — the objects are written
correctly. Ignore them.

**`git add` aborts the WHOLE command on one bad pathspec.** It happened here: a commit landed
containing only a rename and no content, and it looked successful. **Always print
`git show --stat HEAD` after committing** and confirm the file list is what you meant.

---

## 4. What shipped this session

Five commits, all on origin:

```
5a3305d  docs(spec): abandoned is not turn-ending, and fallbackURL no longer exists
d76cfe8  docs: close VIK-034 and PUBLIC_API_PLAN 6.1, record the BGTask finding
42bd7e2  fix(ota): one model of bundle.json, and refuse a dev pack before it activates
bb43b93  docs: split the remaining work by repo, labelled against the Engage spike
30c9845  fix(package): make the VoiceAIKit scheme actually build and run the tests
```

**VIK-034 — one model of `bundle.json`.** There were two Decodable models of the same file.
`NLUPackManifest` (OTA path) had no `channel`, so the installer could not enforce
`refusesDevelopmentPacks` — a dev pack was downloaded, verified, staged and **activated**, and
refused only at the next session load. `NLUBundle` is now the single model everywhere;
`NLUPackManifest` and seven companion types are deleted; `PackValidating.extractAndValidate` and
`NLUPackInstaller.preparePack` return `PackIdentity`. Refusal moved to validation. The C8 token
guard matches on `checksums_root` rather than `version`. Verified on Simulator 26 and against a
live OTA install.

**Scheme fix.** `VoiceAIKit.xcscheme` built the library but never the test target, so its test
plan named a target the scheme could not reach.

**SPEC re-baseline (C3 + C5).** Two document defects, no code change. See §6 — the C5 one is a
correction to an earlier claim of mine.

**`PENDING_WORK_SPLIT.md`** (new, `docs/`) — every open item across both repos, split by owner and
labelled `COMPAT` / `GA` / `BACKLOG` on an axis separate from severity. **Start here** when asked
"what's left".

Current package surface: **31 public types, 147 public declarations** (was 107 / 686).
Bug trackers: **VoiceAIKit 27 fixed / 10 open**, **IntentClassifier 14 fixed / 13 open**.
Seed pack in the repo: `pack-en-v1.0.38-ios`.

---

## 5. What is open

Full detail in `docs/PENDING_WORK_SPLIT.md`. Summary:

**Pure iOS (3):** VIK-027 (facade turn state-machine untested), VIK-030 (`routing.json` decoded,
never read), VIK-012 (regex recompiled ~260× per utterance).

**Pure Python (13):** BUG-009 through BUG-021. The ones that reach a device: BUG-013 (`head.json`
declared, never shipped), BUG-014 (no MiniLM embedder despite `embedder_id`), BUG-019 (56% of pack
bytes unread), BUG-020 (a Python pickle shipped to phones).

**Both, Python first (7):** VIK-007, 008, 010, 011, 013, 014, 026 — iOS reproduces Python constants
that the pack does not carry.

### Blocking the Engage compatibility spike

Nothing in either tracker blocks *linking* the package. Four decisions to take **before** the spike
starts, not during:

1. **Is OTA in scope?** If yes, H5 (host must supply ZIP extraction) and H6 (~400 lines of host OTA
   layer that exist only as STT app code) come first.
2. **Is `loadsSemanticRescue` on?** If yes, BUG-014 first — stage 3 will silently no-op and the
   compatibility result will flatter us.
3. **C4** — the SPEC says `audioSource: .injected(...)`, the kit ships `.appProvided(sampleRate:)`.
   Deliberately left open: it is a naming decision to take **with** the Engage team.
4. **VIK-027** — the external-TTS handoff is the seam Engage runs on and it has no test at all.
   This is the largest remaining honest risk.

### Waiting on Akash

- **BGTask Info keys.** `STTApp.swift:182/192` registers and submits
  `com.starkey.stt.nlu.refresh`, but neither `BGTaskSchedulerPermittedIdentifiers` nor
  `UIBackgroundModes` exists anywhere in the project. Background OTA refresh **has never run**;
  foreground `checkForUpdates` works, which is why nobody noticed. Fix is two Info keys in the STT
  target — app-side, so it was recorded and not applied. He has not answered twice now; ask once
  more, then drop it.
- **Cleanup:** `VoiceAIKit/.build` (tracked-out but present), `.git/PARKED_*` and
  `.git/*.parked.*` litter from the lock workaround. `ota_unification.patch` is already gone.

### Deferred by decision

**B2 — production trust policy.** No production keypair exists; STT and `PackageVoiceView` both
hardcode `.unverifiedForTesting`. **Until this lands, an attacker-authored pack is a trusted pack.**
Correct call for a compatibility spike; it is *the* blocker for production. Do not reopen it — he
was explicit.

---

## 6. Where I was wrong — so you don't repeat it

Read this section. Every item cost time.

**The `VoiceAIKit` scheme — wrong twice.** I said it had no test action (it had a `<TestPlans>`
block), then fixed the scheme while Akash was looking at `STT.xcodeproj`, where package tests
cannot appear at all. I also deleted the aggregate `VoiceAIKit-Package` scheme, which was the only
one that worked, before understanding why. **Read both files completely before diagnosing, and
establish which project is actually open.**

**C5 — I called it a kit defect; it was a document defect.** I wrote that `.interrupted` violated
the SPEC's "exactly one terminal event per turn". The SPEC contradicted *itself*: §2.3, §6.2's
mapping table and Test Strategy IT-11 all describe two events; only §3.2.6 and the state diagram
said one. The kit matched the three — which were also the ones written against its real behaviour.
**Check whether the spec is self-consistent before concluding the code is wrong.**

**"No leftovers after the rename" — wrong.** I grepped for the old name and declared it clean;
three references survived in a scheme file I had not parsed. **Grep is not proof of absence when
you have not read the file formats involved.**

**An empty commit that looked successful.** `git add` aborted on one bad pathspec, so the commit
contained a rename and nothing else. Caught only because I printed the stat afterwards.

**Claiming completion without verification.** There is no compiler here. The correct sentence is
"I have not built this — please run it", every time.

---

## 7. If you want a next step

**VIK-027** is the highest-value remaining VoiceAIKit item and the only `COMPAT`-labelled one that
is pure iOS. It needs a mockable seam — a protocol for the coordinator and injection of the
`ConversationEngine` — so a test can push a synthetic final result, assert the `.speaking` hold,
call `hostDidFinishSpeaking()`, and assert listening resumes. It is a facade refactor with real
regression surface. Ask before starting; it touches working code Akash depends on.
