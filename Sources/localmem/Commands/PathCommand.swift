import ArgumentParser
import LocalmemCore

struct PathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Print the Localmem database path."
    )

    func run() throws {
        print(try Paths.databaseURL().path)
    }
}
