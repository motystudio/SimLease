// SimBar — the panel: booted devices, their sessions, and the gear menu.

import SwiftUI
import AppKit

// MARK: - Views

struct DeviceRow: View {
    @EnvironmentObject var store: Store
    let device: Device
    @State private var confirmKill = false

    var body: some View {
        let session = store.session(for: device)
        HStack(spacing: 6) {
            // device icon: shows the simulator
            Image(systemName: device.isIOS ? "iphone" : "smartphone")
                .font(.system(size: 18))
                .foregroundStyle(device.live ? Color.blue : .secondary)
                .frame(width: 30, height: 40)
                .accessibilityLabel(L("Show the simulator", "Afficher le simulateur"))
                .hoverTarget(help: L("Show the simulator", "Afficher le simulateur")) { store.show(device) }
            // name + status: opens the session using it, if any
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name.isEmpty ? device.id : device.name).font(.system(size: 13, weight: .medium))
                status(session).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .hoverTarget(enabled: session != nil,
                         help: session.map { L("Open session “\($0.title)”", "Ouvrir la session « \($0.title) »") } ?? "") {
                if let s = session { store.open(s) }
            }
            Spacer(minLength: 4)
            usageView
            controls
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .contextMenu {
            Button(L("Copy identifier", "Copier l'identifiant")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(device.id, forType: .string)
            }
        }
    }

    /// Pin + power, in a fixed-size box: the spinner and the confirmation take exactly
    /// their place, so nothing on the left moves.
    var controls: some View {
        let pinned = store.isPinned(device)
        return ZStack {
            HStack(spacing: 6) {
                iconButton(pinned ? "pin.fill" : "pin",
                           help: pinned ? L("Stop keeping alive", "Ne plus garder allumé") : L("Keep alive: never shut down automatically", "Garder allumé : jamais éteint automatiquement"),
                           tint: pinned ? .accentColor : nil) { store.togglePin(device) }
                    .offset(y: 1)   // the pin glyph sits high; lines it up with the power icon
                iconButton(confirmKill ? "power.circle.fill" : "power",
                           help: confirmKill ? L("Click again to shut down", "Cliquer encore pour éteindre") : L("Shut down", "Éteindre"),
                           tint: confirmKill ? .red : nil) {
                    if confirmKill || !(device.live || pinned) {
                        confirmKill = false
                        store.kill(device)
                    } else {
                        confirmKill = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmKill = false }
                    }
                }
            }
            .opacity(store.busy.contains(device.id) ? 0 : 1)
            .allowsHitTesting(!store.busy.contains(device.id))
            if store.busy.contains(device.id) { ProgressView().controlSize(.small) }
        }
        .frame(width: 50, height: 22)
    }

    @ViewBuilder func status(_ s: DesktopSession?) -> some View {
        if device.live {
            let mins = max(0, (Int(Date().timeIntervalSince1970) - device.lastActive) / 60)
            Text(s?.title ?? "Session \(device.session.prefix(8))").foregroundColor(.blue)
                + Text(mins > 1 ? L(" · active \(mins) min ago", " · actif il y a \(mins) min") : "")
        } else if store.isPinned(device) {
            Text(L("Kept alive", "Gardé allumé"))
        } else if device.isUnmanaged {
            Text(L("Unmanaged", "Hors sim-lease") + (device.shutdownInMin >= 0 ? L(" · shuts down in \(device.shutdownInMin) min", " · s'éteint dans \(device.shutdownInMin) min") : ""))
        } else {
            Text(L("Free · shuts down in \(max(0, device.shutdownInMin)) min", "Libre · s'éteint dans \(max(0, device.shutdownInMin)) min"))
        }
    }

    /// RAM and CPU of the whole simulator (all its processes).
    @ViewBuilder var usageView: some View {
        if let u = store.usage[device.usageKey] {
            VStack(alignment: .trailing, spacing: 1) {
                Text(formatMemory(u.memory))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(u.memory >= 4 << 30 ? Color.orange : .primary)
                Text(u.cpu.map { String(format: "%.0f %% CPU", $0) } ?? "— CPU")
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle((u.cpu ?? 0) >= 50 ? Color.orange : .secondary)
            }
            .frame(width: 62, alignment: .trailing)
            .help(L("Memory and CPU used by this simulator (all its processes)", "Mémoire et processeur utilisés par ce simulateur (tous ses processus)"))
        }
    }

    func iconButton(_ name: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 13)).frame(width: 22, height: 22)
                .foregroundStyle(tint ?? .primary)
        }
        .buttonStyle(.borderless).help(help).accessibilityLabel(help)
    }
}

/// A clickable part of a row that highlights on its own when hovered. A real button, so
/// VoiceOver and keyboard navigation can trigger it too.
struct HoverTarget: ViewModifier {
    let enabled: Bool
    let help: String
    let action: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            Button(action: action) { content }
                .buttonStyle(HoverButtonStyle())
                .help(help)
        } else {
            content
        }
    }
}

struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Highlight(configuration: configuration) }

    struct Highlight: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            configuration.label
                .background(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0)))
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}

extension View {
    func hoverTarget(enabled: Bool = true, help: String, action: @escaping () -> Void) -> some View {
        modifier(HoverTarget(enabled: enabled, help: help, action: action))
    }
}

struct PillButtonStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.3 : 0.16)))
            .contentShape(Capsule())
    }
}

struct Panel: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Simulators", "Simulateurs")).font(.headline)
                Spacer()
                if store.loading { ProgressView().controlSize(.mini) }
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless).help(L("Refresh", "Rafraîchir")).accessibilityLabel(L("Refresh", "Rafraîchir"))
                settingsMenu
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            if store.devices.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 24)).foregroundStyle(.green)
                    Text(L("No simulator running", "Aucun simulateur démarré")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                section("iOS", store.devices.filter(\.isIOS))
                section("Android", store.devices.filter { !$0.isIOS })
                actionBar.padding(10)
            }
        }
        .frame(width: 460)
        .background {
            // ⌘, while the panel is open, without opening the gear menu first
            Button("") { Windows.shared.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .onAppear { store.refresh(); store.loadSessions() }
    }

    var settingsMenu: some View {
        Menu {
            Toggle(L("Auto cleanup every 5 min", "Nettoyage auto toutes les 5 min"), isOn: $store.autoReap)
            Toggle(L("Launch at login", "Lancer à l'ouverture de session"), isOn: Binding(
                get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
            // only what still needs installing; the whole section disappears once everything is set up
            let todo = SetupItem.allCases.filter { !(store.setupStates[$0] ?? .ok).isInstalled }
            if !todo.isEmpty {
                Divider()
                Section(L("Setup", "Installation")) {
                    ForEach(todo, id: \.self) { item in
                        switch store.setupStates[item] {
                        case .outdated:
                            Button { store.install([item]) } label: {
                                Label(L("Update \(item.title)", "Mettre à jour : \(item.title)"), systemImage: "arrow.triangle.2.circlepath")
                            }
                        case .malformed:
                            // never fixed silently: asks first
                            Button { store.confirmReplaceRule() } label: {
                                Label(L("Fix \(item.title)…", "Réparer : \(item.title)…"), systemImage: "exclamationmark.triangle.fill")
                            }
                        default:
                            Button { store.install([item]) } label: {
                                Label(L("Install \(item.title)", "Installer : \(item.title)"), systemImage: "exclamationmark.triangle.fill")
                            }
                        }
                    }
                    let silent = todo.filter { store.setupStates[$0]?.installsSilently == true }
                    if silent.count > 1 {
                        Button(L("Install everything", "Tout installer")) { store.install(silent) }
                    }
                }
            }
            Divider()
            Button(L("Settings…", "Réglages…")) { Windows.shared.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Button(L("Setup Assistant…", "Assistant de configuration…")) { Windows.shared.showOnboarding() }
            if updater.isAvailable {
                Button(updater.updateAvailable ? L("Update Available…", "Mise à jour disponible…")
                                               : L("Check for Updates…", "Rechercher les mises à jour…")) {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
            Button(L("Open Log", "Ouvrir le journal")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "\(home)/.claude/sim-leases/sim-lease.log"))
            }
            Divider()
            Button(L("Quit SimBar", "Quitter SimBar")) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape").frame(width: 22, height: 22)
                .overlay(alignment: .topTrailing) {
                    // something from Setup still needs installing, or an update is waiting
                    if store.setupIncomplete || updater.updateAvailable {
                        Circle().fill(Color.orange).frame(width: 7, height: 7).offset(x: -1, y: 2)
                    }
                }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("Settings", "Réglages")).accessibilityLabel(L("Settings", "Réglages"))
    }

    /// Summary of what is idle, with the bulk shutdown actions.
    var actionBar: some View {
        let idleDevices = store.devices.filter { !$0.live && !store.isPinned($0) }
        let idle = idleDevices.count
        let used = store.devices.filter(\.live).count
        let idleMemory = idleDevices.reduce(UInt64(0)) { $0 + (store.usage[$1.usageKey]?.memory ?? 0) }
        return HStack(spacing: 10) {
            Image(systemName: idle > 0 ? "moon.zzz.fill" : "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(idle > 0 ? Color.orange : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(idle > 0 ? plural(idle, L("idle device", "appareil inactif"), L("idle devices", "appareils inactifs")) : L("Everything is in use", "Tout est utilisé"))
                    .font(.system(size: 12, weight: .semibold))
                Text(idle > 0 && idleMemory > 0 ? L("\(formatMemory(idleMemory)) of RAM to reclaim", "\(formatMemory(idleMemory)) de RAM à récupérer")
                     : used > 0 ? L("\(used) used by a session", "\(plural(used, "utilisé", "utilisés")) par une session") : L("No session is using them", "Aucune session ne les utilise"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if idle > 0 {
                Button { store.killIdle() } label: {
                    Label(L("Shut down", "Éteindre"), systemImage: "power").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PillButtonStyle(tint: .orange))
                .help(L("Shut down devices no session is using", "Éteindre les appareils qu'aucune session n'utilise"))
            }
            Menu {
                Button(role: .destructive) { store.killAll() } label: {
                    Label(L("Shut down all, even in use (\(store.devices.count))", "Tout éteindre, même ceux utilisés (\(store.devices.count))"), systemImage: "power")
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("More", "Plus")).accessibilityLabel(L("More", "Plus"))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n > 1 ? many : one)" }

    @ViewBuilder func section(_ title: String, _ list: [Device]) -> some View {
        if !list.isEmpty {
            let memory = list.reduce(UInt64(0)) { $0 + (store.usage[$1.usageKey]?.memory ?? 0) }
            Text("\(title) · \(list.count)" + (memory > 0 ? L(" · \(formatMemory(memory)) total", " · \(formatMemory(memory)) au total") : ""))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 6)
            ForEach(list) { DeviceRow(device: $0) }
        }
    }
}

