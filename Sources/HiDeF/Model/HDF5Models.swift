// SPDX-FileCopyrightText: 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum HDF5ObjectKind: String {
    case unknown
    case group
    case dataset
    case namedDatatype
    case link

    init(rawShimValue: HDHDFObjectKind) {
        switch rawShimValue {
        case HDHDFObjectKindGroup:
            self = .group
        case HDHDFObjectKindDataset:
            self = .dataset
        case HDHDFObjectKindNamedDatatype:
            self = .namedDatatype
        case HDHDFObjectKindLink:
            self = .link
        default:
            self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .group:
            return "Group"
        case .dataset:
            return "Dataset"
        case .namedDatatype:
            return "Datatype"
        case .link:
            return "Link"
        }
    }
}

enum HDF5LinkKind: String {
    case hard
    case soft
    case external
    case userDefined
    case unknown

    init(rawShimValue: HDHDFLinkKind) {
        switch rawShimValue {
        case HDHDFLinkKindHard:
            self = .hard
        case HDHDFLinkKindSoft:
            self = .soft
        case HDHDFLinkKindExternal:
            self = .external
        case HDHDFLinkKindUserDefined:
            self = .userDefined
        default:
            self = .unknown
        }
    }
}

struct HDF5Object: Hashable {
    var name: String
    var path: String
    var kind: HDF5ObjectKind
    var linkKind: HDF5LinkKind
    var childCount: UInt64
    var attributeCount: UInt64
    var storageSize: UInt64
    var typeDescription: String
    var shapeDescription: String
    var linkTarget: String

    var canHaveChildren: Bool {
        kind == .group && childCount > 0
    }

    var detailSummary: String {
        switch kind {
        case .group:
            return "\(childCount) members, \(attributeCount) attributes"
        case .dataset:
            let shape = shapeDescription.isEmpty ? "unknown shape" : shapeDescription
            let type = typeDescription.isEmpty ? "unknown type" : typeDescription
            return "\(shape), \(type)"
        case .namedDatatype:
            return typeDescription
        case .link:
            return linkTarget.isEmpty ? linkKind.rawValue : "\(linkKind.rawValue) -> \(linkTarget)"
        case .unknown:
            return "Unknown object"
        }
    }
}

extension HDF5Object {
    /// Datasets with more columns than this are awkward as a table, so an image view is offered.
    static let imageColumnThreshold = 64

    /// Parsed simple-dataspace extents (e.g. "768 x 1408 x 4" -> [768, 1408, 4]),
    /// or `nil` for scalar/null/unknown shapes and non-datasets.
    var datasetDimensions: [Int]? {
        guard kind == .dataset else { return nil }
        let components = shapeDescription.components(separatedBy: " x ")
        var dims: [Int] = []
        for component in components {
            // Tolerate a trailing " (unlimited)" annotation on growable dimensions.
            let token = component.split(separator: " ").first.map(String.init) ?? component
            guard let value = Int(token) else { return nil }
            dims.append(value)
        }
        return dims.isEmpty ? nil : dims
    }

    /// True for atomic integer/float datasets (the only kinds renderable as an image).
    var isNumericDataset: Bool {
        kind == .dataset && (typeDescription.contains("integer") || typeDescription.contains("float"))
    }

    /// `(height, width, channels)` when this dataset can be rendered as an image, else `nil`.
    /// 2D datasets qualify only once they are wider than `imageColumnThreshold`; 3D datasets
    /// qualify when the trailing dimension is a plausible channel count (1...4).
    var imageShape: (height: Int, width: Int, channels: Int)? {
        guard isNumericDataset, let dims = datasetDimensions else { return nil }
        switch dims.count {
        case 2:
            let (height, width) = (dims[0], dims[1])
            guard height > 0, width > Self.imageColumnThreshold else { return nil }
            return (height, width, 1)
        case 3:
            let (height, width, channels) = (dims[0], dims[1], dims[2])
            guard height > 0, width > 0, (1...4).contains(channels) else { return nil }
            return (height, width, channels)
        default:
            return nil
        }
    }

    /// Number of table columns this dataset is expected to show, computed from its
    /// shape/type without reading data. Used to decide sidebar disclosure defaults.
    var estimatedColumnCount: Int? {
        guard kind == .dataset else { return nil }
        if typeDescription.hasPrefix("compound") {
            let digits = typeDescription.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
            return Int(digits)
        }
        guard let dims = datasetDimensions else { return nil }
        return dims.count >= 2 ? dims[1] : 1
    }

    /// Whether to offer the image view for this dataset at all.
    var supportsImageView: Bool {
        imageShape != nil
    }

    /// Whether the image view is the natural default — true for genuine colour images.
    var prefersImageView: Bool {
        guard let shape = imageShape else { return false }
        return shape.channels >= 3
    }
}

struct HDF5Attribute {
    var name: String
    var typeDescription: String
    var shapeDescription: String
    var valuePreview: String
    var isValueTruncated: Bool
}

struct HDF5DatasetPreview {
    var text: String
    var summary: String
    var columnLabels: [String]
    var columnDisplayPrecisions: [Int]
    var xAxisLabel: String
    var xAxisValues: [Double]
    var xAxisSource: String
    var xAxisDisplayPrecision: Int
    var startRow: UInt64
    var rowStride: UInt64
    var rowCount: UInt64
    var columnCount: UInt64
    var totalRowCount: UInt64
    var totalColumnCount: UInt64
    var isTruncated: Bool
}

struct HDF5DatasetTableRow: Identifiable {
    var rowIndex: UInt64
    var cells: [String]

    var id: UInt64 {
        rowIndex
    }
}

struct HDF5DatasetImage {
    var rgba: Data            // premultiplied RGBA8, width * height * 4 bytes
    var width: Int
    var height: Int
    var channels: Int
    var sourceWidth: UInt64
    var sourceHeight: UInt64
    var isDownsampled: Bool
    var isNormalized: Bool
    var minValue: Double
    var maxValue: Double
}

enum HDF5Error: LocalizedError {
    case openFailed(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message), .readFailed(let message):
            return message
        }
    }
}

func byteCountString(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}
