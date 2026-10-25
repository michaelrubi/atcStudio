import Foundation
import Testing
@testable import RestorationStation

@Suite struct AssetStoreTests {
    let base: URL
    let store: AssetStore

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "atc-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = AssetStore(root: base.appending(path: "Assets"))
    }

    private func makeSource(_ name: String, contents: String = "audio") throws -> URL {
        let url = base.appending(path: "Desktop").appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func copySurvivesOriginalBeingDeleted() throws {
        let source = try makeSource("intro music.wav")
        let path = try store.importFile(at: source)
        try FileManager.default.removeItem(at: source)

        #expect(path.hasPrefix(store.root.path + "/"))
        #expect(URL(filePath: path).lastPathComponent == "intro music.wav")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "audio")
    }

    @Test func sameFileNameTwiceGetsTwoCopies() throws {
        let a = try store.importFile(at: try makeSource("vo.mp3", contents: "spring"))
        let b = try store.importFile(at: try makeSource("vo.mp3", contents: "summer"))
        #expect(a != b)
        #expect(try String(contentsOfFile: a, encoding: .utf8) == "spring")
    }

    @Test func fileAlreadyInStoreIsNotCopiedAgain() throws {
        let path = try store.importFile(at: try makeSource("outro.wav"))
        #expect(try store.importFile(at: URL(filePath: path)) == path)
    }

    @Test func pruneRemovesOnlyUnreferencedCopies() throws {
        let kept = try store.importFile(at: try makeSource("keep.wav"))
        let dropped = try store.importFile(at: try makeSource("drop.wav"))
        try store.prune(keeping: [kept, "/somewhere/else.wav"])

        #expect(FileManager.default.fileExists(atPath: kept))
        #expect(!FileManager.default.fileExists(atPath: dropped))
        #expect(!FileManager.default.fileExists(atPath: URL(filePath: dropped).deletingLastPathComponent().path))
    }

    @Test func pruneWithNoStoreFolderDoesNothing() throws {
        try AssetStore(root: base.appending(path: "Missing")).prune(keeping: [])
    }
}
