import MCP
import Foundation

extension ToolCommand {
	static let echo = ToolCommand(rawValue: "echo")
}

struct EchoTool: ToolImplementation {
	static let command: ToolCommand = .echo
	
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
	
	let arguments: CallTool.Parameters
	
	init(arguments: CallTool.Parameters) {
		self.arguments = arguments
	}
	
	func callAsFunction() async throws(ContentError) -> CallTool.Result {
		guard let message = arguments.strings.message else {
			throw ContentError.contentError(message: "Missing 'message' parameter")
		}
		
		let output = StructuredContentOutput(
			inputRequest: "echo: \(message)",
			metaData: nil,
			content: [["echo": message]])
		
		return output.toResult()
	}
}