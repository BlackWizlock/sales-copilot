import Foundation
import CopilotCore

final class MeetingLibraryTests {
    func run() throws {
        var library = MeetingLibrary()
        let folder = try library.createFolder("  Клиент  ")
        precondition(library.folders.first?.name == "Клиент")
        expectThrows(try library.createFolder("клиент"))
        expectThrows(try library.createFolder("   "))
        var older = MeetingSession(title: "Бета")
        older.created = Date(timeIntervalSince1970: 1)
        var newer = MeetingSession(title: "Альфа")
        newer.created = Date(timeIntervalSince1970: 2)
        try library.move(newer.id, to: folder)
        precondition(library.filtered([older, newer], folder: folder, unfiled: false, query: "", sort: .newest).map(\.id) == [newer.id])
        precondition(library.filtered([newer, older], folder: nil, unfiled: true, query: "", sort: .oldest).map(\.id) == [older.id])
        precondition(library.filtered([older, newer], folder: nil, unfiled: false, query: "альф", sort: .title).map(\.id) == [newer.id])
        precondition(library.filtered([older, newer], folder: nil, unfiled: false, query: "", sort: .newest).map(\.id) == [newer.id, older.id])
        let restored = try JSONDecoder().decode(MeetingLibrary.self, from: JSONEncoder().encode(library))
        precondition(restored.folder(for: newer.id) == folder, "Folders survive a restart")
        library.removeFolder(folder)
        precondition(library.folder(for: newer.id) == nil)
        precondition(library.filtered([older, newer], folder: nil, unfiled: true, query: "", sort: .newest).count == 2, "Removing a folder keeps all meetings")
        expectThrows(try library.move(older.id, to: folder))
        print("PASS: meeting library folders, validation, search, sort and persistence")
    }
}
