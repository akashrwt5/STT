// FoundationModelIntentClassifier.swift
// VoiceAIKit
//
// Classifies an utterance with Apple's on-device language model.
//
// The output is three fields, generated in this order:
//
//   inScope     true only when the utterance asks something of the app
//   intent      one of the pack's labels (an enum, so constrained decoding
//               cannot produce anything else)
//   selfRating  the model's own 0-1 rating; not calibrated
//
// `inScope` comes first so the model decides "is this for the app at all?"
// before it is pulled toward the nearest label. Constrained decoding must emit
// SOME label, and without this step an off-topic question ("why is Minnesota
// famous") lands on whichever label the decoder drifts to. When `inScope` is
// false the pack's fallback label is reported, whatever `intent` says.
//
// The field names sort alphabetically in the same order they are declared, so
// the order holds even if the framework orders properties by name.
//
// Each turn uses a new session. A session keeps every earlier turn in its
// transcript, and one turn's utterance must not influence the next turn's label.
//
// With `logsModelIO` on (development override only), each turn logs the
// utterance, the session transcript the framework actually built (instructions,
// prompt, response), and the raw JSON the model returned.

#if canImport(FoundationModels)
import FoundationModels
import Foundation
import os.log

actor FoundationModelIntentClassifier: GenerativeIntentClassifying {

    private static let log = Logger(subsystem: "com.voiceaikit", category: "FoundationModelClassifier")

    /// Property names in the output schema. Code identifiers, not user-facing text.
    private enum Field {
        static let inScope = "inScope"
        static let intent = "intent"
        static let selfRating = "selfRating"
    }

    private let labels: Set<String>
    private let outOfScopeIntent: String
    private let locale: Locale
    private let instructions: String?
    private let schema: GenerationSchema
    private let logsModelIO: Bool
    /// Set once the unavailability reason has been logged, so it is logged once
    /// per classifier rather than on every turn.
    private var loggedUnavailable = false

    /// - Parameters:
    ///   - labels: the pack's intent labels, the fallback label included. The
    ///     model can only answer with one of these.
    ///   - outOfScopeIntent: the pack's fallback label, reported when the model
    ///     says the utterance is not for the app.
    ///   - locale: the language the user speaks. The model is not asked at all
    ///     when it does not support this locale.
    ///   - instructions: text sent before the utterance, or nil for none.
    ///   - logsModelIO: log the model's input and output, the utterance included.
    /// - Throws: when the labels cannot form a schema (for example, none).
    init(labels: [String], outOfScopeIntent: String, locale: Locale,
         instructions: String?, logsModelIO: Bool = false) throws {
        self.labels = Set(labels)
        self.outOfScopeIntent = outOfScopeIntent
        self.locale = locale
        self.instructions = instructions
        self.logsModelIO = logsModelIO

        let root = DynamicGenerationSchema(
            name: "IntentVerdict",
            description: nil,
            properties: [
                DynamicGenerationSchema.Property(
                    name: Field.inScope,
                    description: nil,
                    schema: DynamicGenerationSchema(type: Bool.self, guides: []),
                    isOptional: false),
                DynamicGenerationSchema.Property(
                    name: Field.intent,
                    description: nil,
                    schema: DynamicGenerationSchema(name: "IntentLabel", description: nil, anyOf: labels),
                    isOptional: false),
                DynamicGenerationSchema.Property(
                    name: Field.selfRating,
                    description: nil,
                    schema: DynamicGenerationSchema(type: Double.self, guides: [.range(0...1)]),
                    isOptional: false),
            ])
        self.schema = try GenerationSchema(root: root, dependencies: [])
    }

    func prewarm() async {
        guard isAvailable() else { return }
        makeSession().prewarm(promptPrefix: nil)
    }

    func classify(_ text: String) async -> GenerativeVerdict? {
        guard isAvailable() else { return nil }

        let session = makeSession()
        // Greedy decoding: the same utterance gets the same answer on the same
        // model version, which is as repeatable as this model can be.
        let options = GenerationOptions(sampling: .greedy)
        if logsModelIO {
            Self.logLong("REQUEST utterance", text)
            Self.logLong("REQUEST instructions", instructions ?? "(none)")
            Self.logLong("REQUEST schema", String(describing: schema))
        }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let response = try await session.respond(schema: schema,
                                                     includeSchemaInPrompt: true,
                                                     options: options) { text }
            let latency = clock.now - start
            let content = response.content
            if logsModelIO {
                Self.logLong("RESPONSE json", content.jsonString)
                Self.logLong("TRANSCRIPT", String(describing: session.transcript))
            }
            let inScope = try content.value(Bool.self, forProperty: Field.inScope)
            let label = try content.value(String.self, forProperty: Field.intent)
            let rating = try content.value(Double.self, forProperty: Field.selfRating)

            // The schema already restricts the label; this check costs nothing
            // and keeps a label outside the pack from ever reaching the engine.
            guard labels.contains(label) else {
                Self.log.error("Model answered with a label outside the pack — ignoring it")
                return nil
            }
            let intent = GenerativeVerdict.resolvedIntent(inScope: inScope, label: label,
                                                          outOfScopeIntent: outOfScopeIntent)
            let confidence = min(max(rating, 0), 1)
            Self.log.notice("""
                verdict inScope=\(inScope, privacy: .public) \
                label=\(label, privacy: .public) \
                intent=\(intent, privacy: .public) \
                confidence=\(confidence, privacy: .public) \
                latency_ms=\(Self.milliseconds(latency), privacy: .public)
                """)
            return GenerativeVerdict(intent: intent, confidence: confidence, latency: latency)
        } catch {
            // Only the error's type is logged by default: an error's description
            // can carry the prompt.
            Self.log.error("Generation failed (\(String(reflecting: type(of: error)), privacy: .public))")
            if logsModelIO { Self.logLong("ERROR", String(describing: error)) }
            return nil
        }
    }

    // MARK: - Private

    private func makeSession() -> LanguageModelSession {
        if let instructions {
            return LanguageModelSession(model: SystemLanguageModel.default,
                                        instructions: { instructions })
        }
        return LanguageModelSession(model: SystemLanguageModel.default)
    }

    /// True when the model is ready AND supports the user's locale.
    ///
    /// Checked on every turn, not once: Apple Intelligence can be turned on or
    /// off, and the model downloaded, while the app runs. Asking a model that
    /// does not support the locale only earns an `unsupportedLanguageOrLocale`
    /// error and its latency, so it is not asked.
    private func isAvailable() -> Bool {
        let model = SystemLanguageModel.default
        // `if case` rather than `switch`, so a case Apple adds later reads as
        // unavailable instead of needing a code change.
        let availability = model.availability
        guard case .available = availability else {
            logUnavailableOnce("model unavailable: \(String(describing: availability))")
            return false
        }
        guard model.supportsLocale(locale) else {
            logUnavailableOnce("locale \(locale.identifier(.icu)) not supported by the on-device model")
            return false
        }
        return true
    }

    private func logUnavailableOnce(_ reason: String) {
        guard !loggedUnavailable else { return }
        loggedUnavailable = true
        Self.log.notice("On-device model not used (\(reason, privacy: .public)) — the pack classifier answers instead")
    }

    /// Logs `text` in numbered pieces. The unified log truncates a long
    /// message, and a schema or transcript is longer than one line can hold.
    private static func logLong(_ title: String, _ text: String) {
        let size = 800
        var pieces: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            pieces.append(String(text[start..<end]))
            start = end
        }
        if pieces.isEmpty { pieces = [""] }
        let total = pieces.count
        for (index, piece) in pieces.enumerated() {
            let number = index + 1
            log.notice("FM \(title, privacy: .public) [\(number)/\(total)] \(piece, privacy: .public)")
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}
#endif
