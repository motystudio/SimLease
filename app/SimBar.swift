// SimBar — menu bar companion for ~/.claude/bin/sim-lease.
// Shows booted iOS simulators / Android emulators, which Claude session holds each one,
// jumps to that session, shuts devices down, and runs `sim-lease reap` every 5 minutes.
//
// SimBar.swift: the app, its windows and the debug snapshots. Model.swift: devices, the script
// runner, the Store. Setup.swift: what gets installed into ~/.claude, requirements.
// Config.swift: sim-lease's settings. Updater.swift: Sparkle. Panel.swift, SettingsView.swift,
// Onboarding.swift: the views.

import SwiftUI
import AppKit

@main
struct SimBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = Store.shared
    /// Created with the app so Sparkle can schedule its checks from launch.
    private let updater = Updater.shared

    var body: some Scene {
        MenuBarExtra {
            Panel().environmentObject(store)
        } label: {
            Image(nsImage: menuBarIcon(count: store.devices.count))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            SimLeaseConfig.shared.load()   // ready by the time Settings opens
            if let path = argument("--snapshot") {
                Snapshot.render(argument("--view") ?? "panel", to: path)
            } else if !UserDefaults.standard.bool(forKey: Defaults.onboardingDone) {
                Windows.shared.showOnboarding()
            }
        }
    }

    /// Opening the app again (Spotlight, Finder, `open`) shows the panel in a normal window,
    /// for when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { Windows.shared.showPanel() }
        return false
    }
}

/// SimBar's windows besides the menu bar panel: the panel itself (when the icon is hidden),
/// Settings and the setup assistant. Each is created once and brought back to the front.
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    static let shared = Windows()
    private var panel: NSWindow?
    private var settings: NSWindow?
    private var onboarding: NSWindow?

    func showPanel() {
        show(&panel) {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Panel().environmentObject(Store.shared)))
            w.title = "SimBar"
            w.styleMask = [.titled, .closable, .miniaturizable]
            return w
        }
    }

    func showSettings() {
        show(&settings) {
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = .preferredContentSize   // grows when sim-lease's settings load
            let w = NSWindow(contentViewController: host)
            w.title = L("SimBar Settings", "Réglages de SimBar")
            w.styleMask = [.titled, .closable, .miniaturizable]
            return w
        }
        SimLeaseConfig.shared.load()
    }

    func showOnboarding() {
        show(&onboarding) {
            let w = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView()))
            w.title = L("Welcome to SimBar", "Bienvenue dans SimBar")
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            return w
        }
    }

    func closeOnboarding() { onboarding?.close() }

    private func show(_ window: inout NSWindow?, make: () -> NSWindow) {
        if window == nil {
            let w = make()
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// The assistant counts as seen once it is closed, finished or not: it doesn't come back
    /// at every launch, and stays one click away in the gear menu, where it starts over.
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === onboarding {
            UserDefaults.standard.set(true, forKey: Defaults.onboardingDone)
            DispatchQueue.main.async { self.onboarding = nil }
        }
    }
}

/// Icon + count drawn as one tight template image (an Image + Text label gets extra spacing).
func menuBarIcon(count: Int) -> NSImage {
    let symbol = NSImage(systemSymbolName: "iphone", accessibilityDescription: L("Simulators", "Simulateurs"))!
        .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))!
    let text = count > 0 ? NSAttributedString(string: "\(count)", attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.black,
    ]) : nil
    let gap: CGFloat = text == nil ? 0 : 2
    let textSize = text?.size() ?? .zero
    let size = NSSize(width: ceil(symbol.size.width + gap + textSize.width), height: max(symbol.size.height, textSize.height))
    let image = NSImage(size: size, flipped: false) { _ in
        symbol.draw(in: NSRect(x: 0, y: (size.height - symbol.size.height) / 2,
                               width: symbol.size.width, height: symbol.size.height))
        text?.draw(at: NSPoint(x: symbol.size.width + gap, y: (size.height - textSize.height) / 2))
        return true
    }
    image.isTemplate = true
    return image
}

/// Debug: `SimBar --snapshot out.png [--view NAME]` renders a view with live data and exits.
/// NAME: `panel` (default), `settings`, or `onboarding-1` … `onboarding-5` (one per step).
/// Views are drawn in an off-screen window, so AppKit controls render as they do on screen.
@MainActor
enum Snapshot {
    static func render(_ name: String, to path: String) {
        let view: AnyView
        switch name {
        case "settings":
            view = AnyView(SettingsView())
        case let s where s.hasPrefix("onboarding"):
            let step = Int(s.split(separator: "-").last ?? "") ?? 1
            view = AnyView(OnboardingView(start: OnboardingView.Step(rawValue: step - 1) ?? .welcome))
        default:
            Store.shared.loadSessions()
            view = AnyView(Panel().environmentObject(Store.shared))
        }
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))   // off screen
        window.orderFront(nil)
        // live data (sim-lease json, config, requirements) arrives within a few seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }
}
