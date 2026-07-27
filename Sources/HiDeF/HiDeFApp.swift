// SPDX-FileCopyrightText: 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct HiDeFApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(DemoHDFDocumentBrowserInstaller.self) private var demoDocumentBrowserInstaller
    #endif

    var body: some Scene {
        DocumentGroup(viewing: HDFDocument.self) { configuration in
            HDFDocumentSceneView(fileURL: configuration.fileURL)
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 780)
        .commands {
            HDFMacDocumentCommands()
        }
        #endif
        #if os(iOS)
        .commands {
            HDFDocumentWindowCommands()
        }
        #endif

        #if os(iOS)
        DocumentGroupLaunchScene("HighDeF") {
            DefaultDocumentGroupLaunchActions()
            DemoHDFDocumentButton()
        }
        #endif
    }
}

#if os(iOS)
private struct HDFDocumentWindowCommands: Commands {
    var body: some Commands {
        // ⌘N opens a new window. iPad shows it as a separate window (Split View / Stage
        // Manager) on the document browser, so a second file can be viewed side by side.
        // iPhone shows one window at a time, so there it just brings up the browser.
        CommandGroup(after: .newItem) {
            Button("New Window") {
                UIApplication.shared.requestSceneSessionActivation(
                    nil,
                    userActivity: nil,
                    options: nil,
                    errorHandler: nil
                )
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}
#endif

private enum DemoHDFDocument {
    static var bundledURL: URL? {
        Bundle.main.url(forResource: "demo", withExtension: "h5")
    }

    static func localDocumentURL() throws -> URL {
        guard let bundledURL else {
            throw CocoaError(.fileNoSuchFile)
        }

        let documentsURL = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let destinationURL = documentsURL.appendingPathComponent("HighDeF Demo.h5")

        // (Re)install when the local copy is missing or stale — e.g. after an app update
        // ships a newer demo — so iOS opens the same demo file macOS does.
        if shouldRefreshDemo(bundled: bundledURL, installed: destinationURL) {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: bundledURL, to: destinationURL)
        }
        return destinationURL
    }

    private static func shouldRefreshDemo(bundled: URL, installed: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: installed.path) else {
            return true
        }
        let bundledAttributes = try? fileManager.attributesOfItem(atPath: bundled.path)
        let installedAttributes = try? fileManager.attributesOfItem(atPath: installed.path)
        let bundledSize = (bundledAttributes?[.size] as? NSNumber)?.int64Value
        let installedSize = (installedAttributes?[.size] as? NSNumber)?.int64Value
        if bundledSize != installedSize {
            return true
        }
        let bundledDate = bundledAttributes?[.modificationDate] as? Date
        let installedDate = installedAttributes?[.modificationDate] as? Date
        if let bundledDate, let installedDate, bundledDate > installedDate {
            return true
        }
        return false
    }
}

#if os(macOS)
import AppKit

private enum HDFAppBrand {
    static let name = "HighDeF"
    static let maker = "Twarge LLC"
    static let contactEmail = "hello@twarge.com"
    static let contactURL = URL(string: "mailto:hello@twarge.com")!
}

private struct HDFMacDocumentCommands: Commands {
    @Environment(\.openDocument) private var openDocument

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(HDFAppBrand.name)") {
                HDFAboutPanel.show()
            }
        }

        CommandGroup(after: .newItem) {
            Button("Open Demo File") {
                openDemoFile()
            }
        }
    }

    private func openDemoFile() {
        guard let url = DemoHDFDocument.bundledURL else {
            HDFAboutPanel.showError("The bundled demo file is missing.")
            return
        }

        Task {
            do {
                try await openDocument(at: url)
            } catch {
                HDFAboutPanel.showError(error.localizedDescription)
            }
        }
    }
}

@MainActor
private enum HDFAboutPanel {
    static func show() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: HDFAppBrand.name,
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
            .credits: licenseCredits()
        ])
    }

    static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could Not Open Demo File"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func licenseCredits() -> NSAttributedString {
        let text = """
        \(HDFAppBrand.name) is made by \(HDFAppBrand.maker).
        \(HDFAppBrand.contactEmail)
        Licensed under the Apache License 2.0.

        \(bundledLicenseText())
        """
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 5
        paragraphStyle.lineSpacing = 1

        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]
        )

        let emailRange = (text as NSString).range(of: HDFAppBrand.contactEmail)
        if emailRange.location != NSNotFound {
            attributed.addAttributes([
                .link: HDFAppBrand.contactURL,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: emailRange)
        }
        return attributed
    }

    private static func bundledLicenseText() -> String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyLicenses", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return """
            \(HDFAppBrand.name) Third-Party Licenses

            HDF5 is distributed under the 3-clause BSD License.
            The bundled ThirdPartyLicenses.txt resource could not be loaded.
            """
        }
        return text
    }
}
#endif

#if os(iOS)
private struct DemoHDFDocumentButton: View {
    @State private var errorMessage: String?

    var body: some View {
        Button {
            DemoHDFDocumentOpener.openDemoDocument { result in
                if case .failure(let error) = result {
                    errorMessage = error.localizedDescription
                }
            }
        } label: {
            Label("Open Demo Document", systemImage: "doc.text.magnifyingglass")
        }
        .alert("Could Not Open Demo Document", isPresented: showsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "The bundled demo file could not be opened.")
        }
    }

    private var showsError: Binding<Bool> {
        Binding {
            errorMessage != nil
        } set: { isPresented in
            if !isPresented {
                errorMessage = nil
            }
        }
    }
}

@MainActor
private final class DemoHDFDocumentBrowserInstaller: NSObject, UIApplicationDelegate {
    private static let demoButtonTag = 0xA11DF5

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        DemoHDFDocumentOpener.installDemoDocument()
        guard #unavailable(iOS 18.0) else { return true }
        scheduleInstall()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        DemoHDFDocumentOpener.installDemoDocument()
        guard #unavailable(iOS 18.0) else { return }
        scheduleInstall()
    }

    private func scheduleInstall() {
        for delay in [0.0, 0.2, 0.6, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.installDemoButtons()
            }
        }
    }

    private static func installDemoButtons() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for window in scenes.flatMap(\.windows) {
            for browser in DemoHDFDocumentOpener.documentBrowsers(in: window.rootViewController) {
                installDemoButton(in: browser)
            }
        }
    }

    private static func installDemoButton(in browser: UIDocumentBrowserViewController) {
        guard !browser.additionalTrailingNavigationBarButtonItems.contains(where: { $0.tag == demoButtonTag }) else {
            return
        }

        let action = UIAction(
            title: "Open Demo Document",
            image: UIImage(systemName: "doc.text.magnifyingglass")
        ) { [weak browser] _ in
            guard let browser else { return }
            DemoHDFDocumentOpener.openDemoDocument(from: browser)
        }

        let button = UIBarButtonItem(primaryAction: action)
        button.tag = demoButtonTag
        button.title = "Demo"
        button.accessibilityLabel = "Open Demo Document"

        browser.additionalTrailingNavigationBarButtonItems =
            browser.additionalTrailingNavigationBarButtonItems + [button]
    }
}

@MainActor
private enum DemoHDFDocumentOpener {
    static func installDemoDocument() {
        // Called only for its side effect (copying the bundled demo into Documents).
        _ = try? DemoHDFDocument.localDocumentURL()
    }

    static func openDemoDocument(
        from browser: UIDocumentBrowserViewController? = nil,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        do {
            let sourceURL = try DemoHDFDocument.localDocumentURL()
            if let browser = browser ?? documentBrowsers().first {
                browser.revealDocument(at: sourceURL, importIfNeeded: false) { revealedURL, error in
                    if let error {
                        completion?(.failure(error))
                        return
                    }
                    openDocument(at: revealedURL ?? sourceURL, from: browser, completion: completion)
                }
            } else {
                openURL(sourceURL, completion: completion)
            }
        } catch {
            completion?(.failure(error))
        }
    }

    private static func openDocument(
        at url: URL,
        from browser: UIDocumentBrowserViewController,
        completion: ((Result<Void, Error>) -> Void)?
    ) {
        let selector = #selector(UIDocumentBrowserViewControllerDelegate.documentBrowser(_:didPickDocumentsAt:))
        if let delegate = browser.delegate, delegate.responds(to: selector) {
            delegate.documentBrowser?(browser, didPickDocumentsAt: [url])
            completion?(.success(()))
        } else {
            openURL(url, completion: completion)
        }
    }

    private static func openURL(_ url: URL, completion: ((Result<Void, Error>) -> Void)?) {
        UIApplication.shared.open(url, options: [:]) { didOpen in
            if didOpen {
                completion?(.success(()))
            } else {
                completion?(.failure(CocoaError(.fileReadUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "iOS could not open \(url.lastPathComponent) as a HighDeF document."
                ])))
            }
        }
    }

    private static func documentBrowsers() -> [UIDocumentBrowserViewController] {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes
            .flatMap(\.windows)
            .flatMap { documentBrowsers(in: $0.rootViewController) }
    }

    static func documentBrowsers(in rootViewController: UIViewController?) -> [UIDocumentBrowserViewController] {
        guard let rootViewController else { return [] }

        var browsers: [UIDocumentBrowserViewController] = []
        if let browser = rootViewController as? UIDocumentBrowserViewController {
            browsers.append(browser)
        }

        for child in rootViewController.children {
            browsers.append(contentsOf: documentBrowsers(in: child))
        }

        if let navigationController = rootViewController as? UINavigationController {
            for viewController in navigationController.viewControllers {
                browsers.append(contentsOf: documentBrowsers(in: viewController))
            }
        }

        if let tabBarController = rootViewController as? UITabBarController {
            for viewController in tabBarController.viewControllers ?? [] {
                browsers.append(contentsOf: documentBrowsers(in: viewController))
            }
        }

        if let presentedViewController = rootViewController.presentedViewController {
            browsers.append(contentsOf: documentBrowsers(in: presentedViewController))
        }

        return browsers
    }
}
#endif
