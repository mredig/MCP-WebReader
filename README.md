# MCP-WebReader

A Swift MCP (Model Context Protocol) server for fetching and parsing web content.

## TLDR - Quick Start

**Install via Homebrew:** (macos only)
Use brew to get the [pizza tool package](https://github.com/mredig/homebrew-pizza-mcp-tools), containing this (and other tools).

```bash
brew tap mredig/pizza-mcp-tools
brew update
brew install mcp-webreader
```

**Or build from source:**
```bash
# Clone and build
git clone <your-repo-url>
cd MCP-WebReader
swift build
```

**Add to Zed settings** (`~/.config/zed/settings.json`): (recommended)

(In Zed, `Add Custom Server` and provide the following snippet)
```json
{
  /// The name of your MCP server
  "webreader": {
    /// The command which runs the MCP server
    "command": "mcp-webreader", // if building yourself, you'll need to provide the whole path
    /// The arguments to pass to the MCP server
    "args": [],
    /// The environment variables to set
    "env": {}
  }
}
```

**or Claude**
```json
# Add to Claude Desktop config at:
# ~/Library/Application Support/Claude/claude_desktop_config.json
{
  "mcpServers": {
    "webreader": {
      "command": "/path/to/MCP-WebReader/.build/debug/mcp-webreader"
    }
  }
}
```

## Adding Your Own Tools

1. **Create a new file** in `Sources/MCPWebReaderLib/ToolImplementations/`
2. **Extend `ToolCommand`** with your command name
3. **Implement `ToolImplementation` protocol**
4. **Add to registry** in `ToolRegistry.swift`

### Example: Adding a Calculator Tool

```swift
// CalculatorTool.swift
import MCP
import Foundation

extension ToolCommand {
    static let calculate = ToolCommand(rawValue: "calculate")
}

struct CalculatorTool: ToolImplementation {
    static let command: ToolCommand = .calculate
    
    // JSON Schema reference: https://json-schema.org/understanding-json-schema/reference
    static let tool = Tool(
        name: command.rawValue,
        description: "Performs basic arithmetic operations",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "operation": .object([
                    "type": "string",
                    "enum": .array([.string("add"), .string("subtract"), .string("multiply"), .string("divide")]),
                    "description": "The operation to perform"
                ]),
                "a": .object([
                    "type": "number",
                    "description": "First number"
                ]),
                "b": .object([
                    "type": "number",
                    "description": "Second number"
                ])
            ]),
            "required": .array([.string("operation"), .string("a"), .string("b")])
        ])
    )
    
    let operation: String
    let a: Double
    let b: Double
    
    init(arguments: CallTool.Parameters) throws(ContentError) {
        guard let operation = arguments.strings.operation else {
            throw .missingArgument("operation")
        }
        guard let a = arguments.doubles.a else {
            throw .missingArgument("a")
        }
        guard let b = arguments.doubles.b else {
            throw .missingArgument("b")
        }
        
        self.operation = operation
        self.a = a
        self.b = b
    }
    
    func callAsFunction() async throws(ContentError) -> CallTool.Result {
        let result: Double
        switch operation {
        case "add": result = a + b
        case "subtract": result = a - b
        case "multiply": result = a * b
        case "divide":
            guard b != 0 else {
                throw .contentError(message: "Division by zero")
            }
            result = a / b
        default:
            throw .contentError(message: "Unknown operation: \(operation)")
        }
        
        let output = StructuredContentOutput(
            inputRequest: "\(operation): \(a) and \(b)",
            metaData: nil,
            content: [["result": result]])
        
        return output.toResult()
    }
}
```

Then add to `ToolRegistry.swift`:
```swift
static let registeredTools: [ToolCommand: any ToolImplementation.Type] = [
    .echo: EchoTool.self,
    .getTimestamp: GetTimestampTool.self,
    .calculate: CalculatorTool.self,  // ← Add your tool here
]
```

That's it! Rebuild and your tool is available.

## Project Structure

```
MCP-WebReader/
├── Sources/MCPWebReaderLib/
│   ├── ToolRegistry.swift              ← Register your tools here
│   ├── ToolCommand.swift                ← Tool command constants
│   ├── ToolImplementations/             ← Put your tools here
│   │   ├── ToolImplementation.swift     ← Protocol definition
│   │   ├── EchoTool.swift               ← Example tool
│   │   └── GetTimestampTool.swift       ← Example tool
│   └── Support/                         ← Implementation details (don't need to modify)
│       ├── ServerHandlers.swift
│       ├── ToolSupport.swift
│       └── ...
```

## Tool Implementation Pattern

Every tool follows the same pattern:

1. **Extend `ToolCommand`** - Define your command identifier
2. **Define `static let tool`** - MCP Tool definition with JSON Schema
3. **Extract parameters in `init`** - Validate and convert to typed properties
4. **Implement `callAsFunction`** - Your tool's business logic

### Parameter Extraction

Use the `ParamLookup` helpers to extract typed parameters:

```swift
arguments.strings.myStringParam    // String?
arguments.integers.myIntParam      // Int?
arguments.doubles.myDoubleParam    // Double?
arguments.bools.myBoolParam        // Bool?
```

### Error Handling

Throw `ContentError` for all tool errors:

```swift
throw .missingArgument("paramName")
throw .mismatchedType(argument: "paramName", expected: "string")
throw .initializationFailed("custom message")
throw .contentError(message: "custom error")
throw .other(someError)
```

## Requirements

- Swift 6.0+
- macOS 13.0+

## Testing

```bash
swift test
```

## Available Tools

### Web Content Tools

#### `fetch-page`
Fetches web page content using URLSession (no JavaScript rendering). Can operate in two modes: **fetch mode** (returns paginated content) or **search mode** (finds and returns all matches with context).

**Parameters:**
- `url` (required, string) - The URL to fetch (must be http:// or https://)
- `query` (optional, string) - Search query. When provided, searches entire webpage and returns match positions with context. When omitted, returns paginated content.
- `offset` (optional, integer) - Starting character position for pagination (default: 0). **Ignored when `query` is provided.**
- `limit` (optional, integer) - Maximum number of characters to return (default: 10000). **Ignored when `query` is provided.**
- `includeMetadata` (optional, boolean) - Include page metadata like title and description (default: true)

**Fetch Mode (no query):**
Returns paginated content from the webpage.
```json
{
  "text": "Page content here...",
  "title": "Page Title",
  "description": "Meta description if available",
  "url": "https://example.com",
  "contentLength": 12345,
  "returnedLength": 500,
  "offset": 0,
  "hasMore": true,
  "nextOffset": 500
}
```

**Search Mode (with query):**
Searches the entire webpage and returns all matches with surrounding context.
```json
{
  "query": "search term",
  "matches": [
    {
      "position": 1234,
      "context": "...text before search term text after..."
    },
    {
      "position": 5678,
      "context": "...another match context..."
    }
  ],
  "totalMatches": 2,
  "title": "Page Title",
  "description": "Meta description if available",
  "url": "https://example.com",
  "webpageLength": 12345
}
```

**Note:** This tool does not execute JavaScript. For pages that require JavaScript rendering, use `render-page` instead (coming soon).

### Example Tools
- `echo` - Echoes a message back (demonstrates parameter handling)
- `get-timestamp` - Returns current ISO 8601 timestamp (demonstrates no-parameter tools)

### Resources
- `webreader://status` - Server status (JSON)
- `webreader://welcome` - Welcome message (text)
- `webreader://config` - Server configuration (JSON)

## Usage Examples

### Fetch a webpage
```json
{
  "tool": "fetch-page",
  "arguments": {
    "url": "https://example.com"
  }
}
```

### Fetch with pagination
```json
{
  "tool": "fetch-page",
  "arguments": {
    "url": "https://example.com",
    "offset": 500,
    "limit": 1000
  }
}
```

### Search within a webpage
```json
{
  "tool": "fetch-page",
  "arguments": {
    "url": "https://example.com",
    "query": "search term"
  }
}
```

### Fetch content around search results
After searching, use the returned positions to fetch specific content ranges:
```json
{
  "tool": "fetch-page",
  "arguments": {
    "url": "https://example.com",
    "offset": 1200,
    "limit": 500
  }
}
```

## Resources

- [MCP Specification](https://spec.modelcontextprotocol.io/)
- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)
- [JSON Schema Reference](https://json-schema.org/understanding-json-schema/reference)

## License

MIT License
