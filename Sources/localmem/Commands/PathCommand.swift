import ArgumentParser
import LocalMemCore

struct PathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Print the LocalMem database path."
    )

    func run() throws {
        print(try Paths.databaseURL().path)
    }
}
