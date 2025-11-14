import MCP
import Foundation

extension ToolCommand {
	static let echo = ToolCommand(rawValue: "echo")
}

/// Example tool that echoes back a message
///
/// This demonstrates the basic pattern for creating MCP tools:
/// 1. Extend `ToolCommand` with a static constant for your command
/// 2. Define the `Tool` with proper JSON Schema for parameters
/// 3. Extract and validate parameters in `init`
/// 4. Implement business logic in `callAsFunction`
struct EchoTool: ToolImplementation {
	static let command: ToolCommand = .echo
	
	// JSON Schema reference: https://json-schema.org/understanding-json-schema/reference
	static let tool = Tool(
		name: command.rawValue,
		description: "Echoes back the provided message",
		inputSchema: .object([
			"type": "object",
			"properties": .object([
				"message": .object([
					"type": "string",
					"description": "The message to echo back"
				])
			]),
			"required": .array([.string("message")])
		])
	)
	
	// Typed properties extracted from parameters
	let message: String
	
	/// Initialize and validate parameters
	/// - Parameter arguments: The raw MCP arguments
	/// - Throws: `ContentError` if required parameters are missing or invalid
	init(arguments: CallTool.Parameters) throws(ContentError) {
		guard let message = arguments.strings.message else {
			throw .missingArgument("message")
		}
		self.message = message
	}
	
	/// Execute the tool
	/// - Returns: Structured JSON result
	func callAsFunction() async throws(ContentError) -> CallTool.Result {
		let output = StructuredContentOutput(
			inputRequest: "echo: \(message)",
			metaData: nil,
			content: [["echo": message]])
		
		return output.toResult()
	}
}