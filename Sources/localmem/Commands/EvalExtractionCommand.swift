import ArgumentParser
import Foundation
import LocalmemCore

/// Hidden dev harness for the two-pass extraction pipeline
/// (docs/Technical_Design.md �10). Hits a real backend, so it never runs
/// in CI — run it manually whenever either prompt changes:
///
///     localmem eval-extraction --fixtures Tests/LocalmemCoreTests/Fixtures/extraction --backend claude-code
///
/// Prints junk-kept / good-lost / duplicate rates per fixture, for extract-only
/// vs extract+verify, so the verifier's contribution is always visible.
/// Never touches the vault — everything stays in memory.
struct EvalExtractionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eval-extraction",
        abstract: "Score the extraction pipeline against golden fixtures (dev harness).",
        shouldDisplay: false
    )

    @Option(help: "Directory of fixture documents with sibling .expected.json files.")
    var fixtures: String

    @Option(help: "Backend to drive: claude-code, codex, or apple.")
    var backend: String = "claude-code"

    @Flag(help: "Skip the verify pass (extract-only baseline).")
    var extractOnly: Bool = false

    func run() async throws {
        guard let backendValue = Self.backendValue(backend) else {
            throw ValidationError("Unknown backend '\(backend)'. Use claude-code, codex, or apple.")
        }
        let dir = URL(fileURLWithPath: (fixtures as NSString).expandingTildeInPath)
        let loaded = try ExtractionEval.loadFixtures(from: dir)
        guard !loaded.isEmpty else {
            throw ValidationError("No fixtures found in \(dir.path) (need <name>.md/.txt + <name>.expected.json).")
        }

        let extractor = ExtractionBackends.extractor(for: backendValue)
        let verifier = ExtractionBackends.verifier(for: backendValue)

        print("Extraction eval — backend: \(backend) · fixtures: \(loaded.count)")
        print(String(repeating: "=", count: 72))
        print(Self.header)

        for fixture in loaded {
            let context = ExtractionContext(sourceName: fixture.name, relPath: fixture.name)
            let extracted: [ExtractedFact]
            do {
                extracted = try await extractor.extract(from: fixture.text, context: context)
            } catch {
                print("  \(fixture.name): EXTRACT FAILED — \(error)")
                continue
            }
            let candidates = Array(DeterministicFilters.clean(extracted)
                .prefix(ConnectorLimits.maxFactsPerFile))

            let baseline = ExtractionEval.score(actual: candidates, expected: fixture.expected)
            print(Self.row(fixture.name, "extract-only", baseline))

            guard !extractOnly else { continue }

            if candidates.isEmpty {
                print(Self.row(fixture.name, "extract+verify",
                               ExtractionEval.score(actual: [], expected: fixture.expected)))
                continue
            }
            do {
                let verdicts = try await verifier.verify(
                    candidates: candidates, against: fixture.text, context: context)
                let (kept, dropped) = VerdictApplication.split(verdicts, candidates: candidates)
                print(Self.row(fixture.name, "extract+verify",
                               ExtractionEval.score(actual: kept, expected: fixture.expected)))
                for (fact, reason) in dropped {
                    print("      dropped: \(fact.title) — \(reason)")
                }
            } catch {
                print("  \(fixture.name): VERIFY FAILED — \(error)")
            }
        }
    }

    static func backendValue(_ raw: String) -> ExtractionBackend? {
        switch raw {
        case "apple":                 return .apple
        case "claude-code", "codex":  return .agent(raw)
        default:                      return nil
        }
    }

    private static let header = String(
        format: "  %-24@ %-15@ %8@ %10@ %10@ %6@",
        "fixture" as NSString, "mode" as NSString, "junk%" as NSString,
        "lost%" as NSString, "dup%" as NSString, "n" as NSString)

    private static func row(_ name: String, _ mode: String, _ m: EvalMetrics) -> String {
        String(format: "  %-24@ %-15@ %7.0f%% %9.0f%% %9.0f%% %6d",
               name as NSString, mode as NSString,
               m.junkKeptRate * 100, m.goodLostRate * 100, m.duplicateRate * 100,
               m.actualCount)
    }
}
