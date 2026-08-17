// SPDX-FileCopyrightText: 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0

import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Streams a numeric dataset out of an open HDF5 file as CSV.
///
/// Policy:
/// - Supported: atomic integer/float datasets of rank 1 or 2. A 1-D dataset
///   exports as `index,value`; a 2-D dataset exports one CSV row per outer
///   index with the outer index first and one column per inner index
///   (`index,c0,c1,...`). Compound, string, scalar, and rank ≥ 3 datasets are
///   not exportable and the controls stay disabled for them.
/// - Size cap: `maxCellCount` (50 million values). Larger datasets are refused
///   with an explanatory message instead of a partial file.
/// - Streaming: rows are read through the same bounded hyperslab window API the
///   table view uses (`datasetTableWindow`), about `chunkCellBudget` values per
///   read, and each chunk is appended to the destination before the next read —
///   the dataset is never resident in memory at once.
/// - Values keep the shim's round-trip formatting (`%.17g` for doubles,
///   `%.9g` for floats, C locale), so they are plain numeric tokens and need
///   no CSV quoting.
enum HDF5DatasetCSVExporter {
    /// Refuse datasets beyond this many values (rows × columns).
    static let maxCellCount: UInt64 = 50_000_000

    /// Values fetched per windowed read while streaming.
    static let chunkCellBudget: UInt64 = 262_144

    enum Exportability {
        /// Numeric, rank 1–2, and within the size cap.
        case exportable
        /// Numeric and the right shape, but beyond `maxCellCount`.
        case tooLarge(cellCount: UInt64)
        /// Non-numeric, compound, scalar, or rank ≥ 3.
        case unsupported
    }

    static func exportability(of object: HDF5Object) -> Exportability {
        guard object.kind == .dataset,
              object.isNumericDataset,
              let dims = object.datasetDimensions,
              (1...2).contains(dims.count),
              dims.count < 2 || dims[1] > 0 else {
            return .unsupported
        }

        let columns = UInt64(dims.count == 2 ? dims[1] : 1)
        let (cells, overflow) = UInt64(dims[0]).multipliedReportingOverflow(by: columns)
        guard !overflow, cells <= maxCellCount else {
            return .tooLarge(cellCount: overflow ? .max : cells)
        }
        return .exportable
    }

    static func defaultFilename(for object: HDF5Object) -> String {
        let name = object.name.replacingOccurrences(of: "/", with: "-")
        return (name.isEmpty ? "dataset" : name) + ".csv"
    }

    static func capMessage(cellCount: UInt64) -> String {
        "This dataset has \(cellCount.formatted()) values; CSV export is limited to \(maxCellCount.formatted())."
    }

    /// Streams `object` to `url` as CSV. Blocking — call it off the main thread
    /// (or through `export(file:object:to:)`).
    static func write(file: HDF5File, object: HDF5Object, to url: URL) throws {
        switch exportability(of: object) {
        case .exportable:
            break
        case .tooLarge(let cellCount):
            throw HDF5Error.readFailed(capMessage(cellCount: cellCount))
        case .unsupported:
            throw HDF5Error.readFailed("Only numeric 1-D and 2-D datasets can be exported as CSV.")
        }

        let dims = object.datasetDimensions ?? []
        let totalRows = UInt64(dims.first ?? 0)
        let columnCount = dims.count == 2 ? dims[1] : 1

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Could not create \(url.lastPathComponent)."
            ])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let header = columnCount == 1
            ? "index,value"
            : "index" + (0..<columnCount).map { ",c\($0)" }.joined()
        try handle.write(contentsOf: Data((header + "\n").utf8))

        // The shape was read when the dataset was selected; a concurrently
        // growing file exports the extent observed then and stops cleanly if
        // the file shrank in the meantime (a window comes back empty).
        let rowsPerChunk = max(1, chunkCellBudget / UInt64(columnCount))
        var nextRow: UInt64 = 0
        while nextRow < totalRows {
            let window = try file.datasetTableWindow(
                at: object.path,
                startRow: nextRow,
                maxRows: min(rowsPerChunk, totalRows - nextRow),
                maxColumns: UInt64(columnCount)
            )
            guard window.rowCount > 0 else {
                break
            }

            var chunk = String()
            chunk.reserveCapacity(window.text.utf8.count + Int(window.rowCount) * 12)
            let lines = window.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, line) in lines.enumerated() where offset < Int(window.rowCount) {
                chunk += "\(nextRow + UInt64(offset)),"
                chunk += line.replacingOccurrences(of: "\t", with: ",")
                chunk += "\n"
            }
            try handle.write(contentsOf: Data(chunk.utf8))
            nextRow += window.rowCount
        }
    }

    /// `write(file:object:to:)` hopped off the main thread, in the same style
    /// as the view models' `perform` helpers.
    static func export(file: HDF5File, object: HDF5Object, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try write(file: file, object: object, to: url)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// The selected dataset as a shareable CSV, offered by the iOS share sheet.
/// Encoding is deferred: constructing this is a value copy, and the CSV is
/// only streamed to disk when a share target actually asks. File transfers
/// hand over a URL, so the bytes go through a uniquely-named temporary
/// directory — which is also what lets the receiver see the real filename.
struct HDF5DatasetCSVFile: Transferable {
    var file: HDF5File
    var object: HDF5Object

    var filename: String {
        HDF5DatasetCSVExporter.defaultFilename(for: object)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) {
            (item: HDF5DatasetCSVFile) async throws -> SentTransferredFile in
            SentTransferredFile(try await item.writeTemporary(), allowAccessingOriginalFile: false)
        }
    }

    private func writeTemporary() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        try await HDF5DatasetCSVExporter.export(file: file, object: object, to: url)
        return url
    }
}

#if os(macOS)
/// What File ▸ Export CSV… needs from the frontmost document window: the open
/// file handle and the selected dataset. Published per scene so the menu item
/// tracks the frontmost window's selection.
struct HDF5DatasetCSVExportContext {
    var file: HDF5File
    var object: HDF5Object
}

extension FocusedValues {
    @Entry var hdfDatasetCSVExport: HDF5DatasetCSVExportContext?
}
#endif
