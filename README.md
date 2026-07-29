# HighDeF

HighDeF is a native document-based HDF5 viewer for Apple devices. The focus is on preview of large timeseries datasets. Limited image display capability exists.

## Building

HDF5 is vendored as a git submodule at `Vendor/hdf5` and pinned to the `2.1.0` release tag; it is built into `Vendor/Build/HDF5.xcframework` before the app.

Run `make` to build the HDF5 XCFramework (if it isn't already built) and then the app. This drives `xcodebuild` against the shared scheme, so the result is identical to pressing **Build & Run** in Xcode; `make run` also launches the macOS app.

To use Xcode directly, build the dependency once with `Scripts/build-hdf5-xcframework.sh`, then open `HiDeF.xcodeproj`.

## Design notes

- Opening a document calls `H5Fopen` and keeps only the file handle plus lightweight metadata in memory.
- Expanding a group calls `H5Literate2` for that group only; the tree is not recursively loaded.
- Selecting an object loads its attributes with an 8 KB value preview limit.
- Dataset previews use an HDF5 hyperslab at the origin, capped by row and column limits. Large datasets are not loaded wholesale.
- The dataset table requests bounded row windows as rows become visible instead of reading the full dataset.
- Numeric plots are rendered from a bounded preview sample: one-dimensional and two-column samples become line plots, wider numeric slices become heatmaps.
- Soft and external links are represented as links instead of being traversed automatically.

The macOS app keeps the HDF5 file open through an `NSDocument`; the iOS app opens documents through a `UIDocumentBrowserViewController`. Both ports share a SwiftUI sidebar-adaptable document viewer, the same HDF5 access layer, lazy hierarchy rendering, bounded dataset previews, and sampled numeric plots.
