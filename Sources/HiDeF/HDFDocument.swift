// SPDX-FileCopyrightText: 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum HDFDocumentContentTypes {
    static let hdf5 = UTType("org.hdfgroup.hdf5") ?? UTType(filenameExtension: "h5") ?? .data
    static let hdf = UTType("org.hdfgroup.hdf") ?? UTType(filenameExtension: "hdf") ?? .data
    static let supported = [hdf5, hdf]
}

final class HDFDocument: ReferenceFileDocument, @unchecked Sendable {
    typealias Snapshot = Void

    static var readableContentTypes: [UTType] {
        HDFDocumentContentTypes.supported
    }

    // Read-only viewer: no writable types means the document is never editable,
    // so the system won't autosave or show an "Edited"/"Not Saved" title state.
    static var writableContentTypes: [UTType] { [] }

    init(configuration: ReadConfiguration) throws {}

    func snapshot(contentType: UTType) throws {}

    func fileWrapper(snapshot: Void, configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteUnknown, userInfo: [
            NSLocalizedDescriptionKey: "HiDeF is a read-only HDF5 viewer."
        ])
    }
}

/// A persisted numeric range (one axis of a plot's zoom window).
struct HDFPersistedRange: Codable, Equatable {
    var minimum: Double
    var maximum: Double
}

/// A persisted plot zoom/pan viewport. A nil axis means "fit to data".
struct HDFPersistedViewport: Codable, Equatable {
    var x: HDFPersistedRange?
    var y: HDFPersistedRange?
}

/// Restorable per-document UI state. Persisted by file path so it is reapplied
/// whenever a document is reopened — including after macOS/iOS document restoration.
struct HDFDocumentViewState: Codable {
    var selectedPath: String?
    var expandedPaths: [String]
    var detailMode: String
    var plotColumnSelections: [String: [Int]]
    var plotXAxisColumns: [String: Int]
    // Added later; optional so previously-saved states still decode.
    var sliceSelections: [String: [Int]]?
    var plotViewports: [String: HDFPersistedViewport]?
}

/// A small, bounded UserDefaults-backed store mapping a document's file path to its
/// last view state. Bounded to the most recently used documents to avoid unbounded growth.
enum HDFDocumentViewStateStore {
    private static let defaultsKey = "HDFDocumentViewStates"
    private static let limit = 50

    private struct Entry: Codable {
        var path: String
        var state: HDFDocumentViewState
    }

    private static func loadEntries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries
    }

    static func load(forPath path: String) -> HDFDocumentViewState? {
        loadEntries().last(where: { $0.path == path })?.state
    }

    static func save(_ state: HDFDocumentViewState, forPath path: String) {
        var entries = loadEntries().filter { $0.path != path }
        entries.append(Entry(path: path, state: state))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

private final class HDFDocumentSceneModel: ObservableObject {
    enum State {
        case loading
        case opened(HDF5File)
        case failed(String)
    }

    @Published private(set) var state: State = .loading

    private var scopedURL: URL?
    private var didStartSecurityScope = false

    init(fileURL: URL?) {
        open(fileURL)
    }

    deinit {
        releaseSecurityScope()
    }

    func open(_ fileURL: URL?) {
        releaseSecurityScope()

        guard let fileURL else {
            state = .failed("The system did not provide a file URL for this document.")
            return
        }

        state = .loading
        let didStartSecurityScope = fileURL.startAccessingSecurityScopedResource()

        do {
            let file = try HDF5File(url: fileURL)
            scopedURL = fileURL
            self.didStartSecurityScope = didStartSecurityScope
            state = .opened(file)
        } catch {
            if didStartSecurityScope {
                fileURL.stopAccessingSecurityScopedResource()
            }
            state = .failed(error.localizedDescription)
        }
    }

    private func releaseSecurityScope() {
        if didStartSecurityScope {
            scopedURL?.stopAccessingSecurityScopedResource()
        }
        scopedURL = nil
        didStartSecurityScope = false
    }
}

struct HDFDocumentSceneView: View {
    @StateObject private var model: HDFDocumentSceneModel

    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        _model = StateObject(wrappedValue: HDFDocumentSceneModel(fileURL: fileURL))
    }

    var body: some View {
        content
            .onChange(of: fileURL) { _, newValue in
                model.open(newValue)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .opened(let file):
            HDFDocumentSidebarView(file: file)
                .id(file.url)
        case .failed(let message):
            ContentUnavailableView(
                "Could Not Open Document",
                systemImage: "doc.badge.exclamationmark",
                description: Text(message)
            )
        }
    }
}
