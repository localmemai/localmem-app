import ArgumentParser

@main
struct LocalMemCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "localmem",
        abstract: "Inspect LocalMem memories.",
        subcommands: [
            ListCommand.self,
            SearchCommand.self,
            ShowCommand.self,
            AddCommand.self,
            PathCommand.self,
        ],
        defaultSubcommand: ListCommand.self
    )
}
