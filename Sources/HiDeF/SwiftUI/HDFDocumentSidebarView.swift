// SPDX-FileCopyrightText: 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Dispatch
import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

private enum HDFPreferenceKeys {
    static let relativeXAxisDisplay = "HDFRelativeXAxisDisplay"
}

final class HDFDocumentCloseAction: ObservableObject {
    var action: (() -> Void)?

    func close() {
        action?()
    }
}

@MainActor
final class HDFSidebarNode: ObservableObject {
    let object: HDF5Object
    @Published var children: [HDFSidebarNode] = []
    @Published var isLoaded = false
    @Published var isLoading = false
    @Published var errorMessage: String?

    var id: String {
        object.path
    }

    init(object: HDF5Object) {
        self.object = object
    }
}

@MainActor
final class HDFDocumentViewModel: ObservableObject {
    private(set) var file: HDF5File
    let fileName: String

    @Published var rootNode: HDFSidebarNode?
    @Published var rootError: String?
    @Published var selectedPath: String? { didSet { persistViewState() } }
    @Published var expandedPaths: Set<String> = [] { didSet { persistViewState() } }
    @Published var selectedObject: HDF5Object?
    @Published fileprivate var datasetDetailMode = HDFDatasetDetailMode.plot { didSet { persistViewState() } }
    @Published private var plotColumnSelections: [String: Set<Int>] = [:] { didSet { persistViewState() } }
    @Published private var plotXAxisColumns: [String: Int] = [:] { didSet { persistViewState() } }
    @Published private var sliceSelections: [String: [Int]] = [:] { didSet { persistViewState() } }
    @Published private var plotViewports: [String: HDFPersistedViewport] = [:] { didSet { persistViewState() } }
    /// Bumped on every reload so data views re-read the freshly reopened file.
    @Published private(set) var reloadGeneration = 0

    private var fileWatchSource: (any DispatchSourceFileSystemObject)?
    private var reloadThrottleScheduled = false
    private var pendingLostFile = false
    /// While true, view-state mutations are not persisted (used during setup and restore).
    private var isRestoring = false

    init(file: HDF5File) {
        self.file = file
        fileName = file.url.lastPathComponent
        isRestoring = true

        do {
            let rootObject = try file.rootObject()
            let rootNode = HDFSidebarNode(object: rootObject)
            self.rootNode = rootNode
            selectedPath = rootObject.path
            selectedObject = rootObject
            expandedPaths.insert(rootObject.path)
        } catch {
            rootError = error.localizedDescription
        }

        // Reapply saved per-document view state (if any) over the defaults.
        let saved = HDFDocumentViewStateStore.load(forPath: file.url.path)
        if let saved {
            var paths = Set(saved.expandedPaths)
            paths.insert("/")
            expandedPaths = paths
            plotColumnSelections = saved.plotColumnSelections.mapValues { Set($0) }
            plotXAxisColumns = saved.plotXAxisColumns
            sliceSelections = saved.sliceSelections ?? [:]
            plotViewports = saved.plotViewports ?? [:]
            if let mode = HDFDatasetDetailMode(rawValue: saved.detailMode) {
                datasetDetailMode = mode
            }
        }
        let restoredSelection = saved?.selectedPath

        Task { @MainActor in
            if let rootNode {
                await restoreExpandedSubtree(rootNode)
            }
            if let restoredSelection,
               restoredSelection != "/",
               let object = try? file.object(at: restoredSelection) {
                selectedPath = restoredSelection
                selectedObject = object
                // Keep the restored view mode unless it isn't valid for this object.
                let available = availableDetailModes(for: object)
                if !available.contains(datasetDetailMode) {
                    datasetDetailMode = available.first ?? .plot
                }
            }
            isRestoring = false
        }

        startWatchingFile()
    }

    deinit {
        fileWatchSource?.cancel()
    }

    /// Re-open the file from disk and refresh the data views, keeping the current
    /// selection and tree expansion. Safe to call repeatedly (manual ⌘R or the watcher).
    func reloadNow() {
        guard let reopened = try? HDF5File(url: file.url) else {
            // The file is momentarily unavailable (e.g. mid-write). Keep showing
            // what we have; the next change event will trigger another attempt.
            return
        }

        file = reopened
        if let selectedPath {
            // Refresh the selected object so its shape/extent reflect new data.
            selectedObject = try? reopened.object(at: selectedPath)
        }
        reloadGeneration &+= 1
    }

    private func startWatchingFile() {
        stopWatchingFile()

        let descriptor = open(file.url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let flags = self.fileWatchSource?.data ?? []
                let lostFile = !flags.isDisjoint(with: [.delete, .rename, .revoke])
                self.handleFileChange(lostFile: lostFile)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        fileWatchSource = source
        source.resume()
    }

    private func stopWatchingFile() {
        fileWatchSource?.cancel()
        fileWatchSource = nil
    }

    private func persistViewState() {
        guard !isRestoring else { return }
        let state = HDFDocumentViewState(
            selectedPath: selectedPath,
            expandedPaths: Array(expandedPaths),
            detailMode: datasetDetailMode.rawValue,
            plotColumnSelections: plotColumnSelections.mapValues { Array($0).sorted() },
            plotXAxisColumns: plotXAxisColumns,
            sliceSelections: sliceSelections,
            plotViewports: plotViewports
        )
        HDFDocumentViewStateStore.save(state, forPath: file.url.path)
    }

    // Per-dataset slice indices (ND dimension stepper), persisted across reopen.
    func sliceSelection(for path: String) -> [Int]? {
        sliceSelections[path]
    }

    func setSliceSelection(_ indices: [Int], for path: String) {
        sliceSelections[path] = indices
    }

    // Per-dataset plot zoom/pan viewport, persisted across reopen.
    func plotViewport(for path: String) -> HDFPersistedViewport? {
        plotViewports[path]
    }

    func setPlotViewport(_ viewport: HDFPersistedViewport?, for path: String) {
        if let viewport {
            plotViewports[path] = viewport
        } else {
            plotViewports.removeValue(forKey: path)
        }
    }

    /// Reload children for every previously-expanded group so the restored tree
    /// shows the same disclosure state the user left it in.
    private func restoreExpandedSubtree(_ node: HDFSidebarNode) async {
        guard expandedPaths.contains(node.id), node.object.canHaveChildren else {
            return
        }
        await loadChildren(for: node)
        for child in node.children {
            await restoreExpandedSubtree(child)
        }
    }

    /// Throttle bursts of write events into at most a few reloads per second, so a
    /// continuously growing log still updates without thrashing the UI.
    private func handleFileChange(lostFile: Bool) {
        pendingLostFile = pendingLostFile || lostFile
        guard !reloadThrottleScheduled else {
            return
        }
        reloadThrottleScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            let lost = self.pendingLostFile
            self.reloadThrottleScheduled = false
            self.pendingLostFile = false
            self.reloadNow()
            if lost {
                // The file was replaced/rotated, so our descriptor is stale —
                // re-attach the watcher to the new file at the same path.
                self.startWatchingFile()
            }
        }
    }

    var selectedBreadcrumbTitle: String {
        guard let selectedObject,
              selectedObject.path != "/" else {
            return ""
        }

        return selectedObject.path
            .split(separator: "/")
            .map(String.init)
            .joined(separator: " › ")
    }

    func select(_ node: HDFSidebarNode) {
        selectedPath = node.object.path
        selectedObject = node.object
        reconcileDetailMode(for: node.object)
    }

    /// The dataset view modes available for `object`. Image is offered only for
    /// image-shaped datasets (see `HDF5Object.supportsImageView`).
    fileprivate func availableDetailModes(for object: HDF5Object?) -> [HDFDatasetDetailMode] {
        var modes: [HDFDatasetDetailMode] = [.table, .plot]
        if object?.supportsImageView == true {
            modes.append(.image)
        }
        return modes
    }

    fileprivate var availableDatasetDetailModes: [HDFDatasetDetailMode] {
        availableDetailModes(for: selectedObject)
    }

    /// Keep the selected mode valid for the newly selected object: default genuine
    /// images to the image view, and fall back off image when it isn't available.
    private func reconcileDetailMode(for object: HDF5Object) {
        let available = availableDetailModes(for: object)
        if object.prefersImageView {
            datasetDetailMode = .image
        } else if !available.contains(datasetDetailMode) {
            datasetDetailMode = available.first ?? .plot
        }
    }

    func explicitPlotColumnSelection(for path: String) -> Set<Int>? {
        plotColumnSelections[path]
    }

    func explicitPlotXAxisColumn(for path: String) -> Int? {
        plotXAxisColumns[path]
    }

    func isPlotColumnSelected(path: String, columnIndex: Int, defaultSelection: Set<Int>) -> Bool {
        if plotXAxisColumns[path] == columnIndex {
            return false
        }
        let selection = plotColumnSelections[path] ?? defaultSelection
        return selection.contains(columnIndex)
    }

    func isPlotXAxisColumn(path: String, columnIndex: Int) -> Bool {
        plotXAxisColumns[path] == columnIndex
    }

    func setPlotColumnSelected(_ isSelected: Bool,
                               node: HDFSidebarNode,
                               columnIndex: Int,
                               defaultSelection: Set<Int>) {
        if isSelected, plotXAxisColumns[node.object.path] == columnIndex {
            plotXAxisColumns.removeValue(forKey: node.object.path)
        }

        var selection = plotColumnSelections[node.object.path] ?? defaultSelection
        if isSelected {
            selection.insert(columnIndex)
        } else {
            selection.remove(columnIndex)
        }
        plotColumnSelections[node.object.path] = selection
        select(node)
        datasetDetailMode = .plot
    }

    func setPlotXAxisColumn(_ columnIndex: Int,
                            node: HDFSidebarNode,
                            defaultSelection: Set<Int>) {
        plotXAxisColumns[node.object.path] = columnIndex
        var selection = plotColumnSelections[node.object.path] ?? defaultSelection
        selection.remove(columnIndex)
        plotColumnSelections[node.object.path] = selection
        select(node)
        datasetDetailMode = .plot
    }

    func clearPlotXAxisColumn(node: HDFSidebarNode) {
        plotXAxisColumns.removeValue(forKey: node.object.path)
        select(node)
        datasetDetailMode = .plot
    }

    fileprivate func setDatasetDetailModeAfterViewUpdate(_ mode: HDFDatasetDetailMode) {
        guard datasetDetailMode != mode else {
            return
        }

        Task { @MainActor in
            await Task.yield()
            guard self.datasetDetailMode != mode else {
                return
            }
            self.datasetDetailMode = mode
        }
    }

    func selectPath(_ path: String?) {
        guard let path,
              selectedObject?.path != path,
              let node = node(for: path, startingAt: rootNode) else {
            return
        }
        select(node)
    }

    func setExpanded(_ node: HDFSidebarNode, isExpanded: Bool) {
        if isExpanded {
            expandedPaths.insert(node.id)
            Task {
                await loadChildren(for: node)
            }
        } else {
            expandedPaths.remove(node.id)
        }
    }

    func loadChildren(for node: HDFSidebarNode) async {
        guard node.object.canHaveChildren, !node.isLoaded, !node.isLoading else {
            return
        }

        node.isLoading = true
        node.errorMessage = nil
        do {
            let hdf5File = file
            let path = node.object.path
            let objects = try await perform {
                try hdf5File.children(of: path)
            }
            node.children = objects.map(HDFSidebarNode.init(object:))
            node.isLoaded = true
        } catch {
            node.errorMessage = error.localizedDescription
        }
        node.isLoading = false
    }

    private func perform<Value>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func node(for path: String, startingAt node: HDFSidebarNode?) -> HDFSidebarNode? {
        guard let node else {
            return nil
        }

        if node.object.path == path {
            return node
        }

        for child in node.children {
            if let match = self.node(for: path, startingAt: child) {
                return match
            }
        }

        return nil
    }
}

struct HDFDocumentSidebarView: View {
    @StateObject private var model: HDFDocumentViewModel
    @ObservedObject private var closeAction: HDFDocumentCloseAction
    @AppStorage(HDFPreferenceKeys.relativeXAxisDisplay) private var usesRelativeXAxisDisplay = true
    #if os(iOS)
    @AppStorage("HDFThemePreference") private var themePreferenceRawValue = HDFThemePreference.system.rawValue
    #endif
    private let hasCloseAction: Bool

    init(file: HDF5File, closeAction: HDFDocumentCloseAction? = nil) {
        _model = StateObject(wrappedValue: HDFDocumentViewModel(file: file))
        let suppliedCloseAction = closeAction
        let closeAction = suppliedCloseAction ?? HDFDocumentCloseAction()
        _closeAction = ObservedObject(wrappedValue: closeAction)
        hasCloseAction = suppliedCloseAction != nil
    }

    var body: some View {
        #if os(iOS)
        documentView
            .preferredColorScheme(themePreference.colorScheme)
        #else
        documentView
        #endif
    }

    private var documentView: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            HDFObjectDetailPanel(model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            closeToolbarItem
            reloadToolbarItem
            datasetViewToolbarItem
            plotPreferencesToolbarItem
            #if os(iOS)
            themeToolbarItem
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 860, minHeight: 560)
        .toolbarBackground(.hidden, for: .windowToolbar)
        #elseif os(iOS)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarTitleDisplayMode(.inline)
        #endif
    }

    #if os(iOS)
    private var themePreference: HDFThemePreference {
        get {
            HDFThemePreference(rawValue: themePreferenceRawValue) ?? .system
        }
        nonmutating set {
            themePreferenceRawValue = newValue.rawValue
        }
    }
    #endif

    @ToolbarContentBuilder
    private var closeToolbarItem: some ToolbarContent {
        if hasCloseAction {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    closeAction.close()
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var reloadToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.reloadNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Reload from disk (⌘R). Updates automatically when the file changes.")
            .accessibilityLabel("Reload")
        }
    }

    @ToolbarContentBuilder
    private var datasetViewToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if model.selectedObject?.kind == .dataset {
                Picker("Dataset View", selection: datasetDetailModeBinding) {
                    ForEach(model.availableDatasetDetailModes) { mode in
                        Image(systemName: mode.symbolName)
                            .tag(mode)
                            .accessibilityLabel(mode.title)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: model.availableDatasetDetailModes.count > 2 ? 132 : 92)
                .accessibilityLabel("Dataset View")
            }
        }
    }

    private var datasetDetailModeBinding: Binding<HDFDatasetDetailMode> {
        Binding(
            get: { model.datasetDetailMode },
            set: { model.setDatasetDetailModeAfterViewUpdate($0) }
        )
    }

    @ToolbarContentBuilder
    private var plotPreferencesToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Toggle(isOn: $usesRelativeXAxisDisplay) {
                    Label("Start X Axis at Zero", systemImage: "plus.forwardslash.minus")
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Plot Preferences")
        }
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private var themeToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Theme", selection: Binding(
                    get: { themePreference },
                    set: { themePreference = $0 }
                )) {
                    ForEach(HDFThemePreference.allCases) { preference in
                        Label(preference.title, systemImage: preference.symbolName)
                            .tag(preference)
                    }
                }
            } label: {
                Image(systemName: themePreference.symbolName)
            }
            .accessibilityLabel("Preferences")
        }
    }
    #endif

    @ViewBuilder
    private var sidebar: some View {
        HDFObjectSidebar(model: model)
            .navigationTitle("Contents")
        #if os(macOS)
            .navigationSplitViewColumnWidth(min: 240, ideal: 310, max: 420)
        #else
            .toolbarTitleDisplayMode(.inline)
        #endif
    }
}

#if os(iOS)
private enum HDFThemePreference: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .system:
            "System"
        case .dark:
            "Dark"
        case .light:
            "Light"
        }
    }

    var symbolName: String {
        switch self {
        case .system:
            "circle.lefthalf.filled"
        case .dark:
            "moon.fill"
        case .light:
            "sun.max.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .dark:
            .dark
        case .light:
            .light
        }
    }
}
#endif

private struct HDFObjectSidebar: View {
    @ObservedObject var model: HDFDocumentViewModel

    var body: some View {
        List(selection: $model.selectedPath) {
            if let rootNode = model.rootNode {
                HDFSidebarNodeView(node: rootNode, model: model)
            } else if let error = model.rootError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .listStyle(.sidebar)
        .onChange(of: model.selectedPath) { _, path in
            model.selectPath(path)
        }
    }
}

private struct HDFSidebarNodeView: View {
    @ObservedObject var node: HDFSidebarNode
    @ObservedObject var model: HDFDocumentViewModel
    @State private var columnsExpandedOverride: Bool?

    var body: some View {
        if node.object.canHaveChildren {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { model.expandedPaths.contains(node.id) },
                    set: { model.setExpanded(node, isExpanded: $0) }
                )
            ) {
                if node.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 18)
                }

                if let errorMessage = node.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 18)
                }

                ForEach(node.children, id: \.id) { child in
                    HDFSidebarNodeView(node: child, model: model)
                }
            } label: {
                rowLabel
            }
            .tag(node.id)
        } else if node.object.kind == .dataset {
            DisclosureGroup(isExpanded: columnDisclosureBinding) {
                HDFDatasetColumnSidebarView(node: node, model: model)
                    .padding(.leading, 6)
            } label: {
                rowLabel
            }
            .tag(node.id)
        } else {
            rowLabel
                .tag(node.id)
        }
    }

    /// Dataset column lists start collapsed once there are more than 10 columns,
    /// until the user toggles the disclosure triangle themselves.
    private var columnDisclosureBinding: Binding<Bool> {
        Binding(
            get: { columnsExpandedOverride ?? ((node.object.estimatedColumnCount ?? 0) <= 10) },
            set: { columnsExpandedOverride = $0 }
        )
    }

    private var rowLabel: some View {
        HDFObjectRow(file: model.file, object: node.object)
            .contentShape(Rectangle())
            .onTapGesture {
                model.select(node)
            }
    }
}

private struct HDFObjectRow: View {
    let file: HDF5File
    let object: HDF5Object

    var body: some View {
        HStack(spacing: 8) {
            // The root object represents the file itself, so show a document icon.
            Image(systemName: object.path == "/" ? "doc" : object.kind.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(object.displayName)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            if object.childCount > 0 {
                Text("\(object.childCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HDFObjectInfoButton(file: file, object: object)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .accessibilityLabel(Text("\(object.displayName), \(object.kind.displayName)"))
    }
}

private struct HDFDatasetColumnInfo: Identifiable {
    let index: Int
    let label: String

    var id: Int {
        index
    }
}

@MainActor
private final class HDFDatasetColumnSidebarViewModel: ObservableObject {
    private let file: HDF5File
    private let path: String
    private let maxColumns: UInt64 = 64
    private var didLoad = false

    @Published var columns: [HDFDatasetColumnInfo] = []
    @Published var defaultSelection: Set<Int> = []
    @Published var totalColumnCount: UInt64?
    @Published var errorMessage: String?
    @Published var isLoading = false

    init(file: HDF5File, path: String) {
        self.file = file
        self.path = path
    }

    var isColumnTruncated: Bool {
        guard let totalColumnCount else {
            return false
        }
        return UInt64(columns.count) < totalColumnCount
    }

    func loadIfNeeded() async {
        guard !didLoad, !isLoading else {
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            let hdf5File = file
            let datasetPath = path
            let columnLimit = maxColumns
            let preview = try await perform {
                try hdf5File.datasetTableWindow(
                    at: datasetPath,
                    startRow: 0,
                    maxRows: 1,
                    maxColumns: columnLimit
                )
            }

            let displayedColumnCount = Int(clamping: preview.columnCount)
            totalColumnCount = preview.totalColumnCount
            columns = (0..<displayedColumnCount).map { column in
                HDFDatasetColumnInfo(
                    index: column,
                    label: HDFDatasetColumnLabel.label(
                        for: column,
                        columnLabels: preview.columnLabels,
                        displayedColumnCount: displayedColumnCount
                    )
                )
            }
            defaultSelection = HDFPlotColumnSelectionDefaults.defaultSelectedIndices(
                columnLabels: preview.columnLabels,
                columnCount: displayedColumnCount,
                hasExternalXAxis: !preview.xAxisValues.isEmpty
            )
            didLoad = true
        } catch {
            errorMessage = error.localizedDescription
            columns = []
            defaultSelection = []
        }
        isLoading = false
    }

    private func perform<Value>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct HDFDatasetColumnSidebarView: View {
    @ObservedObject var node: HDFSidebarNode
    @ObservedObject var model: HDFDocumentViewModel
    @StateObject private var columnModel: HDFDatasetColumnSidebarViewModel

    init(node: HDFSidebarNode, model: HDFDocumentViewModel) {
        self.node = node
        self.model = model
        _columnModel = StateObject(
            wrappedValue: HDFDatasetColumnSidebarViewModel(
                file: model.file,
                path: node.object.path
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if columnModel.isLoading, columnModel.columns.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Columns")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            if let errorMessage = columnModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.vertical, 2)
            }

            ForEach(columnModel.columns) { column in
                columnToggle(column)
            }

            if columnModel.isColumnTruncated, let totalColumnCount = columnModel.totalColumnCount {
                Text("\(totalColumnCount - UInt64(columnModel.columns.count)) more columns")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.vertical, 2)
            }
        }
        .font(.body)
        .task {
            await columnModel.loadIfNeeded()
        }
    }

    private func columnToggle(_ column: HDFDatasetColumnInfo) -> some View {
        let isSelected = model.isPlotColumnSelected(
            path: node.object.path,
            columnIndex: column.index,
            defaultSelection: columnModel.defaultSelection
        )
        let isXAxis = model.isPlotXAxisColumn(path: node.object.path, columnIndex: column.index)

        return Button {
            model.setPlotColumnSelected(
                !isSelected,
                node: node,
                columnIndex: column.index,
                defaultSelection: columnModel.defaultSelection
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .imageScale(.small)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 14)

                Text(column.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)

                if isXAxis {
                    Image(systemName: "arrow.left.and.right")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("X Axis")
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                model.setPlotXAxisColumn(
                    column.index,
                    node: node,
                    defaultSelection: columnModel.defaultSelection
                )
            } label: {
                Label("Use as X Axis", systemImage: "arrow.left.and.right")
            }

            if isXAxis {
                Button {
                    model.clearPlotXAxisColumn(node: node)
                } label: {
                    Label("Clear X Axis", systemImage: "xmark.circle")
                }
            }
        }
        .accessibilityLabel("\(column.label) Plot Column")
        .accessibilityValue(isXAxis ? "X Axis" : (isSelected ? "Plotted" : "Not Plotted"))
    }
}

private enum HDFDatasetColumnLabel {
    static func label(for column: Int, columnLabels: [String], displayedColumnCount: Int) -> String {
        if column < columnLabels.count, !columnLabels[column].isEmpty {
            return columnLabels[column]
        }
        return displayedColumnCount == 1 ? "Value" : "C\(column)"
    }
}

private enum HDFPlotColumnSelectionDefaults {
    /// Column labels treated as axis/index columns, and therefore not plotted by default.
    static let defaultExcludedPlotLabels: Set<String> = ["time", "sample_number", "sample"]

    static func defaultSelectedIndices(columnLabels: [String],
                                       columnCount: Int,
                                       hasExternalXAxis: Bool) -> Set<Int> {
        guard columnCount > 0 else {
            return []
        }

        let normalizedLabels = columnLabels.map { $0.lowercased() }
        let excludedAxisLabels = Self.defaultExcludedPlotLabels
        let dataColumns = (0..<columnCount).filter { column in
            guard column < normalizedLabels.count else {
                return true
            }
            return !excludedAxisLabels.contains(normalizedLabels[column])
        }

        if hasExternalXAxis || dataColumns.count < columnCount {
            return Set(dataColumns)
        }

        if columnCount == 1 {
            return [0]
        }

        if columnCount == 2 {
            return [1]
        }

        return []
    }
}

@MainActor
private final class HDFObjectInfoViewModel: ObservableObject {
    private let file: HDF5File
    private let path: String
    private var didLoad = false

    @Published var attributes: [HDF5Attribute] = []
    @Published var errorMessage: String?
    @Published var isLoading = false

    init(file: HDF5File, path: String) {
        self.file = file
        self.path = path
    }

    func loadIfNeeded() async {
        guard !didLoad, !isLoading else {
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            let hdf5File = file
            let objectPath = path
            attributes = try await perform {
                try hdf5File.attributes(of: objectPath)
            }
            didLoad = true
        } catch {
            errorMessage = error.localizedDescription
            attributes = []
        }
        isLoading = false
    }

    private func perform<Value>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct HDFObjectInfoButton: View {
    let object: HDF5Object

    @StateObject private var model: HDFObjectInfoViewModel
    @State private var isPresented = false

    init(file: HDF5File, object: HDF5Object) {
        self.object = object
        _model = StateObject(wrappedValue: HDFObjectInfoViewModel(file: file, path: object.path))
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Object Info")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            HDFObjectInfoPopover(object: object, model: model)
                .task {
                    await model.loadIfNeeded()
                }
        }
    }
}

private struct HDFObjectInfoPopover: View {
    let object: HDF5Object
    @ObservedObject var model: HDFObjectInfoViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HDFObjectSummaryView(object: object)

                Divider()

                if model.isLoading, model.attributes.isEmpty {
                    ProgressView("Loading Attributes")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else {
                    HDFAttributeList(attributes: model.attributes)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, idealWidth: 680, maxWidth: 760, minHeight: 320, idealHeight: 560, maxHeight: 760)
    }
}

private struct HDFObjectDetailPanel: View {
    @ObservedObject var model: HDFDocumentViewModel

    var body: some View {
        Group {
            if let object = model.selectedObject {
                if object.kind == .dataset {
                    HDFDatasetDataView(
                        object: object,
                        model: model
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Select a Dataset", systemImage: "tablecells")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("Select an Object", systemImage: "sidebar.left")
            }
        }
        .hdfDocumentNavigationTitle(model)
    }
}

private extension View {
    @ViewBuilder
    func hdfDocumentNavigationTitle(_ model: HDFDocumentViewModel) -> some View {
        #if os(iOS)
        if model.selectedBreadcrumbTitle.isEmpty {
            self
                .navigationTitle(model.fileName)
                .navigationDocument(model.file.url)
                .toolbarTitleDisplayMode(.inline)
        } else {
            self
                .navigationTitle(model.fileName)
                .navigationSubtitle(model.selectedBreadcrumbTitle)
                .navigationDocument(model.file.url)
                .toolbarTitleDisplayMode(.inline)
        }
        #else
        if model.selectedBreadcrumbTitle.isEmpty {
            self
                .navigationTitle(model.fileName)
                .navigationDocument(model.file.url)
        } else {
            self
                .navigationTitle(model.fileName)
                .navigationSubtitle(model.selectedBreadcrumbTitle)
                .navigationDocument(model.file.url)
        }
        #endif
    }
}

private struct HDFObjectSummaryView: View {
    let object: HDF5Object

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(object.displayName, systemImage: object.kind.symbolName)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.middle)

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Kind", value: object.kind.displayName)
                LabeledContent("Path") {
                    Text(object.path)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if !object.detailSummary.isEmpty {
                    LabeledContent("Summary", value: object.detailSummary)
                }
                if object.storageSize > 0 {
                    LabeledContent("Storage", value: byteCountString(object.storageSize))
                }
                LabeledContent("Attributes", value: "\(object.attributeCount)")
                if object.linkKind != .hard {
                    LabeledContent("Link", value: object.linkKind.displayName)
                }
                if !object.linkTarget.isEmpty {
                    LabeledContent("Target") {
                        Text(object.linkTarget)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }
}

private struct HDFAttributeList: View {
    let attributes: [HDF5Attribute]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Attributes", systemImage: "tag")
                .font(.headline)

            if attributes.isEmpty {
                Text("No attributes")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(attributes.enumerated()), id: \.offset) { _, attribute in
                        attributeRow(attribute)
                    }
                }
            }
        }
    }

    private func attributeRow(_ attribute: HDF5Attribute) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(attribute.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 10) {
                    Text(attribute.typeDescription)
                    if !attribute.shapeDescription.isEmpty {
                        Text(attribute.shapeDescription)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .frame(minWidth: 160, idealWidth: 210, maxWidth: 240, alignment: .leading)

            if !attribute.valuePreview.isEmpty {
                HDFAttributeValueView(attribute: attribute)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

private struct HDFAttributeValueView: View {
    let attribute: HDF5Attribute

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayValue)
                .font(attribute.prefersNaturalTextValue ? .body : .body.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if attribute.isValueTruncated {
                Text("Preview truncated")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displayValue: String {
        guard attribute.prefersNaturalTextValue else {
            return attribute.valuePreview
        }

        return attribute.valuePreview
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
            .joined(separator: "\n")
    }
}

private extension HDF5Attribute {
    var prefersNaturalTextValue: Bool {
        typeDescription.localizedCaseInsensitiveContains("string")
    }
}

fileprivate enum HDFDatasetDetailMode: String, CaseIterable, Identifiable {
    case table
    case plot
    case image

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .table:
            "Table"
        case .plot:
            "Plot"
        case .image:
            "Image"
        }
    }

    var symbolName: String {
        switch self {
        case .table:
            "tablecells"
        case .plot:
            "chart.xyaxis.line"
        case .image:
            "photo"
        }
    }
}

private struct HDFDatasetDataView: View {
    let object: HDF5Object
    @ObservedObject var model: HDFDocumentViewModel

    var body: some View {
        Group {
            switch model.datasetDetailMode {
            case .table:
                HDFDatasetTableContent(file: model.file, object: object, documentModel: model)
                    .id("\(object.path)#\(model.reloadGeneration)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .plot:
                HDFDatasetPlotContent(
                    file: model.file,
                    object: object,
                    selectedColumnIndices: model.explicitPlotColumnSelection(for: object.path),
                    xAxisColumnIndex: model.explicitPlotXAxisColumn(for: object.path),
                    documentModel: model
                )
                    .id("\(object.path)#\(model.reloadGeneration)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .image:
                HDFDatasetImageContent(file: model.file, object: object)
                    .id("\(object.path)#\(model.reloadGeneration)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(.container, edges: model.datasetDetailMode == .plot ? .top : [])
    }
}

@MainActor
private final class HDFDatasetImageViewModel: ObservableObject {
    private let file: HDF5File
    private let path: String
    private var didRequestLoad = false

    @Published var image: CGImage?
    @Published var info: HDF5DatasetImage?
    @Published var errorMessage: String?
    @Published var isLoading = false

    init(file: HDF5File, path: String) {
        self.file = file
        self.path = path
    }

    func loadIfNeeded() async {
        guard !didRequestLoad else {
            return
        }
        didRequestLoad = true
        isLoading = true
        errorMessage = nil

        let hdf5File = file
        let datasetPath = path
        do {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HDF5DatasetImage, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try hdf5File.datasetImage(at: datasetPath))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            info = result
            image = Self.makeImage(from: result)
            if image == nil {
                errorMessage = "Could not render this dataset as an image."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private static func makeImage(from image: HDF5DatasetImage) -> CGImage? {
        guard image.width > 0, image.height > 0 else {
            return nil
        }
        let bytesPerRow = image.width * 4
        guard image.rgba.count >= bytesPerRow * image.height else {
            return nil
        }
        guard let provider = CGDataProvider(data: image.rgba as CFData) else {
            return nil
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

private struct HDFDatasetImageContent: View {
    @StateObject private var model: HDFDatasetImageViewModel

    init(file: HDF5File, object: HDF5Object) {
        _model = StateObject(wrappedValue: HDFDatasetImageViewModel(file: file, path: object.path))
    }

    var body: some View {
        Group {
            if let image = model.image {
                VStack(spacing: 0) {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()

                    if let caption = model.info.map(HDFDatasetImageContent.caption) {
                        Text(caption)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                            .padding(.bottom, 10)
                    }
                }
            } else if let errorMessage = model.errorMessage {
                ContentUnavailableView(
                    "Can't Show as Image",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Loading Image")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await model.loadIfNeeded()
        }
    }

    private static func caption(_ info: HDF5DatasetImage) -> String {
        var parts: [String] = ["\(info.sourceWidth) × \(info.sourceHeight)"]

        switch info.channels {
        case 1:
            parts.append("grayscale")
        case 2:
            parts.append("grayscale + alpha")
        case 3:
            parts.append("RGB")
        case 4:
            parts.append("RGBA")
        default:
            parts.append("\(info.channels) channels")
        }

        if info.isDownsampled {
            parts.append("shown at \(info.width) × \(info.height)")
        }
        if info.isNormalized {
            parts.append(String(format: "scaled from [%g, %g]", info.minValue, info.maxValue))
        }

        return parts.joined(separator: " · ")
    }
}

@MainActor
private final class HDFDatasetTableViewModel: ObservableObject {
    private let file: HDF5File
    private let path: String
    private let dimensions: [Int]
    private let onSliceChange: (([Int]) -> Void)?
    private let pageSize: UInt64 = 80
    private let maxColumns: UInt64 = 64
    private var didRequestInitialPage = false
    private var didReachEnd = false
    private var isLoadMoreScheduled = false
    private var generation = 0

    @Published var rows: [HDF5DatasetTableRow] = []
    @Published var totalRowCount: UInt64?
    @Published var totalColumnCount: UInt64?
    @Published var displayedColumnCount = 0
    @Published var columnLabels: [String] = []
    @Published var columnDisplayPrecisions: [Int] = []
    @Published var summary: String?
    @Published var errorMessage: String?
    @Published var isLoading = false
    /// Fixed index along each dimension past the first two (rows × columns).
    @Published var sliceIndices: [Int]

    init(
        file: HDF5File,
        path: String,
        dimensions: [Int] = [],
        initialSlices: [Int] = [],
        onSliceChange: (([Int]) -> Void)? = nil
    ) {
        self.file = file
        self.path = path
        self.dimensions = dimensions
        self.onSliceChange = onSliceChange
        // Start from any restored slice indices, padded/clamped to the real dimensions.
        let count = max(0, dimensions.count - 2)
        self.sliceIndices = (0..<count).map { slot in
            let proposed = slot < initialSlices.count ? initialSlices[slot] : 0
            let size = dimensions[slot + 2]
            return min(max(0, proposed), max(0, size - 1))
        }
    }

    /// Dimensions beyond rows/columns that the user can step through, skipping
    /// any of size 1 (nothing to choose). `slot` indexes into `sliceIndices`.
    var trailingAxes: [(slot: Int, dimension: Int, size: Int)] {
        guard dimensions.count > 2 else { return [] }
        return (2..<dimensions.count).compactMap { dimension in
            let size = dimensions[dimension]
            guard size > 1 else { return nil }
            return (slot: dimension - 2, dimension: dimension, size: size)
        }
    }

    func updateSlice(slot: Int, to index: Int) {
        guard slot >= 0, slot < sliceIndices.count, sliceIndices[slot] != index else {
            return
        }
        sliceIndices[slot] = index
        onSliceChange?(sliceIndices)
        reloadFromStart()
    }

    private func reloadFromStart() {
        generation += 1
        rows = []
        didReachEnd = false
        isLoadMoreScheduled = false
        isLoading = true
        Task { @MainActor in
            await performLoad()
        }
    }

    var canLoadMore: Bool {
        guard !didReachEnd else {
            return false
        }
        guard let totalRowCount else {
            return true
        }
        return UInt64(rows.count) < totalRowCount
    }

    var isColumnTruncated: Bool {
        guard let totalColumnCount else {
            return false
        }
        return UInt64(displayedColumnCount) < totalColumnCount
    }

    func loadInitialPageIfNeeded() async {
        guard !didRequestInitialPage else {
            return
        }
        didRequestInitialPage = true
        await Task.yield()
        await loadNextPage()
    }

    func loadMoreIfNeeded(after row: HDF5DatasetTableRow) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }),
              rows.count - index <= 12 else {
            return
        }

        guard !isLoadMoreScheduled else {
            return
        }

        isLoadMoreScheduled = true
        Task { @MainActor in
            await Task.yield()
            isLoadMoreScheduled = false
            await loadNextPage()
        }
    }

    func loadNextPage() async {
        guard !isLoading, canLoadMore else {
            return
        }
        await performLoad()
    }

    private func performLoad() async {
        guard canLoadMore else {
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil
        let generationAtStart = generation
        do {
            let hdf5File = file
            let datasetPath = path
            let startRow = UInt64(rows.count)
            let rowLimit = pageSize
            let columnLimit = maxColumns
            let slices = sliceIndices.map(UInt64.init)
            let page = try await perform {
                try hdf5File.datasetTableWindow(
                    at: datasetPath,
                    startRow: startRow,
                    maxRows: rowLimit,
                    maxColumns: columnLimit,
                    sliceStarts: slices
                )
            }

            // A slice change during the read invalidates this page.
            guard generationAtStart == generation else {
                return
            }

            totalRowCount = page.totalRowCount
            totalColumnCount = page.totalColumnCount
            displayedColumnCount = Int(clamping: page.columnCount)
            columnLabels = page.columnLabels
            columnDisplayPrecisions = page.columnDisplayPrecisions
            summary = page.summary

            let parsedRows = Self.tableRows(from: page)
            if parsedRows.isEmpty {
                didReachEnd = true
            } else {
                rows.append(contentsOf: parsedRows)
                didReachEnd = UInt64(rows.count) >= page.totalRowCount
            }
        } catch {
            if generationAtStart == generation {
                errorMessage = error.localizedDescription
            }
        }
        if generationAtStart == generation {
            isLoading = false
        }
    }

    private func perform<Value>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func tableRows(from preview: HDF5DatasetPreview) -> [HDF5DatasetTableRow] {
        let rowCount = Int(clamping: preview.rowCount)
        let columnCount = Int(clamping: preview.columnCount)
        guard rowCount > 0, columnCount > 0 else {
            return []
        }

        let lines = preview.text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == rowCount else {
            return []
        }

        return lines.enumerated().map { rowOffset, line in
            var cells = line
                .split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            if cells.count < columnCount {
                cells.append(contentsOf: Array(repeating: "", count: columnCount - cells.count))
            } else if cells.count > columnCount {
                cells = Array(cells.prefix(columnCount))
            }

            return HDF5DatasetTableRow(
                rowIndex: preview.startRow + (UInt64(rowOffset) * max(1, preview.rowStride)),
                cells: cells
            )
        }
    }
}

private struct HDFDatasetTableContent: View {
    @StateObject private var model: HDFDatasetTableViewModel

    init(file: HDF5File, object: HDF5Object, documentModel: HDFDocumentViewModel) {
        let path = object.path
        _model = StateObject(
            wrappedValue: HDFDatasetTableViewModel(
                file: file,
                path: path,
                dimensions: object.datasetDimensions ?? [],
                initialSlices: documentModel.sliceSelection(for: path) ?? [],
                onSliceChange: { [weak documentModel] slices in
                    documentModel?.setSliceSelection(slices, for: path)
                }
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.trailingAxes.isEmpty {
                HDFDatasetSliceControl(model: model)
                Divider()
            }

            ZStack(alignment: .bottomLeading) {
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if model.rows.isEmpty, model.isLoading {
                    ProgressView("Loading Table")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.rows.isEmpty {
                    ContentUnavailableView("No Table Data", systemImage: "tablecells")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HDFDatasetLazyTableView(model: model)
                }

                HDFDatasetTableStatusBar(model: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await model.loadInitialPageIfNeeded()
        }
    }
}

private struct HDFDatasetSliceControl: View {
    @ObservedObject var model: HDFDatasetTableViewModel

    var body: some View {
        HStack(spacing: 18) {
            Label("Slice", systemImage: "square.3.layers.3d.down.right")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

            ForEach(model.trailingAxes, id: \.slot) { axis in
                let value = model.sliceIndices.indices.contains(axis.slot) ? model.sliceIndices[axis.slot] : 0
                Stepper(
                    value: Binding(
                        get: { value },
                        set: { model.updateSlice(slot: axis.slot, to: $0) }
                    ),
                    in: 0...(axis.size - 1)
                ) {
                    HStack(spacing: 6) {
                        Text("Dim \(axis.dimension)")
                            .foregroundStyle(.secondary)
                        Text("\(value) / \(axis.size - 1)")
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
                .fixedSize()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct HDFDatasetLazyTableView: View {
    @ObservedObject var model: HDFDatasetTableViewModel

    var body: some View {
        Table(model.rows) {
            TableColumn("Row") { row in
                Text("\(row.rowIndex)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .onAppear {
                        model.loadMoreIfNeeded(after: row)
                    }
            }
            .width(min: 72, ideal: 92, max: 140)

            TableColumnForEach(Array(0..<model.displayedColumnCount), id: \.self) { column in
                TableColumn(columnLabel(for: column)) { (row: HDF5DatasetTableRow) in
                    Text(cellValue(in: row, at: column))
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .width(min: 96, ideal: 148, max: 320)
            }

            if model.isColumnTruncated {
                TableColumn("...") { _ in
                    Text("...")
                        .foregroundStyle(.secondary)
                }
                .width(min: 36, ideal: 44, max: 56)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func columnLabel(for column: Int) -> String {
        HDFDatasetColumnLabel.label(
            for: column,
            columnLabels: model.columnLabels,
            displayedColumnCount: model.displayedColumnCount
        )
    }

    private func cellValue(in row: HDF5DatasetTableRow, at column: Int) -> String {
        guard column < row.cells.count else {
            return ""
        }
        let precision = column < model.columnDisplayPrecisions.count ? model.columnDisplayPrecisions[column] : nil
        return HDFNumericValueFormatter.string(row.cells[column], precision: precision)
    }
}

private struct HDFDatasetTableStatusBar: View {
    @ObservedObject var model: HDFDatasetTableViewModel

    var body: some View {
        Group {
            if isVisible {
                HStack(spacing: 8) {
                    if model.isLoading {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading")
                    } else if model.canLoadMore {
                        Button("Load More") {
                            Task {
                                await model.loadNextPage()
                            }
                        }
                        .buttonStyle(.borderless)
                    }

                    if let summary = model.summary {
                        Text(summary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if model.isColumnTruncated, let totalColumnCount = model.totalColumnCount {
                        Text("Showing \(model.displayedColumnCount) of \(totalColumnCount) columns")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    private var isVisible: Bool {
        model.isLoading || model.canLoadMore || model.summary != nil || model.isColumnTruncated
    }
}

@MainActor
private final class HDFDatasetPlotViewModel: ObservableObject {
    private let file: HDF5File
    private let path: String
    private var activeRequest: HDFDatasetPlotLoadRequest?

    @Published var preview: HDF5DatasetPreview?
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published private(set) var loadedRequest: HDFDatasetPlotLoadRequest?

    init(file: HDF5File, path: String) {
        self.file = file
        self.path = path
    }

    static func targetRows(forPixelWidth pixelWidth: CGFloat) -> UInt64 {
        guard pixelWidth.isFinite, pixelWidth > 0 else {
            return 512
        }

        let raw = Int(ceil(pixelWidth * 2))
        let clamped = min(max(raw, 256), 4096)
        let bucket = 128
        return UInt64(min(4096, ((clamped + bucket - 1) / bucket) * bucket))
    }

    func loadIfNeeded(_ request: HDFDatasetPlotLoadRequest) async {
        let request = request.normalized
        guard loadedRequest != request || preview == nil else {
            return
        }
        guard activeRequest != request else {
            return
        }

        activeRequest = request
        await Task.yield()
        guard activeRequest == request else {
            return
        }
        isLoading = true
        errorMessage = nil

        do {
            let hdf5File = file
            let datasetPath = path
            let loadedPreview = try await perform {
                try hdf5File.datasetPlotPreview(
                    at: datasetPath,
                    startRow: request.startRow,
                    rowCount: request.rowCount,
                    targetRows: request.targetRows,
                    maxColumns: request.columnLimit
                )
            }

            guard activeRequest == request else {
                return
            }

            preview = loadedPreview
            loadedRequest = request
        } catch {
            guard activeRequest == request else {
                return
            }

            preview = nil
            errorMessage = error.localizedDescription
        }

        if activeRequest == request {
            activeRequest = nil
            isLoading = false
        }
    }

    private func perform<Value>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct HDFDatasetPlotContent: View {
    @StateObject private var model: HDFDatasetPlotViewModel
    @Environment(\.displayScale) private var displayScale
    @AppStorage(HDFPreferenceKeys.relativeXAxisDisplay) private var usesRelativeXAxisDisplay = true
    @State private var visibleXRange: HDFPlotRange?
    @State private var visibleYRange: HDFPlotRange?
    @State private var retainedFullLineXRange: HDFPlotRange?
    let selectedColumnIndices: Set<Int>?
    let xAxisColumnIndex: Int?
    private let onViewportChange: (HDFPersistedViewport?) -> Void

    init(file: HDF5File,
         object: HDF5Object,
         selectedColumnIndices: Set<Int>?,
         xAxisColumnIndex: Int?,
         documentModel: HDFDocumentViewModel) {
        self.selectedColumnIndices = selectedColumnIndices
        self.xAxisColumnIndex = xAxisColumnIndex
        _model = StateObject(wrappedValue: HDFDatasetPlotViewModel(file: file, path: object.path))

        let path = object.path
        let saved = documentModel.plotViewport(for: path)
        _visibleXRange = State(initialValue: saved?.x.map { HDFPlotRange(minimum: $0.minimum, maximum: $0.maximum) })
        _visibleYRange = State(initialValue: saved?.y.map { HDFPlotRange(minimum: $0.minimum, maximum: $0.maximum) })
        onViewportChange = { [weak documentModel] viewport in
            documentModel?.setPlotViewport(viewport, for: path)
        }
    }

    private func saveViewport() {
        if visibleXRange == nil, visibleYRange == nil {
            onViewportChange(nil)
        } else {
            onViewportChange(HDFPersistedViewport(
                x: visibleXRange.map { HDFPersistedRange(minimum: $0.minimum, maximum: $0.maximum) },
                y: visibleYRange.map { HDFPersistedRange(minimum: $0.minimum, maximum: $0.maximum) }
            ))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            if let plotData {
                ZStack(alignment: .bottomTrailing) {
                    switch plotData.kind {
                    case .lineSeries(let series):
                        HDFLinePlotView(
                            series: series,
                            visibleXRange: $visibleXRange,
                            visibleYRange: $visibleYRange,
                            fullXRange: retainedFullLineXRange ?? plotData.lineXRange,
                            usesRelativeXAxisDisplay: usesRelativeXAxisDisplay
                        )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                            .onAppear {
                                captureFullLineRangeIfNeeded(from: plotData)
                            }
                            .onChange(of: model.loadedRequest) { _, _ in
                                captureFullLineRangeIfNeeded(from: plotData)
                            }
                    case .heatmap:
                        HDFHeatmapPlotView(
                            data: plotData,
                            visibleXRange: $visibleXRange,
                            visibleYRange: $visibleYRange,
                            usesRelativeXAxisDisplay: usesRelativeXAxisDisplay
                        )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                    }

                    HDFPlotStatsBadge(summary: plotData.summary)
                        .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            } else if model.isLoading {
                ProgressView("Loading Plot")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ContentUnavailableView("No Numeric Plot", systemImage: "chart.xyaxis.line")
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: selectedColumnIndices) { _, _ in
            visibleXRange = nil
            visibleYRange = nil
            retainedFullLineXRange = nil
        }
        .onChange(of: xAxisColumnIndex) { _, _ in
            visibleXRange = nil
            visibleYRange = nil
            retainedFullLineXRange = nil
        }
        .onChange(of: visibleXRange) { _, _ in saveViewport() }
        .onChange(of: visibleYRange) { _, _ in saveViewport() }
        .background {
            GeometryReader { proxy in
                let targetRows = HDFDatasetPlotViewModel.targetRows(
                    forPixelWidth: proxy.size.width * displayScale
                )
                let columnLimit = Self.columnLimit(
                    for: selectedColumnIndices,
                    xAxisColumnIndex: xAxisColumnIndex
                )
                let request = Self.loadRequest(
                    plotData: plotData,
                    visibleXRange: visibleXRange,
                    visibleYRange: visibleYRange,
                    targetRows: targetRows,
                    columnLimit: columnLimit
                )
                Color.clear
                    .task(id: request) {
                        await model.loadIfNeeded(request)
                    }
            }
        }
    }

    private var plotData: HDFDatasetPlotData? {
        guard let preview = model.preview else {
            return nil
        }
        return HDFDatasetPlotData(
            preview: preview,
            selectedColumnIndices: selectedColumnIndices,
            xAxisColumnIndex: xAxisColumnIndex
        )
    }

    private static func columnLimit(for selectedColumnIndices: Set<Int>?,
                                    xAxisColumnIndex: Int?) -> UInt64 {
        let maximumSelectedColumn = [
            selectedColumnIndices?.max(),
            xAxisColumnIndex
        ]
        .compactMap { $0 }
        .max()

        guard let maximumSelectedColumn else {
            return 16
        }
        return UInt64(min(64, max(16, maximumSelectedColumn + 1)))
    }

    private static func loadRequest(plotData: HDFDatasetPlotData?,
                                    visibleXRange: HDFPlotRange?,
                                    visibleYRange: HDFPlotRange?,
                                    targetRows: UInt64,
                                    columnLimit: UInt64) -> HDFDatasetPlotLoadRequest {
        let rowWindow: HDFPlotRowWindow?
        if let plotData,
           case .lineSeries = plotData.kind,
           let visibleXRange {
            rowWindow = plotData.rowWindow(forXRange: visibleXRange)
        } else if let plotData,
                  case .heatmap = plotData.kind,
                  let visibleYRange {
            rowWindow = plotData.rowWindow(forRowRange: visibleYRange)
        } else {
            rowWindow = nil
        }

        return HDFDatasetPlotLoadRequest(
            startRow: rowWindow?.startRow ?? 0,
            rowCount: rowWindow?.rowCount,
            targetRows: targetRows,
            columnLimit: columnLimit
        ).normalized
    }

    private func captureFullLineRangeIfNeeded(from plotData: HDFDatasetPlotData) {
        guard model.loadedRequest?.isFullRange == true || retainedFullLineXRange == nil else {
            return
        }
        retainedFullLineXRange = plotData.lineXRange
    }
}

private struct HDFDatasetPlotLoadRequest: Hashable {
    let startRow: UInt64
    let rowCount: UInt64?
    let targetRows: UInt64
    let columnLimit: UInt64

    var isFullRange: Bool {
        startRow == 0 && rowCount == nil
    }

    var normalized: HDFDatasetPlotLoadRequest {
        HDFDatasetPlotLoadRequest(
            startRow: startRow,
            rowCount: rowCount.map { max(2, $0) },
            targetRows: max(2, targetRows),
            columnLimit: max(1, min(columnLimit, 64))
        )
    }
}

private struct HDFDatasetPlotData {
    enum Kind {
        case lineSeries([HDFLineSeries])
        case heatmap
    }

    let rowCount: Int
    let columnCount: Int
    let columnLabels: [String]
    let columnDisplayPrecisions: [Int]
    let previewXAxisLabel: String
    let previewXAxisValues: [Double]
    let previewXAxisSource: String
    let previewXAxisDisplayPrecision: Int?
    let startRow: UInt64
    let rowStride: UInt64
    let totalRowCount: UInt64
    let values: [Double]
    let minimumValue: Double
    let maximumValue: Double
    let selectedColumnIndices: Set<Int>?
    let xAxisColumnIndex: Int?

    init?(preview: HDF5DatasetPreview,
          selectedColumnIndices: Set<Int>? = nil,
          xAxisColumnIndex: Int? = nil) {
        let rows = Int(clamping: preview.rowCount)
        let columns = Int(clamping: preview.columnCount)
        guard rows > 0, columns > 0, rows <= 4096, columns <= 4096 else {
            return nil
        }

        let validSelectedColumnIndices: Set<Int>?
        if let selectedColumnIndices {
            let validIndices = selectedColumnIndices.filter { index in
                index >= 0 && index < columns
            }
            guard !validIndices.isEmpty else {
                return nil
            }
            validSelectedColumnIndices = Set(validIndices)
        } else {
            validSelectedColumnIndices = nil
        }

        let lines = preview.text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == rows else {
            return nil
        }

        var parsedValues: [Double] = []
        parsedValues.reserveCapacity(rows * columns)
        for line in lines {
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cells.count == columns else {
                return nil
            }

            for cell in cells {
                let text = String(cell).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let value = Double(text), value.isFinite else {
                    return nil
                }
                parsedValues.append(value)
            }
        }

        guard parsedValues.count >= 2,
              let minimum = parsedValues.min(),
              let maximum = parsedValues.max() else {
            return nil
        }

        rowCount = rows
        columnCount = columns
        columnLabels = preview.columnLabels
        columnDisplayPrecisions = preview.columnDisplayPrecisions
        previewXAxisLabel = preview.xAxisLabel
        previewXAxisValues = preview.xAxisValues.count >= rows ? Array(preview.xAxisValues.prefix(rows)) : []
        previewXAxisSource = preview.xAxisSource
        previewXAxisDisplayPrecision = preview.xAxisDisplayPrecision > 0 ? preview.xAxisDisplayPrecision : nil
        startRow = preview.startRow
        rowStride = max(1, preview.rowStride)
        totalRowCount = preview.totalRowCount
        values = parsedValues
        minimumValue = minimum
        maximumValue = maximum
        self.selectedColumnIndices = validSelectedColumnIndices
        if let xAxisColumnIndex, xAxisColumnIndex >= 0 && xAxisColumnIndex < columns {
            self.xAxisColumnIndex = xAxisColumnIndex
        } else {
            self.xAxisColumnIndex = nil
        }
    }

    var kind: Kind {
        if let selectedColumnIndices,
           let selectedSeries = selectedSeries(using: selectedColumnIndices) {
            return .lineSeries(selectedSeries)
        }

        if let explicitXAxisSeries {
            return .lineSeries(explicitXAxisSeries)
        }

        if let explicitTimeSeries {
            return .lineSeries(explicitTimeSeries)
        }

        if let previewAxisSeries {
            return .lineSeries(previewAxisSeries)
        }

        if let sampleNumberSeries {
            return .lineSeries(sampleNumberSeries)
        }

        if columnCount == 1 {
            return .lineSeries([
                HDFLineSeries(
                    index: 0,
                    label: label(for: 0, fallback: "Value"),
                    xAxisLabel: "Row",
                    xAxisSource: "row index",
                    xDisplayPrecision: nil,
                    yDisplayPrecision: displayPrecision(for: 0),
                    points: values.enumerated().map { index, value in
                        HDFPlotPoint(x: rowNumber(for: index), y: value)
                    }
                )
            ])
        }

        if columnCount == 2, rowCount > 1 {
            let points = (0..<rowCount).map { row in
                HDFPlotPoint(x: values[row * columnCount], y: values[row * columnCount + 1])
            }
            return .lineSeries([
                HDFLineSeries(
                    index: 0,
                    label: label(for: 1, fallback: "Value"),
                    xAxisLabel: label(for: 0, fallback: "X"),
                    xAxisSource: "first column",
                    xDisplayPrecision: displayPrecision(for: 0),
                    yDisplayPrecision: displayPrecision(for: 1),
                    points: points
                )
            ])
        }

        return .heatmap
    }

    var summary: String {
        "samples: \(rowCount), stride: \(rowStride)"
    }

    var lineXRange: HDFPlotRange? {
        guard case .lineSeries(let series) = kind else {
            return nil
        }
        return HDFPlotRange(optionalValues: series.flatMap { $0.points.map(\.x) })
    }

    func rowWindow(forXRange xRange: HDFPlotRange) -> HDFPlotRowWindow? {
        guard case .lineSeries(let series) = kind,
              let firstSeries = series.first,
              firstSeries.points.count >= 2,
              totalRowCount > 0,
              let firstX = firstSeries.points.first?.x,
              let lastX = firstSeries.points.last?.x,
              firstX != lastX else {
            return nil
        }

        let firstRow = Double(startRow)
        let lastRow = Double(startRow + (UInt64(max(0, rowCount - 1)) * rowStride))
        guard firstRow != lastRow else {
            return nil
        }

        let lowerX = min(xRange.minimum, xRange.maximum)
        let upperX = max(xRange.minimum, xRange.maximum)
        let rowA = firstRow + ((lowerX - firstX) / (lastX - firstX)) * (lastRow - firstRow)
        let rowB = firstRow + ((upperX - firstX) / (lastX - firstX)) * (lastRow - firstRow)
        return rowWindow(lowerRow: min(rowA, rowB), upperRow: max(rowA, rowB))
    }

    func rowWindow(forRowRange rowRange: HDFPlotRange) -> HDFPlotRowWindow? {
        rowWindow(
            lowerRow: min(rowRange.minimum, rowRange.maximum),
            upperRow: max(rowRange.minimum, rowRange.maximum)
        )
    }

    private var explicitTimeSeries: [HDFLineSeries]? {
        guard let xIndex = normalizedLabels.firstIndex(of: "time") else {
            return nil
        }
        return series(usingColumn: xIndex, xAxisLabel: label(for: xIndex, fallback: "time"), xAxisSource: "time")
    }

    private var explicitXAxisSeries: [HDFLineSeries]? {
        guard let xAxisColumnIndex else {
            return nil
        }
        return series(
            usingColumn: xAxisColumnIndex,
            xAxisLabel: label(for: xAxisColumnIndex, fallback: "C\(xAxisColumnIndex)"),
            xAxisSource: "selected column"
        )
    }

    private var previewAxisSeries: [HDFLineSeries]? {
        guard previewXAxisValues.count >= rowCount else {
            return nil
        }
        return series(
            using: previewXAxisValues,
            xAxisLabel: previewXAxisLabel.isEmpty ? "time" : previewXAxisLabel,
            xAxisSource: previewXAxisSource.isEmpty ? "axis metadata" : previewXAxisSource,
            xDisplayPrecision: previewXAxisDisplayPrecision
        )
    }

    private var sampleNumberSeries: [HDFLineSeries]? {
        guard let xIndex = normalizedLabels.firstIndex(of: "sample_number") else {
            return nil
        }
        return series(usingColumn: xIndex, xAxisLabel: label(for: xIndex, fallback: "sample_number"), xAxisSource: "sample_number")
    }

    private func selectedSeries(using selectedColumnIndices: Set<Int>) -> [HDFLineSeries]? {
        let yIndices = selectedColumnIndices.sorted()
        guard !yIndices.isEmpty else {
            return nil
        }

        if let xAxisColumnIndex {
            return series(
                usingColumn: xAxisColumnIndex,
                xAxisLabel: label(for: xAxisColumnIndex, fallback: "C\(xAxisColumnIndex)"),
                xAxisSource: "selected column",
                yIndices: yIndices
            )
        }

        if let xIndex = normalizedLabels.firstIndex(of: "time") {
            return series(
                usingColumn: xIndex,
                xAxisLabel: label(for: xIndex, fallback: "time"),
                xAxisSource: "time",
                yIndices: yIndices
            )
        }

        if previewXAxisValues.count >= rowCount {
            return series(
                using: previewXAxisValues,
                xAxisLabel: previewXAxisLabel.isEmpty ? "time" : previewXAxisLabel,
                xAxisSource: previewXAxisSource.isEmpty ? "axis metadata" : previewXAxisSource,
                xDisplayPrecision: previewXAxisDisplayPrecision,
                yIndices: yIndices
            )
        }

        if let xIndex = normalizedLabels.firstIndex(of: "sample_number") {
            return series(
                usingColumn: xIndex,
                xAxisLabel: label(for: xIndex, fallback: "sample_number"),
                xAxisSource: "sample_number",
                yIndices: yIndices
            )
        }

        return series(
            using: (0..<rowCount).map { rowNumber(for: $0) },
            xAxisLabel: "Row",
            xAxisSource: "row index",
            xDisplayPrecision: nil,
            yIndices: yIndices
        )
    }

    private var normalizedLabels: [String] {
        columnLabels.map { $0.lowercased() }
    }

    private func series(usingColumn xIndex: Int,
                        xAxisLabel: String,
                        xAxisSource: String,
                        yIndices: [Int]? = nil) -> [HDFLineSeries]? {
        let xValues = (0..<rowCount).map { row in
            values[row * columnCount + xIndex]
        }
        return series(
            using: xValues,
            xAxisLabel: xAxisLabel,
            xAxisSource: xAxisSource,
            xDisplayPrecision: displayPrecision(for: xIndex),
            excludedYIndices: [xIndex],
            yIndices: yIndices
        )
    }

    private func series(using xValues: [Double],
                        xAxisLabel: String,
                        xAxisSource: String,
                        xDisplayPrecision: Int? = nil,
                        excludedYIndices: Set<Int> = [],
                        yIndices requestedYIndices: [Int]? = nil) -> [HDFLineSeries]? {
        guard rowCount > 1, xValues.count >= rowCount else {
            return nil
        }

        let yIndices: [Int]
        if let requestedYIndices {
            yIndices = requestedYIndices.filter { index in
                index >= 0 && index < columnCount && !excludedYIndices.contains(index)
            }
        } else {
            let excludedLabels = HDFPlotColumnSelectionDefaults.defaultExcludedPlotLabels
            yIndices = (0..<columnCount).filter { index in
                guard !excludedYIndices.contains(index) else {
                    return false
                }
                if index < normalizedLabels.count {
                    return !excludedLabels.contains(normalizedLabels[index])
                }
                return true
            }
        }

        guard !yIndices.isEmpty else {
            return nil
        }

        return yIndices.map { columnIndex in
            let points = (0..<rowCount).map { row in
                HDFPlotPoint(
                    x: xValues[row],
                    y: values[row * columnCount + columnIndex]
                )
            }
            return HDFLineSeries(
                index: columnIndex,
                label: label(for: columnIndex, fallback: "C\(columnIndex)"),
                xAxisLabel: xAxisLabel,
                xAxisSource: xAxisSource,
                xDisplayPrecision: xDisplayPrecision,
                yDisplayPrecision: displayPrecision(for: columnIndex),
                points: points
            )
        }
    }

    private func label(for column: Int, fallback: String) -> String {
        if column < columnLabels.count, !columnLabels[column].isEmpty {
            return columnLabels[column]
        }
        return fallback
    }

    private func displayPrecision(for column: Int) -> Int? {
        guard column < columnDisplayPrecisions.count else {
            return nil
        }
        let precision = columnDisplayPrecisions[column]
        return precision > 0 ? precision : nil
    }

    private func rowWindow(lowerRow: Double, upperRow: Double) -> HDFPlotRowWindow? {
        guard totalRowCount > 0,
              lowerRow.isFinite,
              upperRow.isFinite else {
            return nil
        }

        let maximumRow = Double(totalRowCount - 1)
        let clampedLower = min(max(0, lowerRow), maximumRow)
        let clampedUpper = min(max(0, upperRow), maximumRow)
        let visibleSpan = max(1, clampedUpper - clampedLower)
        let padding = max(2, visibleSpan * 0.08)
        let paddedLower = min(max(0, floor(clampedLower - padding)), maximumRow)
        let paddedUpper = min(max(0, ceil(clampedUpper + padding)), maximumRow)
        guard paddedUpper >= paddedLower else {
            return nil
        }

        let start = UInt64(paddedLower)
        let count = max(2, UInt64(paddedUpper - paddedLower + 1))
        if start == 0 && count >= totalRowCount {
            return nil
        }

        return HDFPlotRowWindow(startRow: start, rowCount: count)
    }

    private func rowNumber(for index: Int) -> Double {
        Double(startRow + (UInt64(index) * rowStride))
    }
}

private struct HDFPlotRowWindow: Hashable {
    let startRow: UInt64
    let rowCount: UInt64
}

private struct HDFLineSeries: Identifiable {
    let index: Int
    let label: String
    let xAxisLabel: String
    let xAxisSource: String
    let xDisplayPrecision: Int?
    let yDisplayPrecision: Int?
    let points: [HDFPlotPoint]

    var id: Int {
        index
    }
}

private struct HDFPlotPoint {
    let x: Double
    let y: Double
}

private struct HDFPlotViewport: Equatable {
    var xRange: HDFPlotRange?
    var yRange: HDFPlotRange?
}

@MainActor
private final class HDFPlotUndoTarget: ObservableObject {
    /// A private undo manager for plot zoom/pan. Using this instead of the document's
    /// undo manager keeps zooming from marking this read-only document as "edited".
    /// Zoom can still be reverted with the on-plot reset controls.
    let manager = UndoManager()
    var onRestore: ((HDFPlotViewport) -> Void)?

    func restore(_ viewport: HDFPlotViewport) {
        onRestore?(viewport)
    }
}

private struct HDFLinePlotView: View {
    let series: [HDFLineSeries]
    @Binding var visibleXRange: HDFPlotRange?
    @Binding var visibleYRange: HDFPlotRange?
    let fullXRange: HDFPlotRange?
    let usesRelativeXAxisDisplay: Bool

    @State private var dragSelectionRect: CGRect?
    @State private var activeZoomUndoStart: HDFPlotViewport?
    @StateObject private var undoTarget = HDFPlotUndoTarget()

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let plotRect = HDFPlotLayout.plotRect(for: size)
            let fullXRange = (self.fullXRange ?? Self.fullXRange(for: series))
            let fullYRange = Self.fullYRange(for: series)
            let xRange = (visibleXRange ?? fullXRange).clamped(to: fullXRange)
            let yRange = (visibleYRange ?? fullYRange).clamped(to: fullYRange)

            Canvas { context, canvasSize in
                drawPlot(
                    context: context,
                    size: canvasSize,
                    plotRect: HDFPlotLayout.plotRect(for: canvasSize),
                    xRange: xRange,
                    yRange: yRange
                )
            }
            .contentShape(Rectangle())
            .overlay {
                HDFPlotInteractionOverlay(
                    onPan: { translation in
                        pan(
                            translation: translation,
                            plotRect: plotRect,
                            fullXRange: fullXRange,
                            fullYRange: fullYRange
                        )
                    },
                    onZoom: { request in
                        zoom(
                            request,
                            fullXRange: fullXRange,
                            fullYRange: fullYRange
                        )
                    },
                    onContinuousZoomBegan: beginZoomUndoAction,
                    onContinuousZoomEnded: endZoomUndoAction,
                    onReset: resetViewport,
                    onZoomSelectionChanged: { selection in
                        dragSelectionRect = selection?.previewRect(in: plotRect)
                    },
                    onZoomSelectionEnded: { selection in
                        zoom(
                            to: selection,
                            plotRect: plotRect,
                            xRange: xRange,
                            yRange: yRange,
                            fullXRange: fullXRange,
                            fullYRange: fullYRange
                        )
                        dragSelectionRect = nil
                    }
                )
            }
            .overlay {
                HDFPlotDragSelectionView(rect: dragSelectionRect)
            }
            .overlay(alignment: .topLeading) {
                if series.count > 1 {
                    HDFPlotLegend(series: series)
                        .padding(.leading, plotRect.minX + 8)
                        .padding(.top, plotRect.minY + 8)
                        .padding(.trailing, 82)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                HDFPlotResetControls(
                    onResetHorizontal: resetHorizontalViewport,
                    onResetVertical: resetVerticalViewport
                )
                .padding(.leading, plotRect.minX + 8)
                .padding(.bottom, size.height - plotRect.maxY + 8)
            }
        }
        .frame(minHeight: 260)
        .onAppear {
            undoTarget.onRestore = restoreViewport
        }
        .onDisappear {
            undoTarget.onRestore = nil
        }
    }

    private func drawPlot(context: GraphicsContext,
                          size: CGSize,
                          plotRect: CGRect,
                          xRange: HDFPlotRange,
                          yRange: HDFPlotRange) {
        let drawableSeries = series.filter { $0.points.count >= 2 }
        guard !drawableSeries.isEmpty,
              size.width > 0,
              size.height > 0 else {
            return
        }

        let xAxisLabel = drawableSeries.first?.xAxisLabel.isEmpty == false ? drawableSeries[0].xAxisLabel : "X"
        let yAxisLabel = drawableSeries.count == 1 ? drawableSeries[0].label : "Value"
        let xDisplayPrecision = drawableSeries.compactMap(\.xDisplayPrecision).max()
        let yDisplayPrecision = drawableSeries.compactMap(\.yDisplayPrecision).max()

        drawAxes(
            context: context,
            size: size,
            plotRect: plotRect,
            xRange: xRange,
            yRange: yRange,
            xAxisLabel: xAxisLabel,
            yAxisLabel: yAxisLabel,
            xDisplayPrecision: xDisplayPrecision,
            yDisplayPrecision: yDisplayPrecision
        )

        func point(for plotPoint: HDFPlotPoint) -> CGPoint {
            let xRatio = xRange.unclampedRatio(for: plotPoint.x)
            let yRatio = yRange.unclampedRatio(for: plotPoint.y)
            return CGPoint(
                x: plotRect.minX + plotRect.width * CGFloat(xRatio),
                y: plotRect.maxY - plotRect.height * CGFloat(yRatio)
            )
        }

        var clippedContext = context
        clippedContext.clip(to: Path(plotRect))
        for item in drawableSeries {
            let color = HDFPlotSeriesPalette.color(at: item.index)
            var linePath = Path()
            linePath.move(to: point(for: item.points[0]))
            for plotPoint in item.points.dropFirst() {
                linePath.addLine(to: point(for: plotPoint))
            }
            clippedContext.stroke(linePath, with: .color(color), lineWidth: 2)

            if item.points.count <= 128 {
                for plotPoint in item.points {
                    let center = point(for: plotPoint)
                    let rect = CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)
                    clippedContext.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
    }

    private func drawAxes(context: GraphicsContext,
                          size: CGSize,
                          plotRect: CGRect,
                          xRange: HDFPlotRange,
                          yRange: HDFPlotRange,
                          xAxisLabel: String,
                          yAxisLabel: String,
                          xDisplayPrecision: Int?,
                          yDisplayPrecision: Int?) {
        var gridPath = Path()
        let xAxisDisplay = HDFPlotXAxisDisplay(
            range: xRange,
            tickCount: 5,
            usesRelativeDisplay: usesRelativeXAxisDisplay,
            displayPrecision: xDisplayPrecision
        )

        for value in yRange.ticks(count: 5) {
            let ratio = CGFloat(yRange.ratio(for: value))
            let y = plotRect.maxY - plotRect.height * ratio
            gridPath.move(to: CGPoint(x: plotRect.minX, y: y))
            gridPath.addLine(to: CGPoint(x: plotRect.maxX, y: y))

            context.draw(
                Text(HDFNumericValueFormatter.string(value, precision: yDisplayPrecision))
                    .font(.body)
                    .foregroundStyle(.secondary),
                at: CGPoint(x: plotRect.minX - 8, y: y),
                anchor: .trailing
            )
        }
        for value in xAxisDisplay.ticks {
            let ratio = CGFloat(xRange.ratio(for: value))
            let x = plotRect.minX + plotRect.width * ratio
            gridPath.move(to: CGPoint(x: x, y: plotRect.minY))
            gridPath.addLine(to: CGPoint(x: x, y: plotRect.maxY))

            context.draw(
                Text(xAxisDisplay.label(for: value))
                    .font(.body)
                    .foregroundStyle(.secondary),
                at: CGPoint(x: x, y: plotRect.maxY + 7),
                anchor: .top
            )
        }
        context.stroke(gridPath, with: .color(.secondary.opacity(0.18)), lineWidth: 1)

        var axisPath = Path()
        axisPath.move(to: CGPoint(x: plotRect.minX, y: plotRect.minY))
        axisPath.addLine(to: CGPoint(x: plotRect.minX, y: plotRect.maxY))
        axisPath.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.maxY))
        context.stroke(axisPath, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
        HDFPlotAxisLabelDrawer.drawYAxisLabel(
            yAxisLabel,
            context: context,
            plotRect: plotRect
        )
        context.draw(
            Text(xAxisLabel)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary),
            at: CGPoint(x: plotRect.midX, y: size.height - 4),
            anchor: .bottom
        )

        if let offsetLabel = xAxisDisplay.offsetLabel {
            context.draw(
                Text(offsetLabel)
                    .font(.body)
                    .foregroundStyle(.secondary),
                at: CGPoint(x: plotRect.minX, y: size.height - 4),
                anchor: .bottomLeading
            )
        }
    }

    private func pan(translation: CGSize,
                     plotRect: CGRect,
                     fullXRange: HDFPlotRange,
                     fullYRange: HDFPlotRange) {
        guard plotRect.width > 0, plotRect.height > 0 else {
            return
        }

        let xRange = (visibleXRange ?? fullXRange).clamped(to: fullXRange)
        let yRange = (visibleYRange ?? fullYRange).clamped(to: fullYRange)
        let xDelta = -Double(translation.width / plotRect.width) * xRange.span
        let yDelta = Double(translation.height / plotRect.height) * yRange.span
        setViewport(HDFPlotViewport(
            xRange: xRange.shifted(by: xDelta, within: fullXRange),
            yRange: yRange.shifted(by: yDelta, within: fullYRange)
        ))
    }

    private func zoom(_ zoom: HDFPlotZoom,
                      fullXRange: HDFPlotRange,
                      fullYRange: HDFPlotRange) {
        let xRange = (visibleXRange ?? fullXRange).clamped(to: fullXRange)
        let yRange = (visibleYRange ?? fullYRange).clamped(to: fullYRange)
        var nextViewport = currentViewport
        switch zoom.axis {
        case .horizontal:
            nextViewport.xRange = xRange.zoomed(by: Double(zoom.scale), around: 0.5, within: fullXRange)
        case .vertical:
            nextViewport.yRange = yRange.zoomed(by: Double(zoom.scale), around: 0.5, within: fullYRange)
        }
        setViewport(nextViewport)
    }

    private func zoom(to selection: HDFPlotDragSelection,
                      plotRect: CGRect,
                      xRange: HDFPlotRange,
                      yRange: HDFPlotRange,
                      fullXRange: HDFPlotRange,
                      fullYRange: HDFPlotRange) {
        guard let rect = selection.previewRect(in: plotRect),
              plotRect.width > 0,
              plotRect.height > 0 else {
            return
        }

        var nextViewport = currentViewport
        if selection.mode.updatesHorizontal {
            let x0 = Double((rect.minX - plotRect.minX) / plotRect.width)
            let x1 = Double((rect.maxX - plotRect.minX) / plotRect.width)
            nextViewport.xRange = HDFPlotRange(
                minimum: xRange.minimum + (xRange.span * min(x0, x1)),
                maximum: xRange.minimum + (xRange.span * max(x0, x1))
            ).clamped(to: fullXRange)
        }
        if selection.mode.updatesVertical {
            let y0 = Double((plotRect.maxY - rect.maxY) / plotRect.height)
            let y1 = Double((plotRect.maxY - rect.minY) / plotRect.height)
            nextViewport.yRange = HDFPlotRange(
                minimum: yRange.minimum + (yRange.span * min(y0, y1)),
                maximum: yRange.minimum + (yRange.span * max(y0, y1))
            ).clamped(to: fullYRange)
        }
        applyViewport(nextViewport)
    }

    private func resetViewport() {
        applyViewport(HDFPlotViewport(xRange: nil, yRange: nil), actionName: "Reset Plot Zoom")
    }

    private func resetHorizontalViewport() {
        applyViewport(HDFPlotViewport(xRange: nil, yRange: visibleYRange), actionName: "Reset Horizontal Zoom")
    }

    private func resetVerticalViewport() {
        applyViewport(HDFPlotViewport(xRange: visibleXRange, yRange: nil), actionName: "Reset Vertical Zoom")
    }

    private static func fullXRange(for series: [HDFLineSeries]) -> HDFPlotRange {
        HDFPlotRange(values: series.flatMap { $0.points.map(\.x) })
    }

    private static func fullYRange(for series: [HDFLineSeries]) -> HDFPlotRange {
        HDFPlotRange(values: series.flatMap { $0.points.map(\.y) })
    }

    private var currentViewport: HDFPlotViewport {
        HDFPlotViewport(xRange: visibleXRange, yRange: visibleYRange)
    }

    private func setViewport(_ viewport: HDFPlotViewport) {
        visibleXRange = viewport.xRange
        visibleYRange = viewport.yRange
    }

    private func applyViewport(_ viewport: HDFPlotViewport, actionName: String = "Zoom Plot") {
        let previousViewport = currentViewport
        guard previousViewport != viewport else {
            return
        }
        registerUndo(to: previousViewport, actionName: actionName)
        setViewport(viewport)
    }

    private func restoreViewport(_ viewport: HDFPlotViewport) {
        applyViewport(viewport)
    }

    private func beginZoomUndoAction() {
        if activeZoomUndoStart == nil {
            activeZoomUndoStart = currentViewport
        }
    }

    private func endZoomUndoAction() {
        guard let previousViewport = activeZoomUndoStart else {
            return
        }
        activeZoomUndoStart = nil
        registerUndo(to: previousViewport, actionName: "Zoom Plot")
    }

    private func registerUndo(to viewport: HDFPlotViewport, actionName: String) {
        guard currentViewport != viewport else {
            return
        }
        let undoManager = undoTarget.manager
        undoManager.registerUndo(withTarget: undoTarget) { target in
            target.restore(viewport)
        }
        undoManager.setActionName(actionName)
    }
}

private struct HDFHeatmapPlotView: View {
    let data: HDFDatasetPlotData
    @Binding var visibleXRange: HDFPlotRange?
    @Binding var visibleYRange: HDFPlotRange?
    let usesRelativeXAxisDisplay: Bool

    @State private var dragSelectionRect: CGRect?
    @State private var activeZoomUndoStart: HDFPlotViewport?
    @StateObject private var undoTarget = HDFPlotUndoTarget()

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let plotRect = HDFPlotLayout.plotRect(for: size)
            let fullXRange = self.fullXRange
            let fullYRange = self.fullYRange
            let xRange = (visibleXRange ?? fullXRange).clamped(to: fullXRange)
            let yRange = (visibleYRange ?? fullYRange).clamped(to: fullYRange)

            Canvas { context, canvasSize in
                drawHeatmap(
                    context: context,
                    size: canvasSize,
                    plotRect: HDFPlotLayout.plotRect(for: canvasSize),
                    xRange: xRange,
                    yRange: yRange
                )
            }
            .contentShape(Rectangle())
            .overlay {
                HDFPlotInteractionOverlay(
                    onPan: { translation in
                        pan(
                            translation: translation,
                            plotRect: plotRect,
                            fullXRange: fullXRange,
                            fullYRange: fullYRange
                        )
                    },
                    onZoom: { request in
                        zoom(
                            request,
                            fullXRange: fullXRange,
                            fullYRange: fullYRange
                        )
                    },
                    onContinuousZoomBegan: beginZoomUndoAction,
                    onContinuousZoomEnded: endZoomUndoAction,
                    onReset: resetViewport,
                    onZoomSelectionChanged: { selection in
                        dragSelectionRect = selection?.previewRect(in: plotRect)
                    },
                    onZoomSelectionEnded: { selection in
                        zoom(
                            to: selection,
                            plotRect: plotRect,
                            xRange: xRange,
                            yRange: yRange,
                            fullXRange: fullXRange,
                            fullYRange: fullYRange
                        )
                        dragSelectionRect = nil
                    }
                )
            }
            .overlay {
                HDFPlotDragSelectionView(rect: dragSelectionRect)
            }
            .overlay(alignment: .bottomLeading) {
                HDFPlotResetControls(
                    onResetHorizontal: resetHorizontalViewport,
                    onResetVertical: resetVerticalViewport
                )
                .padding(.leading, plotRect.minX + 8)
                .padding(.bottom, size.height - plotRect.maxY + 8)
            }
        }
        .frame(minHeight: 260)
        .onAppear {
            undoTarget.onRestore = restoreViewport
        }
        .onDisappear {
            undoTarget.onRestore = nil
        }
    }

    private var fullXRange: HDFPlotRange {
        HDFPlotRange(minimum: 0, maximum: Double(max(1, data.columnCount - 1)))
    }

    private var fullYRange: HDFPlotRange {
        HDFPlotRange(minimum: 0, maximum: Double(data.totalRowCount > 1 ? data.totalRowCount - 1 : 1))
    }

    private func drawHeatmap(context: GraphicsContext,
                             size: CGSize,
                             plotRect: CGRect,
                             xRange: HDFPlotRange,
                             yRange: HDFPlotRange) {
        guard data.rowCount > 0,
              data.columnCount > 0,
              size.width > 0,
              size.height > 0 else {
            return
        }

        let valueRange = HDFPlotRange(minimum: data.minimumValue, maximum: data.maximumValue)
        let rowStep = Double(data.rowStride)
        var clippedContext = context
        clippedContext.clip(to: Path(plotRect))

        for row in 0..<data.rowCount {
            let rowCenter = Double(data.startRow + (UInt64(row) * data.rowStride))
            for column in 0..<data.columnCount {
                let value = data.values[row * data.columnCount + column]
                let ratio = valueRange.ratio(for: value)
                let x0 = plotRect.minX + plotRect.width * CGFloat(xRange.ratio(for: Double(column) - 0.5))
                let x1 = plotRect.minX + plotRect.width * CGFloat(xRange.ratio(for: Double(column) + 0.5))
                let y0 = plotRect.minY + plotRect.height * CGFloat(yRange.ratio(for: rowCenter - (rowStep / 2)))
                let y1 = plotRect.minY + plotRect.height * CGFloat(yRange.ratio(for: rowCenter + (rowStep / 2)))
                let rect = CGRect(
                    x: min(x0, x1),
                    y: min(y0, y1),
                    width: abs(x1 - x0),
                    height: abs(y1 - y0)
                ).insetBy(dx: 0.5, dy: 0.5)
                clippedContext.fill(Path(rect), with: .color(HDFPlotPalette.color(for: ratio)))
            }
        }

        drawAxes(
            context: context,
            size: size,
            plotRect: plotRect,
            xRange: xRange,
            yRange: yRange
        )
    }

    private func drawAxes(context: GraphicsContext,
                          size: CGSize,
                          plotRect: CGRect,
                          xRange: HDFPlotRange,
                          yRange: HDFPlotRange) {
        var gridPath = Path()
        let xAxisDisplay = HDFPlotXAxisDisplay(
            range: xRange,
            tickCount: 5,
            usesRelativeDisplay: usesRelativeXAxisDisplay,
            displayPrecision: nil
        )

        for value in yRange.ticks(count: 5) {
            let y = plotRect.minY + plotRect.height * CGFloat(yRange.ratio(for: value))
            gridPath.move(to: CGPoint(x: plotRect.minX, y: y))
            gridPath.addLine(to: CGPoint(x: plotRect.maxX, y: y))
            context.draw(
                Text(HDFNumericValueFormatter.string(value))
                    .font(.body)
                    .foregroundStyle(.secondary),
                at: CGPoint(x: plotRect.minX - 8, y: y),
                anchor: .trailing
            )
        }

        for value in xAxisDisplay.ticks {
            let x = plotRect.minX + plotRect.width * CGFloat(xRange.ratio(for: value))
            gridPath.move(to: CGPoint(x: x, y: plotRect.minY))
            gridPath.addLine(to: CGPoint(x: x, y: plotRect.maxY))
            context.draw(
                Text(xAxisDisplay.label(for: value))
                    .font(.body)
                    .foregroundStyle(.secondary),
                at: CGPoint(x: x, y: plotRect.maxY + 7),
                anchor: .top
            )
        }
        context.stroke(gridPath, with: .color(.secondary.opacity(0.18)), lineWidth: 1)

        var axisPath = Path()
        axisPath.move(to: CGPoint(x: plotRect.minX, y: plotRect.minY))
        axisPath.addLine(to: CGPoint(x: plotRect.minX, y: plotRect.maxY))
        axisPath.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.maxY))
        context.stroke(axisPath, with: .color(.secondary.opacity(0.45)), lineWidth: 1)

        HDFPlotAxisLabelDrawer.drawYAxisLabel(
            "Row",
            context: context,
            plotRect: plotRect
        )
        context.draw(
            Text("Column")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary),
            at: CGPoint(x: plotRect.midX, y: size.height - 4),
            anchor: .bottom
        )

        if let offsetLabel = xAxisDisplay.offsetLabel {
            context.draw(
                Text(offsetLabel)
                    .font(.body)
                    .foregroundStyle(.secondary),
                at: CGPoint(x: plotRect.minX, y: size.height - 4),
                anchor: .bottomLeading
            )
        }
    }

    private func pan(translation: CGSize,
                     plotRect: CGRect,
                     fullXRange: HDFPlotRange,
                     fullYRange: HDFPlotRange) {
        guard plotRect.width > 0, plotRect.height > 0 else {
            return
        }

        let xRange = (visibleXRange ?? fullXRange).clamped(to: fullXRange)
        let yRange = (visibleYRange ?? fullYRange).clamped(to: fullYRange)
        let xDelta = -Double(translation.width / plotRect.width) * xRange.span
        let yDelta = -Double(translation.height / plotRect.height) * yRange.span
        setViewport(HDFPlotViewport(
            xRange: xRange.shifted(by: xDelta, within: fullXRange),
            yRange: yRange.shifted(by: yDelta, within: fullYRange)
        ))
    }

    private func zoom(_ zoom: HDFPlotZoom,
                      fullXRange: HDFPlotRange,
                      fullYRange: HDFPlotRange) {
        let xRange = (visibleXRange ?? fullXRange).clamped(to: fullXRange)
        let yRange = (visibleYRange ?? fullYRange).clamped(to: fullYRange)
        var nextViewport = currentViewport
        switch zoom.axis {
        case .horizontal:
            nextViewport.xRange = xRange.zoomed(by: Double(zoom.scale), around: 0.5, within: fullXRange)
        case .vertical:
            nextViewport.yRange = yRange.zoomed(by: Double(zoom.scale), around: 0.5, within: fullYRange)
        }
        setViewport(nextViewport)
    }

    private func zoom(to selection: HDFPlotDragSelection,
                      plotRect: CGRect,
                      xRange: HDFPlotRange,
                      yRange: HDFPlotRange,
                      fullXRange: HDFPlotRange,
                      fullYRange: HDFPlotRange) {
        guard let rect = selection.previewRect(in: plotRect),
              plotRect.width > 0,
              plotRect.height > 0 else {
            return
        }

        var nextViewport = currentViewport
        if selection.mode.updatesHorizontal {
            let x0 = Double((rect.minX - plotRect.minX) / plotRect.width)
            let x1 = Double((rect.maxX - plotRect.minX) / plotRect.width)
            nextViewport.xRange = HDFPlotRange(
                minimum: xRange.minimum + (xRange.span * min(x0, x1)),
                maximum: xRange.minimum + (xRange.span * max(x0, x1))
            ).clamped(to: fullXRange)
        }
        if selection.mode.updatesVertical {
            let y0 = Double((rect.minY - plotRect.minY) / plotRect.height)
            let y1 = Double((rect.maxY - plotRect.minY) / plotRect.height)
            nextViewport.yRange = HDFPlotRange(
                minimum: yRange.minimum + (yRange.span * min(y0, y1)),
                maximum: yRange.minimum + (yRange.span * max(y0, y1))
            ).clamped(to: fullYRange)
        }
        applyViewport(nextViewport)
    }

    private func resetViewport() {
        applyViewport(HDFPlotViewport(xRange: nil, yRange: nil), actionName: "Reset Plot Zoom")
    }

    private func resetHorizontalViewport() {
        applyViewport(HDFPlotViewport(xRange: nil, yRange: visibleYRange), actionName: "Reset Horizontal Zoom")
    }

    private func resetVerticalViewport() {
        applyViewport(HDFPlotViewport(xRange: visibleXRange, yRange: nil), actionName: "Reset Vertical Zoom")
    }

    private var currentViewport: HDFPlotViewport {
        HDFPlotViewport(xRange: visibleXRange, yRange: visibleYRange)
    }

    private func setViewport(_ viewport: HDFPlotViewport) {
        visibleXRange = viewport.xRange
        visibleYRange = viewport.yRange
    }

    private func applyViewport(_ viewport: HDFPlotViewport, actionName: String = "Zoom Plot") {
        let previousViewport = currentViewport
        guard previousViewport != viewport else {
            return
        }
        registerUndo(to: previousViewport, actionName: actionName)
        setViewport(viewport)
    }

    private func restoreViewport(_ viewport: HDFPlotViewport) {
        applyViewport(viewport)
    }

    private func beginZoomUndoAction() {
        if activeZoomUndoStart == nil {
            activeZoomUndoStart = currentViewport
        }
    }

    private func endZoomUndoAction() {
        guard let previousViewport = activeZoomUndoStart else {
            return
        }
        activeZoomUndoStart = nil
        registerUndo(to: previousViewport, actionName: "Zoom Plot")
    }

    private func registerUndo(to viewport: HDFPlotViewport, actionName: String) {
        guard currentViewport != viewport else {
            return
        }
        let undoManager = undoTarget.manager
        undoManager.registerUndo(withTarget: undoTarget) { target in
            target.restore(viewport)
        }
        undoManager.setActionName(actionName)
    }
}

private enum HDFPlotLayout {
    static func plotRect(for size: CGSize) -> CGRect {
        let leftMargin = min(112, max(88, size.width * 0.18))
        let topMargin: CGFloat = 68
        let bottomMargin = min(74, max(58, size.height * 0.18))
        return CGRect(
            x: leftMargin,
            y: topMargin,
            width: max(1, size.width - leftMargin - 20),
            height: max(1, size.height - bottomMargin - topMargin)
        )
    }
}

private enum HDFPlotAxisLabelDrawer {
    static func drawYAxisLabel(_ label: String,
                               context: GraphicsContext,
                               plotRect: CGRect) {
        var labelContext = context
        labelContext.translateBy(x: max(18, plotRect.minX - 78), y: plotRect.midY)
        labelContext.rotate(by: .degrees(-90))
        labelContext.draw(
            Text(label)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary),
            at: .zero,
            anchor: .center
        )
    }
}

private struct HDFPlotDragSelectionView: View {
    let rect: CGRect?

    var body: some View {
        Canvas { context, _ in
            guard let rect,
                  rect.width > 0,
                  rect.height > 0 else {
                return
            }

            let path = Path(rect)
            context.fill(path, with: .color(.accentColor.opacity(0.14)))
            context.stroke(path, with: .color(.accentColor.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .allowsHitTesting(false)
    }
}

private struct HDFPlotStatsBadge: View {
    let summary: String

    var body: some View {
        Text(summary)
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
        .frame(maxWidth: 260, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }
}

private struct HDFPlotLegend: View {
    let series: [HDFLineSeries]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(series) { item in
                HStack(spacing: 5) {
                    Circle()
                        .fill(HDFPlotSeriesPalette.color(at: item.index))
                        .frame(width: 7, height: 7)
                    Text(item.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: 150, alignment: .leading)
            }
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Plot legend")
    }
}

private struct HDFPlotResetControls: View {
    let onResetHorizontal: () -> Void
    let onResetVertical: () -> Void

    var body: some View {
        HStack(spacing: Self.spacing) {
            Button(action: onResetHorizontal) {
                Image(systemName: "arrow.left.and.right")
                    .frame(width: Self.tapTarget, height: Self.tapTarget)
                    .contentShape(Rectangle())
            }
            .help("Reset Horizontal")

            Button(action: onResetVertical) {
                Image(systemName: "arrow.up.and.down")
                    .frame(width: Self.tapTarget, height: Self.tapTarget)
                    .contentShape(Rectangle())
            }
            .help("Reset Vertical")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .font(Self.iconFont)
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .background(.regularMaterial, in: Capsule())
    }

    // Touch devices need larger hit targets (~44pt); the desktop keeps a compact control.
    #if os(iOS)
    private static let iconFont: Font = .title2
    private static let tapTarget: CGFloat? = 44
    private static let spacing: CGFloat = 8
    private static let horizontalPadding: CGFloat = 8
    private static let verticalPadding: CGFloat = 4
    #else
    private static let iconFont: Font = .body
    private static let tapTarget: CGFloat? = nil
    private static let spacing: CGFloat = 4
    private static let horizontalPadding: CGFloat = 7
    private static let verticalPadding: CGFloat = 5
    #endif
}

private enum HDFPlotZoomAxis {
    case horizontal
    case vertical
}

private enum HDFPlotDragZoomMode {
    case rectangular
    case horizontal
    case vertical

    var updatesHorizontal: Bool {
        self != .vertical
    }

    var updatesVertical: Bool {
        self != .horizontal
    }
}

private struct HDFPlotDragSelection {
    let rect: CGRect
    let mode: HDFPlotDragZoomMode

    init(start: CGPoint, end: CGPoint) {
        rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        mode = Self.mode(for: CGSize(width: end.x - start.x, height: end.y - start.y))
    }

    func previewRect(in plotRect: CGRect) -> CGRect? {
        switch mode {
        case .rectangular:
            let clippedRect = rect.intersection(plotRect)
            guard !clippedRect.isNull, !clippedRect.isEmpty else {
                return nil
            }
            guard clippedRect.width >= 4, clippedRect.height >= 4 else {
                return nil
            }
            return clippedRect
        case .horizontal:
            let minX = max(rect.minX, plotRect.minX)
            let maxX = min(rect.maxX, plotRect.maxX)
            let width = maxX - minX
            guard width >= 4 else {
                return nil
            }
            return CGRect(x: minX, y: plotRect.minY, width: width, height: plotRect.height)
        case .vertical:
            let minY = max(rect.minY, plotRect.minY)
            let maxY = min(rect.maxY, plotRect.maxY)
            let height = maxY - minY
            guard height >= 4 else {
                return nil
            }
            return CGRect(x: plotRect.minX, y: minY, width: plotRect.width, height: height)
        }
    }

    func isLargeEnough(minimumDistance: CGFloat) -> Bool {
        switch mode {
        case .rectangular:
            rect.width >= minimumDistance && rect.height >= minimumDistance
        case .horizontal:
            rect.width >= minimumDistance
        case .vertical:
            rect.height >= minimumDistance
        }
    }

    private static func mode(for translation: CGSize) -> HDFPlotDragZoomMode {
        let width = abs(translation.width)
        let height = abs(translation.height)
        guard width > 0 || height > 0 else {
            return .rectangular
        }

        let axisLockSlope: CGFloat = 0.364
        if height <= width * axisLockSlope {
            return .horizontal
        }
        if width <= height * axisLockSlope {
            return .vertical
        }
        return .rectangular
    }
}

private struct HDFPlotZoom {
    let axis: HDFPlotZoomAxis
    let scale: CGFloat

    static func dominant(horizontalScale: CGFloat,
                         verticalScale: CGFloat,
                         fallbackScale: CGFloat? = nil,
                         verticalPreference: CGFloat = 1) -> HDFPlotZoom? {
        let cleanHorizontal = cleanScale(horizontalScale)
        let cleanVertical = cleanScale(verticalScale)
        let horizontalMagnitude = magnitude(of: cleanHorizontal)
        let verticalMagnitude = magnitude(of: cleanVertical)

        if horizontalMagnitude == 0, verticalMagnitude == 0, let fallbackScale {
            return HDFPlotZoom(axis: .horizontal, scale: cleanScale(fallbackScale))
        }

        // Latch to a single axis, preferring horizontal. Vertical wins only when the
        // vertical component clearly dominates; `verticalPreference` > 1 biases harder
        // toward horizontal (i.e. requires a "quite vertical" pinch to zoom vertically).
        if verticalMagnitude > horizontalMagnitude * verticalPreference {
            return HDFPlotZoom(axis: .vertical, scale: cleanVertical)
        }
        return HDFPlotZoom(axis: .horizontal, scale: cleanHorizontal)
    }

    /// A zoom confined to a single, already-decided axis. Returns nil for a no-op scale.
    static func single(axis: HDFPlotZoomAxis, scale: CGFloat) -> HDFPlotZoom? {
        let clean = cleanScale(scale)
        guard magnitude(of: clean) > 0 else {
            return nil
        }
        return HDFPlotZoom(axis: axis, scale: clean)
    }

    private static func cleanScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else {
            return 1
        }
        return min(64, max(0.015625, scale))
    }

    private static func magnitude(of scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else {
            return 0
        }
        return CGFloat(abs(log(Double(scale))))
    }
}

private struct HDFPlotTouchSpan {
    let width: CGFloat
    let height: CGFloat

    static func span(for points: [CGPoint]) -> HDFPlotTouchSpan? {
        guard points.count >= 2 else {
            return nil
        }

        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(),
              let maxX = xs.max(),
              let minY = ys.min(),
              let maxY = ys.max() else {
            return nil
        }
        return HDFPlotTouchSpan(width: maxX - minX, height: maxY - minY)
    }

    func zoom(to next: HDFPlotTouchSpan,
              minimumSpan: CGFloat,
              fallbackScale: CGFloat? = nil,
              verticalPreference: CGFloat = 1) -> HDFPlotZoom? {
        let horizontalScale = axisScale(from: width, to: next.width, minimumSpan: minimumSpan)
        let verticalScale = axisScale(from: height, to: next.height, minimumSpan: minimumSpan)
        return HDFPlotZoom.dominant(
            horizontalScale: horizontalScale,
            verticalScale: verticalScale,
            fallbackScale: fallbackScale,
            verticalPreference: verticalPreference
        )
    }

    private func axisScale(from previous: CGFloat, to next: CGFloat, minimumSpan: CGFloat) -> CGFloat {
        guard previous >= minimumSpan, next >= minimumSpan else {
            return 1
        }
        return next / previous
    }
}

private struct HDFPlotInteractionOverlay: View {
    let onPan: (CGSize) -> Void
    let onZoom: (HDFPlotZoom) -> Void
    let onContinuousZoomBegan: () -> Void
    let onContinuousZoomEnded: () -> Void
    let onReset: () -> Void
    let onZoomSelectionChanged: (HDFPlotDragSelection?) -> Void
    let onZoomSelectionEnded: (HDFPlotDragSelection) -> Void

    var body: some View {
        #if os(macOS)
        HDFMacPlotInteractionView(
            onPan: onPan,
            onZoom: onZoom,
            onContinuousZoomBegan: onContinuousZoomBegan,
            onContinuousZoomEnded: onContinuousZoomEnded,
            onReset: onReset,
            onZoomSelectionChanged: onZoomSelectionChanged,
            onZoomSelectionEnded: onZoomSelectionEnded
        )
        #elseif os(iOS)
        HDFIOSPlotInteractionView(
            onPan: onPan,
            onZoom: onZoom,
            onContinuousZoomBegan: onContinuousZoomBegan,
            onContinuousZoomEnded: onContinuousZoomEnded,
            onReset: onReset
        )
        #else
        Color.clear
        #endif
    }
}

#if os(macOS)
private struct HDFMacPlotInteractionView: NSViewRepresentable {
    let onPan: (CGSize) -> Void
    let onZoom: (HDFPlotZoom) -> Void
    let onContinuousZoomBegan: () -> Void
    let onContinuousZoomEnded: () -> Void
    let onReset: () -> Void
    let onZoomSelectionChanged: (HDFPlotDragSelection?) -> Void
    let onZoomSelectionEnded: (HDFPlotDragSelection) -> Void

    func makeNSView(context: Context) -> HDFMacPlotInteractionNSView {
        let view = HDFMacPlotInteractionNSView()
        view.onPan = onPan
        view.onZoom = onZoom
        view.onContinuousZoomBegan = onContinuousZoomBegan
        view.onContinuousZoomEnded = onContinuousZoomEnded
        view.onReset = onReset
        view.onZoomSelectionChanged = onZoomSelectionChanged
        view.onZoomSelectionEnded = onZoomSelectionEnded
        return view
    }

    func updateNSView(_ nsView: HDFMacPlotInteractionNSView, context: Context) {
        nsView.onPan = onPan
        nsView.onZoom = onZoom
        nsView.onContinuousZoomBegan = onContinuousZoomBegan
        nsView.onContinuousZoomEnded = onContinuousZoomEnded
        nsView.onReset = onReset
        nsView.onZoomSelectionChanged = onZoomSelectionChanged
        nsView.onZoomSelectionEnded = onZoomSelectionEnded
    }
}

private final class HDFMacPlotInteractionNSView: NSView {
    var onPan: ((CGSize) -> Void)?
    var onZoom: ((HDFPlotZoom) -> Void)?
    var onContinuousZoomBegan: (() -> Void)?
    var onContinuousZoomEnded: (() -> Void)?
    var onReset: (() -> Void)?
    var onZoomSelectionChanged: ((HDFPlotDragSelection?) -> Void)?
    var onZoomSelectionEnded: ((HDFPlotDragSelection) -> Void)?
    private var lastMagnificationSpan: HDFPlotTouchSpan?
    private var isMagnifying = false
    private var dragStart: CGPoint?

    override var acceptsFirstResponder: Bool {
        true
    }

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func scrollWheel(with event: NSEvent) {
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let translation = CGSize(
            width: event.scrollingDeltaX * multiplier,
            height: event.scrollingDeltaY * multiplier
        )
        if translation != .zero {
            onPan?(translation)
        }
    }

    override func magnify(with event: NSEvent) {
        let fallbackScale = max(0.05, 1 + event.magnification)
        let currentSpan = Self.touchSpan(from: event, in: self)

        if event.phase == .began {
            beginMagnificationIfNeeded()
            lastMagnificationSpan = currentSpan
            return
        }

        beginMagnificationIfNeeded()
        if let currentSpan {
            if let previousSpan = lastMagnificationSpan,
               let zoom = previousSpan.zoom(to: currentSpan, minimumSpan: 0.002, fallbackScale: fallbackScale) {
                onZoom?(zoom)
            }
            lastMagnificationSpan = currentSpan
        } else if let zoom = HDFPlotZoom.dominant(
            horizontalScale: fallbackScale,
            verticalScale: 1,
            fallbackScale: fallbackScale
        ) {
            onZoom?(zoom)
        }

        if event.phase == .ended || event.phase == .cancelled {
            lastMagnificationSpan = nil
            endMagnificationIfNeeded()
        }
    }

    override func smartMagnify(with event: NSEvent) {
        onReset?()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = point(from: event)
        onZoomSelectionChanged?(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else {
            return
        }

        let selection = HDFPlotDragSelection(start: dragStart, end: point(from: event))
        onZoomSelectionChanged?(selection)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            onZoomSelectionChanged?(nil)
        }

        guard let dragStart else {
            return
        }

        let selection = HDFPlotDragSelection(start: dragStart, end: point(from: event))
        guard selection.isLargeEnough(minimumDistance: 6) else {
            return
        }
        onZoomSelectionEnded?(selection)
    }

    private static func touchSpan(from event: NSEvent, in view: NSView) -> HDFPlotTouchSpan? {
        let points = event.touches(matching: .touching, in: view).map { touch in
            CGPoint(x: touch.normalizedPosition.x, y: touch.normalizedPosition.y)
        }
        return HDFPlotTouchSpan.span(for: points)
    }

    private func beginMagnificationIfNeeded() {
        guard !isMagnifying else {
            return
        }
        isMagnifying = true
        onContinuousZoomBegan?()
    }

    private func endMagnificationIfNeeded() {
        guard isMagnifying else {
            return
        }
        isMagnifying = false
        onContinuousZoomEnded?()
    }

    private func point(from event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

}
#elseif os(iOS)
private struct HDFIOSPlotInteractionView: UIViewRepresentable {
    let onPan: (CGSize) -> Void
    let onZoom: (HDFPlotZoom) -> Void
    let onContinuousZoomBegan: () -> Void
    let onContinuousZoomEnded: () -> Void
    let onReset: () -> Void

    func makeUIView(context: Context) -> HDFIOSPlotInteractionUIView {
        let view = HDFIOSPlotInteractionUIView()
        view.onPan = onPan
        view.onZoom = onZoom
        view.onContinuousZoomBegan = onContinuousZoomBegan
        view.onContinuousZoomEnded = onContinuousZoomEnded
        view.onReset = onReset
        return view
    }

    func updateUIView(_ uiView: HDFIOSPlotInteractionUIView, context: Context) {
        uiView.onPan = onPan
        uiView.onZoom = onZoom
        uiView.onContinuousZoomBegan = onContinuousZoomBegan
        uiView.onContinuousZoomEnded = onContinuousZoomEnded
        uiView.onReset = onReset
    }
}

private final class HDFIOSPlotInteractionUIView: UIView, UIGestureRecognizerDelegate {
    var onPan: ((CGSize) -> Void)?
    var onZoom: ((HDFPlotZoom) -> Void)?
    var onContinuousZoomBegan: (() -> Void)?
    var onContinuousZoomEnded: (() -> Void)?
    var onReset: (() -> Void)?

    private var lastPinchScale: CGFloat = 1
    private var lockedPinchAxis: HDFPlotZoomAxis?
    private var isPinching = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.delegate = self
        addGestureRecognizer(pan)

        // Two-finger scroll on a trackpad (or a mouse wheel) arrives as an indirect scroll
        // event with no on-screen touches, so the direct two-finger pan above never sees it.
        // A scroll-only recognizer (zero direct touches) routes those to the same pan handler.
        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        scrollPan.allowedScrollTypesMask = .all
        scrollPan.minimumNumberOfTouches = 0
        scrollPan.maximumNumberOfTouches = 0
        scrollPan.delegate = self
        addGestureRecognizer(scrollPan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let reset = UITapGestureRecognizer(target: self, action: #selector(handleReset(_:)))
        reset.numberOfTapsRequired = 2
        reset.numberOfTouchesRequired = 2
        reset.delegate = self
        addGestureRecognizer(reset)
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.translation(in: self)
        let translation = CGSize(width: point.x, height: point.y)
        if translation != .zero {
            onPan?(translation)
            recognizer.setTranslation(.zero, in: self)
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            isPinching = true
            onContinuousZoomBegan?()
            lastPinchScale = recognizer.scale
            // Latch the zoom axis from how the two fingers are oriented (the line between
            // them) — not from how the span changes. It holds for the whole gesture.
            let span = Self.touchSpan(from: recognizer, in: self)
            lockedPinchAxis = span.map(Self.axisForOrientation)
        case .changed:
            guard lastPinchScale != 0 else {
                lastPinchScale = recognizer.scale
                return
            }
            // If the axis wasn't set at .began (touches arrived a frame late), set it now.
            if lockedPinchAxis == nil, let span = Self.touchSpan(from: recognizer, in: self) {
                lockedPinchAxis = Self.axisForOrientation(of: span)
            }
            let incrementalScale = recognizer.scale / lastPinchScale
            lastPinchScale = recognizer.scale

            // Zoom magnitude comes from the pinch itself; the axis is the latched orientation.
            let axis = lockedPinchAxis ?? .horizontal
            if let zoom = HDFPlotZoom.single(axis: axis, scale: incrementalScale) {
                onZoom?(zoom)
            }
        default:
            lastPinchScale = 1
            lockedPinchAxis = nil
            if isPinching {
                isPinching = false
                onContinuousZoomEnded?()
            }
        }
    }

    @objc private func handleReset(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .recognized {
            onReset?()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    /// How much taller than wide the two-finger gap must be before the pinch zooms
    /// vertically. > 1 biases toward horizontal (1 = an even 45° split; larger = stronger
    /// horizontal preference, i.e. fingers must be more clearly stacked to zoom vertically).
    private static let verticalOrientationFactor: CGFloat = 2

    /// Choose the zoom axis from the fingers' orientation. The two-finger bounding box is the
    /// gap between them: width = |Δx|, height = |Δy|. Horizontal is preferred; vertical is
    /// chosen only when the fingers are clearly stacked vertically.
    private static func axisForOrientation(of span: HDFPlotTouchSpan) -> HDFPlotZoomAxis {
        span.height > span.width * verticalOrientationFactor ? .vertical : .horizontal
    }

    private static func touchSpan(from recognizer: UIPinchGestureRecognizer,
                                  in view: UIView) -> HDFPlotTouchSpan? {
        guard recognizer.numberOfTouches >= 2 else {
            return nil
        }

        var points: [CGPoint] = []
        for index in 0..<recognizer.numberOfTouches {
            points.append(recognizer.location(ofTouch: index, in: view))
        }
        return HDFPlotTouchSpan.span(for: points)
    }
}
#endif

private struct HDFPlotXAxisDisplay {
    let offset: Double?
    let ticks: [Double]
    private let displayPrecision: Int?

    init(range: HDFPlotRange,
         tickCount: Int,
         usesRelativeDisplay: Bool,
         displayPrecision: Int?) {
        self.displayPrecision = displayPrecision

        if usesRelativeDisplay {
            offset = range.minimum
            ticks = HDFPlotRange(minimum: 0, maximum: range.span)
                .ticks(count: tickCount)
                .map { range.minimum + $0 }
        } else {
            offset = nil
            ticks = range.ticks(count: tickCount)
        }
    }

    var offsetLabel: String? {
        guard let offset else {
            return nil
        }
        return HDFNumericValueFormatter.signedOffsetString(offset, precision: displayPrecision)
    }

    func label(for value: Double) -> String {
        HDFNumericValueFormatter.string(value - (offset ?? 0), precision: displayPrecision)
    }
}

private struct HDFPlotRange: Hashable {
    let minimum: Double
    let maximum: Double

    var span: Double {
        max(0, maximum - minimum)
    }

    init(values: [Double]) {
        self.init(minimum: values.min() ?? 0, maximum: values.max() ?? 1)
    }

    init?(optionalValues values: [Double]) {
        guard let minimum = values.min(),
              let maximum = values.max() else {
            return nil
        }
        self.init(minimum: minimum, maximum: maximum)
    }

    init(minimum: Double, maximum: Double) {
        if minimum == maximum {
            self.minimum = minimum - 1
            self.maximum = maximum + 1
        } else {
            self.minimum = minimum
            self.maximum = maximum
        }
    }

    func ratio(for value: Double) -> Double {
        guard maximum > minimum else {
            return 0.5
        }
        return min(1, max(0, (value - minimum) / (maximum - minimum)))
    }

    func unclampedRatio(for value: Double) -> Double {
        guard maximum > minimum else {
            return 0.5
        }
        return (value - minimum) / (maximum - minimum)
    }

    func ticks(count: Int) -> [Double] {
        guard count > 1, maximum > minimum else {
            return [minimum]
        }

        let step = Self.niceStep(for: (maximum - minimum) / Double(count - 1))
        guard step.isFinite, step > 0 else {
            return [minimum, maximum]
        }

        let firstTick = (minimum / step).rounded(.up) * step
        let lastTick = (maximum / step).rounded(.down) * step
        let epsilon = step * 1e-10
        var ticks: [Double] = []
        var tick = firstTick
        while tick <= lastTick + epsilon, ticks.count < max(count * 3, count + 2) {
            ticks.append(Self.cleanedTick(tick, step: step))
            tick += step
        }

        if ticks.isEmpty {
            return [Self.cleanedTick((minimum + maximum) / 2, step: step)]
        }
        return ticks
    }

    private static func niceStep(for rawStep: Double) -> Double {
        guard rawStep.isFinite, rawStep > 0 else {
            return rawStep
        }

        let exponent = floor(log10(rawStep))
        let magnitude = pow(10, exponent)
        let fraction = rawStep / magnitude
        let niceFraction: Double
        if fraction <= 1 {
            niceFraction = 1
        } else if fraction <= 2 {
            niceFraction = 2
        } else if fraction <= 2.5 {
            niceFraction = 2.5
        } else if fraction <= 5 {
            niceFraction = 5
        } else {
            niceFraction = 10
        }

        return niceFraction * magnitude
    }

    private static func cleanedTick(_ value: Double, step: Double) -> Double {
        guard value.isFinite, step.isFinite, step > 0 else {
            return value
        }

        let rounded = (value / step).rounded() * step
        return abs(rounded) < step * 1e-10 ? 0 : rounded
    }

    func shifted(by delta: Double, within fullRange: HDFPlotRange) -> HDFPlotRange {
        guard span < fullRange.span else {
            return fullRange
        }

        return HDFPlotRange(minimum: minimum + delta, maximum: maximum + delta)
            .clamped(to: fullRange)
    }

    func zoomed(by scale: Double, around anchorRatio: Double, within fullRange: HDFPlotRange) -> HDFPlotRange {
        guard scale.isFinite, scale > 0, fullRange.span > 0 else {
            return self
        }

        let cleanAnchor = min(1, max(0, anchorRatio))
        let cleanScale = min(64, max(0.015625, scale))
        let minimumSpan = max(fullRange.span / 1_000_000, .ulpOfOne)
        let nextSpan = min(fullRange.span, max(minimumSpan, span / cleanScale))
        let anchor = minimum + (span * cleanAnchor)
        let nextMinimum = anchor - (nextSpan * cleanAnchor)
        return HDFPlotRange(minimum: nextMinimum, maximum: nextMinimum + nextSpan)
            .clamped(to: fullRange)
    }

    func clamped(to fullRange: HDFPlotRange) -> HDFPlotRange {
        guard fullRange.span > 0 else {
            return fullRange
        }

        let currentSpan = min(max(span, .ulpOfOne), fullRange.span)
        let lowerBound = fullRange.minimum
        let upperBound = fullRange.maximum - currentSpan
        let nextMinimum = min(max(minimum, lowerBound), upperBound)
        return HDFPlotRange(minimum: nextMinimum, maximum: nextMinimum + currentSpan)
    }
}

private enum HDFPlotPalette {
    static func color(for ratio: Double) -> Color {
        Color(hue: 0.62 - (0.55 * ratio), saturation: 0.72, brightness: 0.92)
    }
}

private enum HDFPlotSeriesPalette {
    private static let colors: [Color] = [
        .accentColor,
        .green,
        .orange,
        .pink,
        .purple,
        .cyan
    ]

    static func color(at index: Int) -> Color {
        colors[index % colors.count]
    }
}

private enum HDFNumericValueFormatter {
    static func string(_ rawValue: String, precision: Int?) -> String {
        guard let precision,
              precision > 0,
              let value = Double(rawValue),
              value.isFinite else {
            return rawValue
        }

        return string(value, precision: precision)
    }

    static func string(_ value: Double, precision: Int? = nil) -> String {
        guard value.isFinite else {
            return String(describing: value)
        }

        let significantDigits = min(17, max(1, precision ?? 6))
        let absolute = abs(value)
        if precision == nil, absolute != 0, absolute < 0.001 || absolute >= 1_000_000 {
            return String(format: "%.*e", min(significantDigits, 6), value)
        }
        return String(format: "%.*g", significantDigits, value)
    }

    static func signedOffsetString(_ value: Double, precision: Int? = nil) -> String {
        let absoluteValue = abs(value)
        let prefix = value < 0 ? "-" : "+"
        return "\(prefix)\(string(absoluteValue, precision: precision))"
    }
}

private extension HDF5Object {
    var displayName: String {
        name.isEmpty ? "/" : name
    }
}

private extension HDF5ObjectKind {
    var symbolName: String {
        switch self {
        case .group:
            "folder"
        case .dataset:
            "tablecells"
        case .namedDatatype:
            "shippingbox"
        case .link:
            "link"
        case .unknown:
            "questionmark.diamond"
        }
    }
}

private extension HDF5LinkKind {
    var displayName: String {
        switch self {
        case .hard:
            "Hard"
        case .soft:
            "Soft"
        case .external:
            "External"
        case .userDefined:
            "User Defined"
        case .unknown:
            "Unknown"
        }
    }
}
