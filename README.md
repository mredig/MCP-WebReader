# MCP-WebReader

A minimal Swift-based Model Context Protocol (MCP) server template.

## Requirements

- Swift 6.0+
- macOS 13.0+

## Quick Start

```bash
# Build
swift build

# Run
swift run mcp-webreader
```

## Usage with Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "webreader": {
      "command": "/path/to/MCP-WebReader/.build/debug/mcp-webreader"
    }
  }
}
```

## Included Examples

### Tools
- `echo` - Echoes a message back
- `get-timestamp` - Returns current ISO 8601 timestamp

### Resources
- `webreader://status` - Server status (JSON)
- `webreader://welcome` - Welcome message (text)
- `webreader://config` - Server configuration (JSON)

## Development

Edit `Sources/MCPWebReaderLib/ServerHandlers.swift` to add your own tools and resources.

```bash
# Run tests
swift test
```

## License

MIT License