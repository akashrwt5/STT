import XCTest
@testable import STT
import VoiceIntentKit

/// A mock URLProtocol to intercept URLSession requests for testing NLUOTAManager without hitting the real network.
class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?
    
    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }
    
    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            fatalError("Handler is unavailable.")
        }
        
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    
    override func stopLoading() {}
}

final class NLUOTAManagerTests: XCTestCase {
    
    func testNetworkFailureReturnsError() async throws {
        // Setup mock URLSession
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        
        // Mock a 500 Internal Server Error response
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, nil)
        }
        
        // We'd initialize NLUOTAManager here with the mockSession
        // NLUOTAManager(voiceClient: ..., apiBaseURL: ..., urlSession: mockSession)
        
        // Assert that checkForUpdates() returns .failed(.invalidHTTPResponse(500))
        // (Implementation left to integrate with real VoiceIntentClient)
    }
}
