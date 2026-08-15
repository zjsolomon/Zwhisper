import Foundation
import Testing
@testable import ZwispCore

struct CorrectionStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zwispTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("corrections.json")
    }

    @Test func startsEmptyAndRoundTrips() {
        let url = tempFile()
        let store = CorrectionStore(fileURL: url)
        #expect(store.records.isEmpty)

        let date = Date(timeIntervalSince1970: 1_784_000_000)
        store.record(raw: "call zeddo", injected: "Call zeddo.", corrected: "Call Ziedo.",
                     date: date)

        let reloaded = CorrectionStore(fileURL: url)
        #expect(reloaded.records == [CorrectionRecord(
            date: date, raw: "call zeddo", injected: "Call zeddo.", corrected: "Call Ziedo.")])
    }

    @Test func oldestRecordsArePrunedPastTheCap() {
        let url = tempFile()
        let store = CorrectionStore(config: .init(maxStored: 3), fileURL: url)
        for i in 1...5 {
            store.record(raw: "raw \(i)", injected: "in \(i)", corrected: "out \(i)")
        }
        #expect(store.records.count == 3)
        #expect(store.records.map { $0.raw } == ["raw 3", "raw 4", "raw 5"])
    }

    @Test func corruptFileLoadsAsEmpty() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(CorrectionStore(fileURL: url).records.isEmpty)
    }
}
