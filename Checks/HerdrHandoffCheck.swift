import Foundation
import SwitcherCore
import Darwin

// Local validation utility: never changes credentials or closes Codex Desktop.
@main
struct HerdrHandoffCheck {
    static func main() async {
        guard CommandLine.arguments.count == 3,
              ["inspect", "cycle", "recover"].contains(CommandLine.arguments[1]) else {
            print("Usage: HerdrHandoffCheck inspect|cycle|recover /absolute/test-journal.json")
            exit(2)
        }
        let mode = CommandLine.arguments[1]
        let path = CommandLine.arguments[2]
        guard path.hasPrefix("/") else { exit(2) }
        let coordinator = HerdrCoordinator(journalURL: URL(fileURLWithPath: path))
        do {
            if mode == "recover" {
                try await coordinator.resume()
            } else {
                try await coordinator.prepare()
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let records = object["records"] as? [[String: Any]] {
                    print("Prepared \(records.count) Codex chats")
                    for row in records {
                        print("\(row["paneID"] ?? "?"): \(row["threadID"] ?? "?")")
                    }
                } else { print("No running Codex chats") }
                if mode == "cycle" {
                    do { try await coordinator.suspend() }
                    catch {
                        try? await coordinator.resume()
                        throw error
                    }
                }
                try await coordinator.resume()
            }
            print("\(mode) completed; pending recovery: \(await coordinator.hasPendingRecovery())")
        } catch {
            print("Validation stopped: \(error.localizedDescription)")
            exit(1)
        }
    }
}
