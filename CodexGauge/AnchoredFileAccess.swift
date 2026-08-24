import Darwin
import Foundation

enum AnchoredFileAccess {
    struct Directory {
        let descriptor: Int32
        let resolvedPath: String
    }

    struct DirectoryEntryBatch {
        let names: [String]
        let reachedEnd: Bool
    }

    final class DirectoryStream: @unchecked Sendable {
        private var stream: UnsafeMutablePointer<DIR>?

        init?(directoryDescriptor: Int32) {
            let independentDescriptor = openat(
                directoryDescriptor,
                ".",
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            guard independentDescriptor >= 0,
                  let stream = fdopendir(independentDescriptor) else {
                if independentDescriptor >= 0 { close(independentDescriptor) }
                return nil
            }
            self.stream = stream
        }

        deinit {
            if let stream { closedir(stream) }
        }

        func nextBatch(maximumEntries: Int) -> DirectoryEntryBatch {
            guard maximumEntries > 0, let stream else {
                return DirectoryEntryBatch(names: [], reachedEnd: true)
            }
            var names: [String] = []
            var reachedEnd = false
            names.reserveCapacity(min(maximumEntries, 512))
            while names.count < maximumEntries {
                guard let entry = readdir(stream) else {
                    reachedEnd = true
                    rewinddir(stream)
                    break
                }
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                guard name != ".", name != ".." else { continue }
                names.append(name)
            }
            return DirectoryEntryBatch(names: names, reachedEnd: reachedEnd)
        }
    }

    static func openDirectory(_ url: URL) -> Directory? {
        guard let resolvedPath = canonicalPath(for: url) else { return nil }
        guard resolvedPath.hasPrefix("/") else { return nil }

        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }

        for component in URL(fileURLWithPath: resolvedPath).pathComponents.dropFirst() {
            guard isSafeComponent(component) else {
                close(descriptor)
                return nil
            }
            let next = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor)
            return nil
        }
        return Directory(descriptor: descriptor, resolvedPath: resolvedPath)
    }

    static func canonicalPath(for url: URL) -> String? {
        guard let canonicalPointer = realpath(url.standardizedFileURL.path, nil) else { return nil }
        defer { free(canonicalPointer) }
        return String(cString: canonicalPointer)
    }

    static func openRegularFile(relativePath: String, directoryDescriptor: Int32) -> Int32? {
        guard directoryDescriptor >= 0, !relativePath.hasPrefix("/") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy(isSafeComponent) else { return nil }

        var descriptor = dup(directoryDescriptor)
        guard descriptor >= 0 else { return nil }

        for component in components.dropLast() {
            let next = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
        }

        let final = components.last!.withCString {
            openat(descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        close(descriptor)
        guard final >= 0 else { return nil }

        var status = stat()
        guard fstat(final, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0 else {
            close(final)
            return nil
        }
        return final
    }

    private static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." && !component.contains("/")
    }
}
