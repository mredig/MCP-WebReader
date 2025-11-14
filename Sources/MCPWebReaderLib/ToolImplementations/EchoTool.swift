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
	
	let message: String
	
	init(arguments: CallTool.Parameters) throws(ContentError) {
		guard let message = arguments.strings.message else {
			throw .missingArgument("message")
		}
		self.message = message
	}
	
	func callAsFunction() async throws(ContentError) -> CallTool.Result {
		let output = StructuredContentOutput(
			inputRequest: "echo: \(message)",
			metaData: nil,
			content: [["echo": message]])
		
		return output.toResult()
	}
}