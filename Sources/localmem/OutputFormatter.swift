import Foundation
import LocalmemCore

enum OutputFormatter {
    private static let tableDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func printTable(_ memories: [Memory]) {
        guard !memories.isEmpty else {
            print("(no memories)")
            return
        }

        print("ID        CREATED              TYPE        TITLE")
        for memory in memories {
            let shortId = String(memory.id.uuidString.prefix(8)).lowercased()
            let created = tableDateFormatter.string(from: memory.createdAt)
            let type    = memory.type.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            let title   = memory.title ?? String(memory.content.prefix(60))
            print("\(shortId)  \(created)  \(type)  \(title)")
        }
    }

    static func printDetail(_ memory: Memory) {
        print("id:         \(memory.id.uuidString)")
        print("type:       \(memory.type.rawValue)")
        if let source = memory.source { print("source:     \(source)") }
        print("created_at: \(memory.createdAt)")
        print("updated_at: \(memory.updatedAt)")
        if let title = memory.title { print("title:      \(title)") }
        if !memory.tags.isEmpty { print("tags:       \(memory.tags.joined(separator: ", "))") }
        print("---")
        print(memory.content)
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        if let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    }
}
