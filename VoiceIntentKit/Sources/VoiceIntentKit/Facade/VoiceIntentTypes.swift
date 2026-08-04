// VoiceIntentTypes.swift
// VoiceIntentKit
//
// The public vocabulary of the package: configuration, language selection, session
// state, per-turn outcome, and the event stream element. These are the ONLY types a
// consuming app needs to know about — everything else (STT engine, 3-stage
// classifier, dialog manager, entity extractor) is an internal implementation detail.

import Foundation

// MARK: - Language

/// The single language the session operates in. Whichever language you pick must
/// have its models/overlays bundled in the package. English is fully self-contained;
/// `fr`, `de`, `da` ship with overlays and use the multilingual classifier.
///
/// This mirrors the design constraint "one model, one language": a session speaks
/// exactly one language, chosen here at construction time.
public enum VoiceLanguage: Sendable, Equatable {
    /// English — uses the dedicated English classifier + English word-lists.
    case english
    /// Any other bundled language. `code` is the NLU language tag ("fr", "de", "da");
    /// `locale` is the BCP-47 identifier the speech recognizer uses ("fr-FR", "de-DE").
    case language(code: String, locale: String)

    /// BCP-47 locale identifier used to configure the speech recognizer.
    public var localeIdentifier: String {
        switch self {
        case .english:                 return "en-US"
        case .language(_, let locale): return locale
        }
    }

    /// NLU language tag used to select word-lists, overlays, and entity data.
    public var languageCode: String {
        switch self {
        case .english:               return "en"
        case .language(let code, _): return code
        }
    }
}

// MARK: - Configuration

/// Everything needed to stand up a session.
///
/// `packProvider` and `trust` have no defaults, and that is the point. Both used
/// to be implicit — the pack came from `Bundle.module` and nothing was verified
/// — and an implicit default for either is a session that runs on data nobody
/// chose. Everything else defaults sensibly.
public struct VoiceIntentConfiguration: Sendable {
    /// The language the session operates in.
    public var language: VoiceLanguage
    /// Where this session's pack comes from. Required — there is no default,
    /// because every default here is a language, and a wrong default is a
    /// session that quietly speaks the wrong one.
    public var packProvider: any PackProvider
    /// Who is allowed to have signed this session's pack.
    ///
    /// Required, and deliberately not defaulted. The signing keys are the host's
    /// — pinning them in the SDK would mean an SDK release to rotate one — and a
    /// default that skips verification is a default that ships.
    public var trust: PackTrustPolicy
    /// Words never treated as typos when fuzzy-matching an enum entity.
    ///
    /// English by default and WRONG for any other language: the list is what
    /// stops "the" matching the memory "three", and a French pack needs
    /// le/la/de. The pack format has nowhere to carry it (VIK-007), so it is a
    /// parameter rather than a guess, and the resolver logs an error when a
    /// non-English pack is loaded without one.
    public var fuzzyStopwords: Set<String>?
    /// When true, follow-up questions and fulfillment messages are spoken aloud and
    /// the microphone auto-restarts to capture the user's answer (hands-free).
    public var speaksPrompts: Bool
    /// When true, a turn ends automatically shortly after the user stops speaking.
    /// When false, the session captions continuously until `stop()` is called.
    public var autoStopOnSilence: Bool
    /// When true, the MiniLM semantic-rescue stage (Stage 3) is loaded so
    /// low-confidence utterances get a second opinion. Costs ~16 MB of memory.
    public var loadsSemanticRescue: Bool

    public init(
        language: VoiceLanguage = .english,
        packProvider: any PackProvider,
        trust: PackTrustPolicy,
        speaksPrompts: Bool = true,
        autoStopOnSilence: Bool = true,
        loadsSemanticRescue: Bool = false,
        fuzzyStopwords: Set<String>? = nil
    ) {
        self.language = language
        self.packProvider = packProvider
        self.trust = trust
        self.speaksPrompts = speaksPrompts
        self.autoStopOnSilence = autoStopOnSilence
        self.loadsSemanticRescue = loadsSemanticRescue
        self.fuzzyStopwords = fuzzyStopwords
    }
}

// MARK: - Session state

public enum VoiceSessionState: Sendable, Equatable {
    /// Constructed but not yet started.
    case idle
    /// Loading models / resolving permissions before the first listen.
    case preparing
    /// Microphone is live and transcribing.
    case listening
    /// Running classification / dialog logic on a final transcript.
    case thinking
    /// Speaking a prompt or fulfillment message aloud.
    case speaking
    /// Stopped; resources released.
    case stopped
}

// MARK: - Stage breakdown

/// Per-stage detail from the 3-stage classifier — surfaced so the UI can show
/// which stage answered and each stage's score (like the app's English /
/// Multilingual debug view). All confidences are 0…1.
///
/// - `winningStage`: 1 = keyword rule, 2 = TF-IDF/CoreML, 3 = MiniLM semantic
///   rescue, `nil` = below every threshold (GenAI fallback).
/// - `stage2Score`: TF-IDF/CoreML confidence when evaluated. `nil` only for
///   pure Stage-1 keyword hits.
/// - `stage3Score`: MiniLM semantic confidence when evaluated. `nil` when
///   Stage 3 isn't loaded or Stage 2 already succeeded and Stage 3 was skipped.
public struct VoiceIntentStages: Sendable {
    public let winningStage: Int?
    public let stage2Score: Double?
    public let stage3Score: Double?
}

// MARK: - Per-turn outcome

/// The result of one conversational turn. A multi-turn exchange (e.g. setting a
/// reminder) produces several of these: one or more `followUp`/`confirmation` turns,
/// then a terminal `fulfilled` or `notUnderstood`.
public enum VoiceIntentTurn: Sendable {
    /// The dialog needs another piece of information. Speak/show `question`;
    /// `collected` holds the slots gathered so far.
    case followUp(question: String, collected: [String: String])
    /// A yes/no confirmation is required before acting.
    case confirmation(question: String)
    /// Fully resolved. `intent` is the label, `slots` the extracted parameters,
    /// `message` the fulfillment text, `confidence` the model score,
    /// `viaSemanticRescue` true when Stage 3 (MiniLM) produced it, and
    /// `stages` a per-stage breakdown for UI/debug display.
    case fulfilled(intent: String, slots: [String: String], message: String,
                   confidence: Double, viaSemanticRescue: Bool, stages: VoiceIntentStages?)
    /// Below threshold / out of scope. `fallbackURL` is the GenAI hand-off URL.
    /// `stages` carries whatever the classifier saw before falling back.
    case notUnderstood(fallbackURL: URL, confidence: Double, stages: VoiceIntentStages?)
    /// The user switched topics mid slot-filling; the named flow was abandoned.
    /// The new intent's outcome arrives as the next `.turn` event.
    case interrupted(cancelledIntent: String)
}

// MARK: - Event stream element

/// Emitted on `VoiceIntentSession.events`. Observe this single stream to drive your
/// entire UI: transcripts, dialog turns, state, and errors.
public enum VoiceIntentEvent: Sendable {
    case stateChanged(VoiceSessionState)
    /// In-progress transcript (may still change).
    case partialTranscript(String)
    /// Committed transcript for the turn just classified.
    case finalTranscript(String)
    /// The classified outcome of a turn.
    case turn(VoiceIntentTurn)
    /// A non-recoverable error terminated the session. `message` is human-readable.
    case error(message: String)
}
