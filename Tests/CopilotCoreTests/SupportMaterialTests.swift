import Foundation
import CopilotCore

final class SupportMaterialTests {
    func run() throws {
        let legacy = Data(#"{"proposalName":"old.txt","proposalText":"Old terms","dealText":""}"#.utf8)
        var record = try JSONDecoder().decode(IntelligenceRecord.self, from: legacy)
        try record.addMaterials([SupportMaterial(name: "new.txt", text: "New terms")])
        precondition(record.supportMaterials.count == 2)
        precondition(record.proposalText.contains("Old terms") && record.proposalText.contains("New terms"))
        try record.addMaterials([SupportMaterial(name: "new.txt", text: "New terms")])
        precondition(record.supportMaterials.count == 2, "Repeated file must not duplicate context")
        let before = record.proposalText
        do {
            try record.addMaterials([SupportMaterial(name: "valid.txt", text: "valid"), SupportMaterial(name: "empty.txt", text: " ")])
            preconditionFailure("Empty material accepted")
        } catch {}
        precondition(record.proposalText == before, "Batch validation must be atomic")
        let roundTrip = try JSONDecoder().decode(IntelligenceRecord.self, from: JSONEncoder().encode(record))
        precondition(roundTrip.supportMaterials.map(\.name) == ["old.txt", "new.txt"])
        record.removeMaterial(id: record.supportMaterials[0].id)
        precondition(!record.proposalText.contains("Old terms") && record.proposalText.contains("New terms"))
        record.removeMaterial(id: record.supportMaterials[0].id)
        precondition(record.proposalText.isEmpty && record.proposalName.isEmpty)
        print("PASS: multiple support materials, legacy migration, deduplication, atomic validation and removal")
    }
}
