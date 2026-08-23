import Foundation

actor SnapshotCache {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appending(path: "CodexGauge", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "account-snapshot.json")
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> AccountSnapshot? {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              let size = values?.fileSize,
              size <= 4 * 1_024 * 1_024,
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        return try? decoder.decode(AccountSnapshot.self, from: data)
    }

    func save(_ snapshot: AccountSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
