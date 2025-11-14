import ArgumentParser
import MCPWebReaderLib

@main
struct MCPWebReaderMain: AsyncParsableCommand {
	func run() async throws {
		try await Entrypoint.run()
	}
}