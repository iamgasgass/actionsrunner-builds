// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import Foundation

// The names of an archive are paths, and the viewer shows them as folders and files, as Files shows a folder.
// The names are data the archive carries: they group entries and are shown, and no path of the file system is
// ever made from one.

/// The folders and files of a listing, level by level.
nonisolated struct SendFeedbackArchiveTree: Sendable {
    struct Folder: Hashable, Sendable {
        /// Where the folder is: its names joined by "/", the key to ask `level(at:)` for what is inside.
        let path: String
        /// What the row says: the names from the level it is in to here, joined by "/" (a folder with nothing but
        /// one folder in it is shown as one row with that one inside).
        let label: String
        /// The files in it and in every folder under it.
        let files: Int
        let bytes: UInt64
    }

    struct File: Hashable, Sendable {
        let entry: SendFeedbackArchiveEntry
        /// The last name of the path.
        let label: String
    }

    struct Level: Equatable, Sendable {
        var folders: [Folder]
        var files: [File]
    }

    private struct Node {
        var folders: [String] = []
        var files: [Int] = []
        /// The files in it and in every folder under it.
        var fileCount = 0
        var bytes: UInt64 = 0
    }

    private var nodes: [String: Node] = ["": Node()]
    private let entries: [SendFeedbackArchiveEntry]

    init(entries: [SendFeedbackArchiveEntry]) {
        self.entries = entries
        for (index, entry) in entries.enumerated() {
            // One more than the levels, so that what is past them stays whole as the last element.
            let parts = entry.path.split(separator: "/", maxSplits: Self.maxLevels, omittingEmptySubsequences: true)
            if entry.isFolder {
                _ = makeChain(parts.prefix(Self.maxLevels).map(String.init))
                continue
            }
            let parent = makeChain((parts.count > Self.maxLevels ? parts.prefix(Self.maxLevels) : parts.dropLast()).map(String.init))
            nodes[parent.last!]!.files.append(index)
            // Every folder above it counts it.
            for path in parent {
                nodes[path]!.fileCount += 1
                nodes[path]!.bytes += entry.size
            }
        }
    }

    /// How many folder levels a path makes: a path of more components keeps its first sixteen as folders, and the
    /// rest of it, slashes included, is the file's name inside the sixteenth. What a path may cost the tree is then
    /// at most sixteen prefixes, each as long as a name may be (`SendFeedbackArchiveLimits.maxNameBytes`).
    static let maxLevels = 16

    /// How many folders the tree holds (the top included) and the bytes of their paths: for the tests of the bound.
    var nodeCount: Int { nodes.count }
    var keyBytes: Int { nodes.keys.reduce(0) { $0 + $1.utf8.count } }

    /// The nodes from the top (the empty path) down to the folder the names make, made where they are not yet.
    private mutating func makeChain(_ names: some Collection<String>) -> [String] {
        var path = ""
        var chain = [""]
        for name in names {
            let child = path.isEmpty ? name : path + "/" + name
            if nodes[child] == nil {
                nodes[child] = Node()
                nodes[path]!.folders.append(name)
            }
            path = child
            chain.append(path)
        }
        return chain
    }

    /// The name of a file inside its folders: the last component, or, when the path has more components than the
    /// tree has levels, everything after the sixteenth (slashes included).
    private static func fileName(of path: String) -> String {
        let parts = path.split(separator: "/", maxSplits: maxLevels, omittingEmptySubsequences: true)
        return (parts.count > maxLevels ? parts[maxLevels] : parts.last).map(String.init) ?? path
    }

    /// What is directly in the folder at `path` ("" is the top): the folders first, then the files, each by name.
    func level(at path: String) -> Level {
        guard let node = nodes[path] else { return Level(folders: [], files: []) }
        let folders = node.folders.map { name -> Folder in
            var at = path.isEmpty ? name : path + "/" + name
            var label = SendFeedbackArchiveNames.shortened(name)
            while let inner = nodes[at], inner.files.isEmpty, inner.folders.count == 1 {
                at += "/" + inner.folders[0]
                label += "/" + SendFeedbackArchiveNames.shortened(inner.folders[0])
            }
            let found = nodes[at]!
            return Folder(path: at, label: label, files: found.fileCount, bytes: found.bytes)
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        let files = node.files.map { index -> File in
            let entry = entries[index]
            return File(entry: entry, label: SendFeedbackArchiveNames.shortened(Self.fileName(of: entry.path)))
        }
        .sorted {
            let order = $0.label.localizedStandardCompare($1.label)
            return order == .orderedSame ? $0.entry.id < $1.entry.id : order == .orderedAscending
        }
        return Level(folders: folders, files: files)
    }
}

#endif
