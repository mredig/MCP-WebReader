import MCP
import Foundation

/// Protocol for tool implementations
protocol ToolImplementation: Sendable {
	/// The tool command identifier
	static var command: ToolCommand { get }
	
	/// The MCP Tool definition
	static var tool: Tool { get }
	
	/// Arguments passed to the tool
	var arguments: CallTool.Parameters { get }
	
	/// Initialize with tool arguments
	init(arguments: CallTool.Parameters)
	
	/// Execute the tool and return structured output
	func callAsFunction() async throws(ContentError) -> CallTool.Result
}