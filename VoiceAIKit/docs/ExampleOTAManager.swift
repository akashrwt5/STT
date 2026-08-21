import Foundation
import BackgroundTasks
import VoiceAIKit

// MARK: - IMPORTANT NOTICE
/*
 This file is provided as REFERENCE APPLICATION CODE ONLY.
 It is NOT part of the VoiceAIKit SDK and will not be compiled into it.
 
 Host Applications should copy this logic into their own codebase and adapt
 it to use their preferred networking stack (Alamofire, URLSession, etc.) and
 retry policies. Background scheduling remains the strict responsibility of
 the Host Application.
 */

struct UpdateResponse: Codable {
    let update_available: Bool
    let version: String?
    let download_url: String?
    let size_bytes: Int?
}

/// A reference manager demonstrating how the Host App coordinates the backend API and the VoiceAIKit SDK.
final class ExampleOTAManager {
    
    private let voiceClient: VoiceIntentClient
    private let urlSession: URLSession
    
    init(voiceClient: VoiceIntentClient) {
        self.voiceClient = voiceClient
        
        // Ensure the session is configured to automatically follow HTTP 302 Redirects for the AWS S3 URL.
        let config = URLSessionConfiguration.default
        self.urlSession = URLSession(configuration: config)
    }
    
    /// Entry point for a background fetch or daily boot check.
    func checkForUpdatesAndInstall() async {
        do {
            // 1. Polling the BFF
            let currentPackVersion = voiceClient.activePackVersion(for: "en") ?? "0.0.0"
            let apiURL = URL(string: "https://your-backend.com/api/v1/nlu/latest?lang=en&platform=ios&current_pack_version=\(currentPackVersion)")!
            let (data, _) = try await urlSession.data(from: apiURL)
            let response = try JSONDecoder().decode(UpdateResponse.self, from: data)
            
            // 2. Evaluate update availability
            guard response.update_available, let downloadString = response.download_url, let downloadURL = URL(string: downloadString) else {
                print("OTA: Device is up to date.")
                return
            }
            
            // Optional: Evaluate response.size_bytes to restrict downloading over cellular networks.
            
            // 3. Downloading the Payload (Handles HTTP 302 Redirects automatically)
            let (tempZipURL, _) = try await urlSession.download(from: downloadURL)
            
            // 4. Handoff to VoiceAIKit
            // This extracts the zip, parses bundle.json, and verifies Ed25519 signatures.
            let manifest = try await voiceClient.installer.preparePack(from: tempZipURL, language: "en")
            print("OTA: Prepared version \(manifest.version)")
            
            // 5. Activation Timing
            // We must never interrupt the user if they are currently speaking to the NLU engine.
            while !voiceClient.engineProvider.isIdle {
                try await Task.sleep(nanoseconds: 1_000_000_000) // Sleep for 1 second
            }
            
            // 6. Safe Activation
            // The SDK will run a smoke test. If successful, it atomically swaps the filesystem.
            try await voiceClient.installer.activatePreparedPack(language: "en")
            print("OTA: Successfully activated!")
            
        } catch {
            print("OTA Update Failed: \(error.localizedDescription)")
            // Retry Policy: Intentionally left to the Host Application.
            // You may schedule another background task, retry immediately, or wait for next boot.
        }
    }
}

// MARK: - Background Task Registration (Reference)

/*
 
 /// Call this in your AppDelegate's `didFinishLaunchingWithOptions`
 func registerBackgroundTasks() {
     BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.yourapp.nlu.refresh", using: nil) { task in
         guard let appRefreshTask = task as? BGAppRefreshTask else { return }
         self.handleAppRefresh(task: appRefreshTask)
     }
 }
 
 func handleAppRefresh(task: BGAppRefreshTask) {
     scheduleNextRefresh()
     
     let otaManager = ExampleOTAManager(voiceClient: self.sharedVoiceClient)
     
     Task {
         await otaManager.checkForUpdatesAndInstall()
         task.setTaskCompleted(success: true)
     }
     
     task.expirationHandler = {
         // Optionally cancel the URLSession download if iOS runs out of background time.
     }
 }
 
 func scheduleNextRefresh() {
     let request = BGAppRefreshTaskRequest(identifier: "com.yourapp.nlu.refresh")
     request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60) // Check once a day
     
     do {
         try BGTaskScheduler.shared.submit(request)
     } catch {
         print("Could not schedule app refresh: \(error)")
     }
 }
 */
