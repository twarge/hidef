// SPDX-FileCopyrightText: 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation

final class HDF5File: @unchecked Sendable {
    private let handle: OpaquePointer
    private let queue = DispatchQueue(label: "com.twarge.hidef.hdf5.file")

    let url: URL

    init(url: URL) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard let opened = HDHDFOpenFile(url.path, &errorPointer) else {
            throw HDF5Error.openFailed(Self.consume(errorPointer) ?? "Could not open \(url.lastPathComponent)")
        }
        handle = opened
        self.url = url
    }

    deinit {
        HDHDFCloseFile(handle)
    }

    func rootObject() throws -> HDF5Object {
        try queue.sync {
            var errorPointer: UnsafeMutablePointer<CChar>?
            var raw = HDHDFCopyRootObjectInfo(handle, &errorPointer)
            defer { HDHDFFreeObjectInfo(&raw) }

            if let message = Self.consume(errorPointer) {
                throw HDF5Error.readFailed(message)
            }

            return Self.object(from: raw)
        }
    }

    func object(at path: String) throws -> HDF5Object {
        try queue.sync {
            var errorPointer: UnsafeMutablePointer<CChar>?
            var raw = path.withCString { cPath in
                HDHDFCopyObjectInfo(handle, cPath, &errorPointer)
            }
            defer { HDHDFFreeObjectInfo(&raw) }

            if let message = Self.consume(errorPointer) {
                throw HDF5Error.readFailed(message)
            }

            return Self.object(from: raw)
        }
    }

    func children(of path: String) throws -> [HDF5Object] {
        try queue.sync {
            var rawList = path.withCString { cPath in
                HDHDFCopyChildren(handle, cPath)
            }
            defer { HDHDFFreeObjectList(&rawList) }

            if let message = Self.string(from: rawList.errorMessage) {
                throw HDF5Error.readFailed(message)
            }

            guard let items = rawList.items else {
                return []
            }

            return (0..<rawList.count).map { index in
                Self.object(from: items.advanced(by: index).pointee)
            }
        }
    }

    func attributes(of path: String) throws -> [HDF5Attribute] {
        try queue.sync {
            var rawList = path.withCString { cPath in
                HDHDFCopyAttributes(handle, cPath, 8 * 1024)
            }
            defer { HDHDFFreeAttributeList(&rawList) }

            if let message = Self.string(from: rawList.errorMessage) {
                throw HDF5Error.readFailed(message)
            }

            guard let items = rawList.items else {
                return []
            }

            return (0..<rawList.count).map { index in
                let raw = items.advanced(by: index).pointee
                return HDF5Attribute(
                    name: Self.string(from: raw.name) ?? "",
                    typeDescription: Self.string(from: raw.typeDescription) ?? "",
                    shapeDescription: Self.string(from: raw.shapeDescription) ?? "",
                    valuePreview: Self.string(from: raw.valuePreview) ?? "",
                    isValueTruncated: raw.isValueTruncated
                )
            }
        }
    }

    func previewDataset(at path: String, maxRows: UInt64 = 200, maxColumns: UInt64 = 32) throws -> HDF5DatasetPreview {
        try queue.sync {
            var rawPreview = path.withCString { cPath in
                HDHDFCopyDatasetPreview(handle, cPath, maxRows, maxColumns, maxRows * maxColumns)
            }
            defer { HDHDFFreeDatasetPreview(&rawPreview) }

            if let message = Self.string(from: rawPreview.errorMessage) {
                throw HDF5Error.readFailed(message)
            }

            return Self.datasetPreview(from: rawPreview)
        }
    }

    func datasetTableWindow(
        at path: String,
        startRow: UInt64,
        maxRows: UInt64 = 80,
        maxColumns: UInt64 = 64,
        sliceStarts: [UInt64] = []
    ) throws -> HDF5DatasetPreview {
        try queue.sync {
            var rawPreview = path.withCString { cPath in
                sliceStarts.withUnsafeBufferPointer { sliceBuffer in
                    HDHDFCopyDatasetPreviewWindowSliced(
                        handle,
                        cPath,
                        startRow,
                        maxRows,
                        maxColumns,
                        maxRows * maxColumns,
                        sliceBuffer.baseAddress,
                        sliceBuffer.count
                    )
                }
            }
            defer { HDHDFFreeDatasetPreview(&rawPreview) }

            if let message = Self.string(from: rawPreview.errorMessage) {
                throw HDF5Error.readFailed(message)
            }

            return Self.datasetPreview(from: rawPreview)
        }
    }

    func datasetPlotPreview(
        at path: String,
        startRow: UInt64? = nil,
        rowCount: UInt64? = nil,
        targetRows: UInt64,
        maxColumns: UInt64 = 16
    ) throws -> HDF5DatasetPreview {
        try queue.sync {
            let maxScalarValues = targetRows.saturatingMultiplied(by: maxColumns)
            var rawPreview = path.withCString { cPath in
                if let startRow, let rowCount {
                    HDHDFCopyDatasetPlotPreviewWindow(
                        handle,
                        cPath,
                        startRow,
                        rowCount,
                        targetRows,
                        maxColumns,
                        maxScalarValues
                    )
                } else {
                    HDHDFCopyDatasetPlotPreview(handle, cPath, targetRows, maxColumns, maxScalarValues)
                }
            }
            defer { HDHDFFreeDatasetPreview(&rawPreview) }

            if let message = Self.string(from: rawPreview.errorMessage) {
                throw HDF5Error.readFailed(message)
            }

            return Self.datasetPreview(from: rawPreview)
        }
    }

    func datasetImage(at path: String, maxDimension: UInt32 = 2048) throws -> HDF5DatasetImage {
        try queue.sync {
            var raw = path.withCString { cPath in
                HDHDFCopyDatasetImage(handle, cPath, maxDimension)
            }
            defer { HDHDFFreeDatasetImage(&raw) }

            if let message = Self.string(from: raw.errorMessage) {
                throw HDF5Error.readFailed(message)
            }

            let byteCount = Int(raw.width) * Int(raw.height) * 4
            let rgba: Data
            if let bytes = raw.rgba, byteCount > 0 {
                rgba = Data(bytes: bytes, count: byteCount)
            } else {
                rgba = Data()
            }

            return HDF5DatasetImage(
                rgba: rgba,
                width: Int(raw.width),
                height: Int(raw.height),
                channels: Int(raw.channels),
                sourceWidth: raw.sourceWidth,
                sourceHeight: raw.sourceHeight,
                isDownsampled: raw.isDownsampled,
                isNormalized: raw.isNormalized,
                minValue: raw.minValue,
                maxValue: raw.maxValue
            )
        }
    }

    private static func object(from raw: HDHDFObjectInfo) -> HDF5Object {
        HDF5Object(
            name: string(from: raw.name) ?? "",
            path: string(from: raw.path) ?? "/",
            kind: HDF5ObjectKind(rawShimValue: raw.kind),
            linkKind: HDF5LinkKind(rawShimValue: raw.linkKind),
            childCount: raw.childCount,
            attributeCount: raw.attributeCount,
            storageSize: raw.storageSize,
            typeDescription: string(from: raw.typeDescription) ?? "",
            shapeDescription: string(from: raw.shapeDescription) ?? "",
            linkTarget: string(from: raw.linkTarget) ?? ""
        )
    }

    private static func datasetPreview(from raw: HDHDFDatasetPreview) -> HDF5DatasetPreview {
        HDF5DatasetPreview(
            text: string(from: raw.text) ?? "",
            summary: string(from: raw.summary) ?? "",
            columnLabels: Self.labels(from: raw.columnLabels),
            columnDisplayPrecisions: Self.intValues(from: raw.columnDisplayPrecisions),
            xAxisLabel: string(from: raw.xAxisLabel) ?? "",
            xAxisValues: Self.doubleValues(from: raw.xAxisValues),
            xAxisSource: string(from: raw.xAxisSource) ?? "",
            xAxisDisplayPrecision: Int(raw.xAxisDisplayPrecision),
            startRow: raw.startRow,
            rowStride: raw.rowStride == 0 ? 1 : raw.rowStride,
            rowCount: raw.rowCount,
            columnCount: raw.columnCount,
            totalRowCount: raw.totalRowCount,
            totalColumnCount: raw.totalColumnCount,
            isTruncated: raw.isTruncated
        )
    }

    private static func labels(from pointer: UnsafeMutablePointer<CChar>?) -> [String] {
        guard let text = string(from: pointer), !text.isEmpty else {
            return []
        }
        return text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    }

    private static func doubleValues(from pointer: UnsafeMutablePointer<CChar>?) -> [Double] {
        guard let text = string(from: pointer), !text.isEmpty else {
            return []
        }
        return text
            .split(whereSeparator: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == " " })
            .compactMap { Double($0) }
    }

    private static func intValues(from pointer: UnsafeMutablePointer<CChar>?) -> [Int] {
        guard let text = string(from: pointer), !text.isEmpty else {
            return []
        }
        return text
            .split(whereSeparator: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == " " })
            .compactMap { Int($0) }
    }

    private static func string(from pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else {
            return nil
        }
        return String(cString: pointer)
    }

    private static func consume(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else {
            return nil
        }
        let string = String(cString: pointer)
        HDHDFFreeString(pointer)
        return string
    }
}

private extension UInt64 {
    func saturatingMultiplied(by rhs: UInt64) -> UInt64 {
        guard rhs != 0 else {
            return 0
        }
        guard self <= UInt64.max / rhs else {
            return UInt64.max
        }
        return self * rhs
    }
}
