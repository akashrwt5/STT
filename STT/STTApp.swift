//
//  STTApp.swift
//  STT

import SwiftUI
import BackgroundTasks
import VoiceIntentKit
import ZIPFoundation
#if canImport(VoiceIntentSeedPackEN)
import VoiceIntentSeedPackEN
#endif

/// Single source of truth for where OTA packs live on disk.
///
/// Both the OTA writer (`PackStorageController`, created in `STTApp`) and the read side
/// (`PackProviderForApp`, which serves the active pack to `VoiceIntentSession`) resolve the same
/// base here. This is what wires the two halves together: OTA activates a pack under this base,
/// and the very next `VoiceIntentSession` build reads it back from the same base. If these two
/// ever computed the location independently they would silently drift — which is exactly the bug
/// that left downloaded packs unused.
enum OTAStorageLocator {
    /// Application Support. `PackStorageController` appends `VoiceIntentKit/Packs` under it.
    static var baseStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}

/// Bridges STT to VoiceIntentKit's OTA engine hooks.
///
/// `smokeTest` is a real dress rehearsal: it loads the staged pack through the SAME path a live
/// `VoiceIntentSession` uses (`BundleDataLoader` + `PackEngineFactory`) and runs one classification.
/// If it throws, the OTA installer refuses to activate the pack — so a crypto-valid but
/// device-unloadable pack can never become `Current`.
final class STTNLUEngineProvider: NLUEngineProvider {
    /// Trust policy for the smoke-test load. Must match the session's policy.
    /// TODO: (Security) a production build must use a signing-key policy, not `.unverifiedForTesting`.
    private let trust: PackTrustPolicy = .unverifiedForTesting

    /// OTA activation never interrupts the live engine in this app — serving happens through
    /// `VoiceIntentSession`, which loads the freshest pack on its next build (apply-on-next-build).
    /// So the installer's idle-gate is always satisfiable here.
    var isIdle: Bool { true }

    func load(modelPath: URL, vocabularyPath: URL) throws {
        // No-op: this app serves via VoiceIntentSession, which loads packs itself. The OTA path is
        // publish-only and does not load into a separate live engine. Kept to satisfy the protocol.
    }

    func smokeTest(packRoot: URL, language: String) async throws {
        // Load the staged pack exactly as a live session would, and run one inference. Throwing here
        // aborts activation before the pack becomes `Current`.
        let pack = try BundleDataLoader.load(packAt: packRoot, language: language, trust: trust)
        let engine = try PackEngineFactory.makeEngine(pack: pack)
        _ = await engine.handle("hello")
    }
}

// A simple bridge for extracting the OTA ZIP payload
class STTPackExtractor: PackExtractor {
    func extract(from source: URL, to destination: URL) throws {
        // Use ZIPFoundation to unzip the payload directly into the staging directory
        try FileManager.default.unzipItem(at: source, to: destination)
        
        let bundleURL = destination.appendingPathComponent("bundle.json")
        
        // Step 1: Hoist files if the backend zipped a top-level folder instead of the raw contents
        if !FileManager.default.fileExists(atPath: bundleURL.path) {
            let contents = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            
            // Filter out macOS specific artifacts
            let validContents = contents.filter { $0.lastPathComponent != "__MACOSX" }
            
            if validContents.count == 1, let subDir = validContents.first, try subDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                let subContents = try FileManager.default.contentsOfDirectory(at: subDir, includingPropertiesForKeys: nil)
                for file in subContents {
                    try FileManager.default.moveItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
                }
                try FileManager.default.removeItem(at: subDir)
            }
        }
        
        // Step 2: Hotfix — Inject 'version' field if the Python backend hasn't added it yet.
        // TODO: Remove once Python backend ships the version field (TODO_Python.md)
        if FileManager.default.fileExists(atPath: bundleURL.path),
           let data = try? Data(contentsOf: bundleURL),
           let jsonObject = try? JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? NSMutableDictionary {
            if jsonObject["version"] == nil, let bundleId = jsonObject["bundle_id"] as? String,
               let range = bundleId.range(of: "-v") {
                jsonObject["version"] = String(bundleId[range.upperBound...])
                if let patched = try? JSONSerialization.data(withJSONObject: jsonObject) {
                    try patched.write(to: bundleURL)
                }
            }
        }
    }
}

@main
struct STTApp: App {
    
    // Shared dependencies instantiated once at app launch
    private let voiceClient: VoiceIntentClient
    private let otaManager: NLUOTAManager
    
    /// The primary language for OTA updates.
    /// TODO: Make this dynamic based on user's language selection when multilingual OTA is supported.
    private static let primaryOTALanguage = "en"
    
    init() {
        // Find the bundled seed pack from the SPM module
#if canImport(VoiceIntentSeedPackEN)
        let seedURL = VoiceIntentSeedPackEN.url ?? URL(fileURLWithPath: "/dev/null")
#else
        let seedURL = Bundle.main.url(forResource: "en", withExtension: "nlu") ?? URL(fileURLWithPath: "/dev/null")
#endif
        
        // Initialize dependencies.
        //
        // The base is Application Support itself. PackStorageController appends its own
        // `VoiceIntentKit/Packs` under it, so packs live at
        // `…/Application Support/VoiceIntentKit/Packs/{lang}/…`. Passing an already-`VoiceIntentKit`
        // suffixed URL here (as before) produced a doubled `VoiceIntentKit/VoiceIntentKit/Packs`
        // path — and, critically, a path NOTHING on the read side ever looked at.
        //
        // OTAStorageLocator.baseStorageURL is the single source of truth for this location so the
        // OTA writer (here) and the read side (PackProviderForApp) can never drift apart.
        let storageBase = OTAStorageLocator.baseStorageURL

        let storage: PackStorageController
        do {
            storage = try PackStorageController(baseStorageURL: storageBase, fileManager: .default)
        } catch {
            fatalError("[STT] Critical: Failed to initialize VoiceIntentKit storage at \(storageBase.path). Error: \(error.localizedDescription)")
        }

        let extractor = STTPackExtractor()
        // TODO: (Security / ADR-005 Part 11) A release build must pass a production PackTrustPolicy
        // carrying the real Ed25519 public key(s) and `refusesDevelopmentPacks: true`. This dev
        // policy skips signature verification — never ship it.
        let validator = PackValidator(extractor: extractor, trust: .unverifiedForTesting)
        let engineProvider = STTNLUEngineProvider()
        
        self.voiceClient = VoiceIntentClient(
            storage: storage,
            validator: validator,
            engineProvider: engineProvider,
            seedPackURL: seedURL
        )
        self.otaManager = NLUOTAManager(voiceClient: self.voiceClient, apiBaseURL: URL(string: "https://stingily-vowed-dutiful.ngrok-free.dev/api/v1/nlu")!)

        // NOTE: We deliberately do NOT call `voiceClient.start(...)` at launch. In this app the live
        // NLU is served by `VoiceIntentSession` (see PackageVoiceView), which loads the freshest pack
        // via `PackProviderForApp` on its next build — the "apply-on-next-build" model. The OTA path
        // is publish-only: it downloads, verifies and atomically activates a pack on disk; nothing
        // needs to be pre-loaded into a separate live engine here. `voiceClient` remains as the OTA
        // orchestration handle used by `otaManager`.
    }
    
    var body: some Scene {
        let manager = self.otaManager
        WindowGroup {
            STTTestView(otaManager: manager)
                .onAppear {
                    // Register the first background refresh when the app launches
                    Self.scheduleAppRefresh()
                }
                // Inject the OTA manager directly into the views that need it (or as an environment value if you build a custom key)
        }
        .backgroundTask(.appRefresh("com.starkey.stt.nlu.refresh")) {
            // 1. Recursive Registration: Always schedule the *next* background task
            Self.scheduleAppRefresh()
            
            // 2. Perform the update using the exact same shared otaManager instance
            await manager.checkForUpdates(language: Self.primaryOTALanguage)
        }
    }
    
    static func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.starkey.stt.nlu.refresh")
        // Schedule to run again in 24 hours
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)
        
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Could not schedule app refresh: \(error)")
        }
    }
}
