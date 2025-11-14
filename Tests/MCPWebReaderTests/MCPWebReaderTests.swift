import XCTest
import MCP
import Logging
@testable import MCPWebReaderLib

final class MCPWebReaderTests: XCTestCase {
    var logger: Logger!
    
    override func setUp() async throws {
        logger = Logger(label: "com.webreader.tests")
        logger.logLevel = .debug
    }
    
    // MARK: - Tool Tests
    
    func testEchoTool() async throws {
        let server = createTestServer()
        await ServerHandlers.registerHandlers(on: server)
        
        let (serverTransport, clientTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        
        // Create a client and connect
        let client = Client(name: "TestClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)
        
        // Test echo tool
        let (content, isError) = try await client.callTool(
            name: "echo",
            arguments: ["message": "Hello, World!"]
        )
        
        XCTAssertFalse(isError ?? false, "Echo tool should not return an error")
        XCTAssertEqual(content.count, 1, "Should return one content item")
        
        if case .text(let text) = content.first {
            // Verify it's valid JSON with the echo field
            XCTAssertTrue(text.contains("\"echo\""), "Should contain echo field")
            XCTAssertTrue(text.contains("Hello, World!"), "Should contain the echoed message")
        } else {
            XCTFail("Expected text content")
        }
        
        await server.stop()
    }
    
    func testFetchPageTool() async throws {
        let server = createTestServer()
        await ServerHandlers.registerHandlers(on: server)
        
        let (serverTransport, clientTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        
        let client = Client(name: "TestClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)
        
        // Test fetch-page tool with example.com (a reliable test URL)
        let (content, isError) = try await client.callTool(
            name: "fetch-page",
            arguments: [
                "url": "https://example.com",
                "limit": 500
            ]
        )
        
        XCTAssertFalse(isError ?? false, "Fetch-page tool should not return an error")
        XCTAssertEqual(content.count, 1, "Should return one content item")
        
        if case .text(let text) = content.first {
            // Verify it's valid JSON with expected fields
            XCTAssertTrue(text.contains("\"text\""), "Should contain text field")
            XCTAssertTrue(text.contains("\"url\""), "Should contain url field")
            XCTAssertTrue(text.contains("\"contentLength\""), "Should contain contentLength field")
            XCTAssertTrue(text.contains("example.com"), "Should contain the URL")
            
            // Parse JSON to validate structure
            if let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                XCTAssertNotNil(json["text"], "Should have text field")
                XCTAssertNotNil(json["url"], "Should have url field")
                XCTAssertNotNil(json["contentLength"], "Should have contentLength field")
                XCTAssertNotNil(json["returnedLength"], "Should have returnedLength field")
                XCTAssertNotNil(json["offset"], "Should have offset field")
                XCTAssertNotNil(json["hasMore"], "Should have hasMore field")
            } else {
                XCTFail("Should be valid JSON")
            }
        } else {
            XCTFail("Expected text content")
        }
        
        await server.stop()
    }
    
    func testGetTimestampTool() async throws {
        let server = createTestServer()
        await ServerHandlers.registerHandlers(on: server)
        
        let (serverTransport, clientTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        
        let client = Client(name: "TestClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)
        
        let (content, isError) = try await client.callTool(
            name: "get-timestamp",
            arguments: [:]
        )
        
        XCTAssertFalse(isError ?? false, "Timestamp tool should not return an error")
        XCTAssertEqual(content.count, 1, "Should return one content item")
        
        if case .text(let text) = content.first {
            // Verify it's valid JSON with the timestamp field
            XCTAssertTrue(text.contains("\"timestamp\""), "Should contain timestamp field")
            
            // Extract and validate the ISO 8601 timestamp from JSON
            if let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let timestampString = json["timestamp"] {
                let formatter = ISO8601DateFormatter()
                XCTAssertNotNil(formatter.date(from: timestampString), "Should be valid ISO 8601 timestamp")
            } else {
                XCTFail("Should be valid JSON with timestamp field")
            }
        } else {
            XCTFail("Expected text content")
        }
        
        await server.stop()
    }
    
    // MARK: - Resource Tests
    
    func testListResources() async throws {
        let server = createTestServer()
        await ServerHandlers.registerHandlers(on: server)
        
        let (serverTransport, clientTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        
        let client = Client(name: "TestClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)
        
        let (resources, _) = try await client.listResources()
        
        XCTAssertGreaterThan(resources.count, 0, "Should have resources available")
        
        let uris = resources.map { $0.uri }
        XCTAssertTrue(uris.contains("webreader://status"), "Should have status resource")
        XCTAssertTrue(uris.contains("webreader://welcome"), "Should have welcome resource")
        XCTAssertTrue(uris.contains("webreader://config"), "Should have config resource")
        
        await server.stop()
    }
    
    func testReadStatusResource() async throws {
        let server = createTestServer()
        await ServerHandlers.registerHandlers(on: server)

        let (serverTransport, clientTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)
        
        // Test reading status resource
        let statusContents = try await client.readResource(uri: "webreader://status")
        XCTAssertEqual(statusContents.count, 1, "Should have one content item")

        if let firstStatusContent = statusContents.first, let text = firstStatusContent.text {
            let mimeType = firstStatusContent.mimeType

            XCTAssertEqual(mimeType, "application/json")
            XCTAssertTrue(text.contains("status"), "Status should contain 'status' field")
            XCTAssertTrue(text.contains("version"), "Status should contain 'version' field")
        } else {
            XCTFail("Expected text content")
        }
        
        await server.stop()
    }
    
    func testReadWelcomeResource() async throws {
        let server = createTestServer()
        await ServerHandlers.registerHandlers(on: server)

        let (serverTransport, clientTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)
        
        // Test reading welcome resource
        let welcomeContents = try await client.readResource(uri: "webreader://welcome")
        XCTAssertEqual(welcomeContents.count, 1, "Should have one content item")

        if let firstWelcome = welcomeContents.first, let text = firstWelcome.text {
            let mimeType = firstWelcome.mimeType
            XCTAssertEqual(mimeType, "text/plain")
            XCTAssertTrue(text.contains("Welcome"), "Welcome should contain greeting")
            XCTAssertTrue(text.contains("MCP WebReader"), "Welcome should mention server name")
        } else {
            XCTFail("Expected text content")
        }
        
        await server.stop()
    }
    
    func testReadConfigResource() async throws {
        let server = createTestServer()
        await ServerHandlers.registerHandlers(on: server)

        let (serverTransport, clientTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)
        
        // Test reading config resource
        let configContents = try await client.readResource(uri: "webreader://config")
        XCTAssertEqual(configContents.count, 1, "Should have one content item")

        if let firstConfig = configContents.first, let text = firstConfig.text {
            let mimeType = firstConfig.mimeType
            XCTAssertEqual(mimeType, "application/json")
            XCTAssertTrue(text.contains("MCP-WebReader"), "Config should contain server name")
            XCTAssertTrue(text.contains("capabilities"), "Config should contain capabilities")
        } else {
            XCTFail("Expected text content")
        }
        
        await server.stop()
    }
    
    // MARK: - Helper Methods
    
    private func createTestServer() -> Server {
        return Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(
                resources: .init(subscribe: true, listChanged: true),
                tools: .init(listChanged: true)
            )
        )
    }
}