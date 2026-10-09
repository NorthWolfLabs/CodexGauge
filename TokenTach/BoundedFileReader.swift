import Darwin
import Foundation

enum BoundedFileReader {
    static func read(_ url: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes >= 0 else { return nil }
        guard let directory = AnchoredFileAccess.openDirectory(url.deletingLastPathComponent()) else { return nil }
        defer { close(directory.descriptor) }
        guard let descriptor = AnchoredFileAccess.openRegularFile(
            relativePath: url.lastPathComponent,
            directoryDescriptor: directory.descriptor
        ) else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0,
              status.st_size <= maximumBytes else { return nil }

        do {
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
