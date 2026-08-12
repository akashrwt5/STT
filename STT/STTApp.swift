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
        
        // Hoist files if the backend zipped a top-level folder instead of the raw contents
        let bundleURL = destination.appendingPathComponent("bundle.json")
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
    }
}

@main
struct STTApp: App {
    
    // Shared dependencies instantiated once at app launch
    private let voiceClient: VoiceIntentClient
    private let otaManager: NLUOTAManager
    
    init() {
        // Find the bundled seed pack from the SPM module
#if canImport(VoiceIntentSeedPackEN)
        let seedURL = VoiceIntentSeedPackEN.url ?? URL(fileURLWithPath: "/dev/null")
#else
        let seedURL = Bundle.main.url(forResource: "en", withExtension: "nlu") ?? URL(fileURLWithPath: "/dev/null")
#endif
        
        // Initialize dependencies
        let storageURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("VoiceIntentKit")
        let storage = try! PackStorageController(baseStorageURL: storageURL, fileManager: .default)
        let extractor = STTPackExtractor()
        let validator = PackValidator(extractor: extractor)
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
        Task {
            try? await client.start(for: "en")
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
            await manager.checkForUpdates(language: "en")
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
