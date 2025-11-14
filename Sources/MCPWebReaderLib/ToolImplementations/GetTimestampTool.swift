import MCP
import Foundation

extension ToolCommand {
	static let getTimestamp = ToolCommand(rawValue: "get-timestamp")
}

/// Example tool that returns the current timestamp
///
/// This demonstrates a tool with no required parameters.
/// The `init` still conforms to the protocol but doesn't need to extract anything.
struct GetTimestampTool: ToolImplementation {
	static let command: ToolCommand = .getTimestamp
	
	// JSON Schema reference: https://json-schema.org/understanding-json-schema/reference
	static let tool = Tool(
		name: command.rawValue,
		description: "Returns the current timestamp in ISO 8601 format",
		inputSchema: .object([
			"type": "object",
			"properties": .object([:])
		])
	)
	
	/// Initialize with no required parameters
	/// - Parameter arguments: The raw MCP arguments (unused for this tool)
	/// - Throws: `ContentError` if initialization fails
	init(arguments: CallTool.Parameters) throws(ContentError) {
		// No parameters needed for this tool
	}
	
	/// Execute the tool
	/// - Returns: Structured JSON result with current timestamp
	func callAsFunction() async throws(ContentError) -> CallTool.Result {
		let timestamp = ISO8601DateFormatter().string(from: Date())
		
		let output = StructuredContentOutput(
			inputRequest: "get-timestamp",
			metaData: nil,
			content: [["timestamp": timestamp]])
		
		return output.toResult()
	}
}