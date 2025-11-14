import MCP
import Foundation

extension ToolCommand {
	static let getTimestamp = ToolCommand(rawValue: "get-timestamp")
}

struct GetTimestampTool: ToolImplementation {
	static let command: ToolCommand = .getTimestamp
	
	static let tool = Tool(
		name: command.rawValue,
		description: "Returns the current timestamp in ISO 8601 format",
		inputSchema: .object([
			"type": "object",
			"properties": .object([:])
		])
	)
	
	let arguments: CallTool.Parameters
	
	init(arguments: CallTool.Parameters) {
		self.arguments = arguments
	}
	
	func callAsFunction() async throws(ContentError) -> CallTool.Result {
		let timestamp = ISO8601DateFormatter().string(from: Date())
		
		let output = StructuredContentOutput(
			inputRequest: "get-timestamp",
			metaData: nil,
			content: [["timestamp": timestamp]])
		
		return output.toResult()
	}
}