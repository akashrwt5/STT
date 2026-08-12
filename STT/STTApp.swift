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

// A simple bridge between STT and VoiceIntentKit's engine protocol
class STTNLUEngineProvider: NLUEngineProvider {
    var isIdle: Bool { true } // Replace with actual STT engine state
    func load(modelPath: URL, vocabularyPath: URL) throws {
        // Replace with actual STT engine load
    }
    func smokeTest(modelPath: URL, vocabularyPath: URL) throws {
        // Replace with actual STT engine smoke test
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
        
        // Asynchronously boot the SDK so the active CoreML model is ready
        let client = self.voiceClient
        let language = Self.primaryOTALanguage
        Task {
            try? await client.start(for: language)
        }
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
