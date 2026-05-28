import ArgumentParser

@main
struct LocalmemCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "localmem",
        abstract: "Inspect Localmem memories.",
        subcommands: [
            ListCommand.self,
            SearchCommand.self,
            ShowCommand.self,
            AddCommand.self,
            DeleteCommand.self,
            SetupCommand.self,
            StatusCommand.self,
            PathCommand.self,
        ],
        defaultSubcommand: ListCommand.self
    )
}
