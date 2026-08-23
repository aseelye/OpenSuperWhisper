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
struct OpenSuperWhisperApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if !appState.hasCompletedOnboarding {
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
        _ = ShortcutManager.shared

        // Existing installs keep their completed-onboarding state. Once the
        // preference migration has selected Apple Speech, warm its locale
        // asset in the background so the first dictation is ready without
        // showing onboarding again. The manager owns reservations and is
        // idempotent for an already-installed locale.
        let preferences = AppPreferences.shared
        if preferences.hasCompletedOnboarding,
           preferences.transcriptionBackend == .appleSpeech {
            Task { @MainActor in
                _ = try? await AppleSpeechAssetManager.shared.prepare(locale: preferences.locale)
            }
        }
    }
}

class AppState: ObservableObject {
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            AppPreferences.shared.hasCompletedOnboarding = hasCompletedOnboarding
        }
    }

    init() {
        self.hasCompletedOnboarding = ProcessInfo.processInfo.arguments.contains(
            "--open-super-whisper-ui-test"
        ) || AppPreferences.shared.hasCompletedOnboarding
    }
}

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
            rootView: ContentView().environmentObject(AppState())
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
