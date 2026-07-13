import ArgumentParser
import LocalmemCore

@main
struct LocalmemCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "localmem",
        abstract: "Inspect Localmem memories.",
        version: LocalmemVersion.current,
        subcommands: [
            ListCommand.self,
            SearchCommand.self,
            ShowCommand.self,
            AddCommand.self,
            UpdateCommand.self,
            DeleteCommand.self,
            SetupCommand.self,
            StatusCommand.self,
            PathCommand.self,
        ],
        defaultSubcommand: ListCommand.self
    )
}
