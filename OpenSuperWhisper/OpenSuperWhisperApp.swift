//
//  OpenSuperWhisperApp.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import SwiftUI
import AppKit

@main
@MainActor
struct OpenSuperWhisperApp: App {
    @State private var startupOutcome: ForkIdentityMigrationOutcome
    @StateObject private var appState: AppState
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if let issue = startupOutcome.issue {
                    ForkIdentityStartupView(issue: issue, retry: retryStartup)
                } else if !appState.hasCompletedOnboarding {
                    OnboardingView()
                } else {
                    ContentView()
                }
            }
            .frame(width: 450, height: 650)
            .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 450, height: 650)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "openMainWindow"))
    }

    init() {
        // This must remain the first startup operation. AppState, the
        // preferences singleton, shortcuts, and recording stores are created
        // only after the identity migration has either completed or been
        // explicitly skipped for an isolated UI-test launch.
        let outcome = ForkIdentityMigrator().migrate()
        _startupOutcome = State(initialValue: outcome)
        _appState = StateObject(wrappedValue: AppState(startupOutcome: outcome))

        initializeRuntime(for: outcome)
    }

    private func initializeRuntime(for outcome: ForkIdentityMigrationOutcome) {
        guard outcome.canStartApplication else { return }

        _ = ShortcutManager.shared

        // Existing installs keep their completed-onboarding state. Once the
        // preference migration has selected Apple Speech, warm its locale
        // asset in the background so the first dictation is ready without
        // showing onboarding again. UI-test launches deliberately avoid the
        // production preferences domain as well as identity migration.
        guard case .success = outcome else { return }
        let preferences = AppPreferences.shared
        if preferences.hasCompletedOnboarding,
           preferences.transcriptionBackend == .appleSpeech {
            Task { @MainActor in
                _ = try? await AppleSpeechAssetManager.shared.prepare(locale: preferences.locale)
            }
        }
    }

    private func retryStartup() {
        let outcome = ForkIdentityMigrator().migrate()
        if outcome.canStartApplication {
            appState.activateAfterStartup(outcome)
            initializeRuntime(for: outcome)
        }
        startupOutcome = outcome
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            guard startupIsReady else { return }
            AppPreferences.shared.hasCompletedOnboarding = hasCompletedOnboarding
        }
    }

    private var startupIsReady: Bool

    convenience init() {
        self.init(startupOutcome: .success(ForkIdentityMigrationReport()))
    }

    init(startupOutcome: ForkIdentityMigrationOutcome) {
        self.startupIsReady = startupOutcome.canStartApplication
        if startupOutcome.canStartApplication {
            self.hasCompletedOnboarding = ProcessInfo.processInfo.arguments.contains(
                ForkIdentityMigrator.uiTestLaunchArgument
            ) || AppPreferences.shared.hasCompletedOnboarding
        } else {
            // A blocked launch must not read or create the production
            // preferences singleton. This inert state exists only so the App
            // can present the recovery screen while the user retries.
            self.hasCompletedOnboarding = false
        }
    }

    func activateAfterStartup(_ outcome: ForkIdentityMigrationOutcome) {
        guard outcome.canStartApplication, !startupIsReady else { return }
        startupIsReady = true
        hasCompletedOnboarding = ProcessInfo.processInfo.arguments.contains(
            ForkIdentityMigrator.uiTestLaunchArgument
        ) || AppPreferences.shared.hasCompletedOnboarding
    }
}

/// Minimal recovery surface for an identity conflict or filesystem failure.
/// No normal app view is composed while this screen is visible.
@MainActor
private struct ForkIdentityStartupView: View {
    let issue: ForkIdentityMigrationIssue
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: issue.isConflict ? "externaldrive.badge.exclamationmark" : "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(issue.isConflict ? "Resolve OpenSuperWhisper storage" : "OpenSuperWhisper needs attention")
                .font(.headline)
            Text(issue.message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            HStack(spacing: 10) {
                Button("Retry", action: retry)
                    .keyboardShortcut(.defaultAction)
                Button("Reveal folders") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        issue.legacyDirectory,
                        issue.currentDirectory
                    ])
                }
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(28)
        .frame(width: 450, height: 300)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusItem: NSStatusItem?
    private var uiTestWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBarItem()
        bindWindowDelegates()
        DispatchQueue.main.async {
            if ProcessInfo.processInfo.arguments.contains("--open-super-whisper-ui-test") {
                self.showMainWindow()
            }
        }
    }
    
    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            if let iconImage = NSImage(named: "tray_icon") {
                iconImage.size = NSSize(width: 48, height: 48)
                iconImage.isTemplate = true
                button.image = iconImage
            } else {
                button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "OpenSuperWhisper")
            }
            
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
        }
        
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "OpenSuperWhisper", action: #selector(openApp), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc private func statusBarButtonClicked(_ sender: Any) {
        statusItem?.button?.performClick(nil)
    }
    
    @objc private func openApp() {
        showMainWindow()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    func showMainWindow() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)

        // WindowGroup creation is asynchronous for this menu-bar app. In
        // UI-test mode, always own a concrete window so the test target has
        // an accessible surface even when the scene has not materialized (or
        // has restored an invisible window) yet.
        if ProcessInfo.processInfo.arguments.contains("--open-super-whisper-ui-test") {
            showUITestWindow(application: application)
            return
        }

        if let window = currentMainWindow() {
            window.delegate = self
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            window.orderFrontRegardless()
            application.activate(ignoringOtherApps: true)
        } else {
            let url = URL(string: "openSuperWhisper://openMainWindow")!
            NSWorkspace.shared.open(url)
        }
    }

    private func showUITestWindow(application: NSApplication) {
        if let window = uiTestWindow {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            application.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: ContentView().environmentObject(
                AppState(startupOutcome: .skippedForUITest)
            )
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "OpenSuperWhisper"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 450, height: 650))
        window.isRestorable = false
        window.center()
        window.delegate = self
        uiTestWindow = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        application.activate(ignoringOtherApps: true)
    }

    /// WindowGroup may close and recreate its window. Resolve the current
    /// eligible window at action time instead of retaining the launch-time
    /// `windows.first` pointer.
    private func currentMainWindow() -> NSWindow? {
        let windows = NSApplication.shared.windows
        return windows.first(where: {
            !$0.isMiniaturized && $0.isVisible && !($0 is NSPanel)
        }) ?? windows.first(where: { !($0 is NSPanel) && $0.contentView != nil })
    }

    private func bindWindowDelegates() {
        NSApplication.shared.windows
            .filter { !($0 is NSPanel) }
            .forEach { $0.delegate = self }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
