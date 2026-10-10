// Which Claude — pick a Claude profile and open it as its own Claude.app instance.
// Build with Xcode (WhichClaude.xcodeproj). App Sandbox must stay off: it blocks launch arguments.

import SwiftUI
import AppKit
import Combine
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Theme

enum Theme {
    static let bg = Color(hex: "18150F")
    static let line = Color(hex: "3A322A")
    static let divider = Color(hex: "2C251F")
    static let card = Color(hex: "1C1813")
    static let field = Color(hex: "1F1A15")
    static let rowSelected = Color(hex: "2B241D")
    static let rowSelectedBorder = Color(hex: "4A3E33")
    static let text = Color(hex: "F1ECE4")
    static let secondary = Color(hex: "CFC6BB")
    static let muted = Color(hex: "A69B8F")
    static let ok = Color(hex: "8FC98A")
    static let warn = Color(hex: "E8A15A")

    /// Accent colors offered for profiles.
    static let swatches = ["C9714A", "E2A53A", "5FA89A", "7F8FD6", "B77FC4", "8FAF5A"]

    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        let f = Font.system(size: size, weight: .medium, design: .serif)
        return italic ? f.italic() : f
    }

    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }

    static func label() -> Font {
        .system(size: 11, weight: .semibold)
    }
}

extension Color {
    init(hex: String) {
        let (r, g, b) = rgb(hex)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

private func rgb(_ hex: String) -> (Double, Double, Double) {
    let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    var v: UInt64 = 0
    Scanner(string: s).scanHexInt64(&v)
    return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
}

/// True when dark text reads better than light text on this color.
private func isLight(_ hex: String) -> Bool {
    let (r, g, b) = rgb(hex)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.5
}

// MARK: - Model

struct Profile: Identifiable, Codable {
    var id = UUID()
    var name: String
    var blurb: String
    /// Folder in ~/Library/Application Support holding this account's login. Empty = Claude's default.
    var dataFolder: String
    var colorHex: String
    var lastOpened: Date? = nil

    var color: Color { Color(hex: colorHex) }
    var foreground: Color { isLight(colorHex) ? Color(hex: "2A1C06") : Color(hex: "FFF4EC") }

    var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }
        let s = String(letters).uppercased()
        return s.isEmpty ? "?" : s
    }
}

final class ProfileStore: ObservableObject {
    @Published var profiles: [Profile] {
        didSet { save(); refreshRunning() }
    }

    /// Profiles whose Claude instance is currently running.
    @Published private(set) var running: Set<UUID> = []

    private let key = "profiles.v2"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Profile].self, from: data),
           !saved.isEmpty {
            profiles = saved
        } else {
            profiles = [
                Profile(name: "Personal", blurb: "Your everyday Claude account",
                        dataFolder: "", colorHex: "C9714A"),
                Profile(name: "Work", blurb: "A second account with its own login",
                        dataFolder: "Claude-Work", colorHex: "E2A53A"),
            ]
        }
        refreshRunning()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Launcher.bundleID else { return }
                MainActor.assumeIsolated { self?.refreshRunning() }
            }
        }
    }

    func refreshRunning() {
        let commands = Launcher.instances().map(\.command)
        running = Set(profiles.filter { p in
            commands.contains { Launcher.isProfile(p.dataFolder, command: $0) }
        }.map(\.id))
    }

    /// Opens the profile's Claude, or focuses it if already running.
    @discardableResult
    func launch(_ profile: Profile) async -> Launcher.Result {
        let result = await Launcher.open(profile.dataFolder)
        if case .failed = result { return result }
        markOpened(profile.id)
        return result
    }

    /// Opens every profile that isn't running yet.
    func openAll() async {
        refreshRunning()
        for p in profiles where !running.contains(p.id) {
            await launch(p)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func contains(_ id: UUID) -> Bool { profiles.contains { $0.id == id } }

    func upsert(_ profile: Profile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
        }
    }

    func delete(_ id: UUID) { profiles.removeAll { $0.id == id } }

    private func markOpened(_ id: UUID) {
        if let i = profiles.firstIndex(where: { $0.id == id }) {
            profiles[i].lastOpened = Date()
        }
    }
}

// MARK: - Launching

enum Launcher {
    static let bundleID = "com.anthropic.claudefordesktop"

    /// `--user-data-dir=…` for a data folder, or nil for Claude's default folder.
    static func dataDirArg(_ folder: String) -> String? {
        guard !folder.isEmpty else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(folder)
        return "--user-data-dir=\(url.path)"
    }

    /// Running Claude processes with their full command lines (which carry `--user-data-dir`).
    /// Also sees instances started outside this app (e.g. the `claude-ss` alias).
    static func instances() -> [(app: NSRunningApplication, command: String)] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        guard !apps.isEmpty else { return [] }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-ww", "-o", "pid=,command=", "-p", apps.map { "\($0.processIdentifier)" }.joined(separator: ",")]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return [] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()

        return out.split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = pid_t(parts[0]),
                  let app = apps.first(where: { $0.processIdentifier == pid }) else { return nil }
            return (app, String(parts[1]))
        }
    }

    /// True when a Claude command line belongs to the profile with this data folder.
    static func isProfile(_ folder: String, command: String) -> Bool {
        guard let arg = dataDirArg(folder) else { return !command.contains("--user-data-dir") }
        return command.hasSuffix(arg) || command.contains(arg + " ")
    }

    static func running(_ folder: String) -> NSRunningApplication? {
        instances().first { isProfile(folder, command: $0.command) }?.app
    }

    /// Quits every Claude instance, same as ⌘Q in each.
    static func quitAll() {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
    }

    enum Result { case opened, focused, failed(String) }

    /// Focuses the profile's Claude if it's running, otherwise starts a new instance for it.
    static func open(_ folder: String) async -> Result {
        // macOS only lets the active app hand focus to another. From a global hotkey we're
        // in the background, so take focus first, then pass it on.
        NSApp.activate()
        if let app = running(folder) {
            app.activate()
            return .focused
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return .failed("Claude.app isn't installed.")
        }
        let config = NSWorkspace.OpenConfiguration()
        // Without this, macOS just focuses whichever Claude is already open (maybe the wrong account).
        config.createsNewApplicationInstance = true
        config.arguments = dataDirArg(folder).map { [$0] } ?? []
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            return .opened
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ProfileStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeys.register { [store] index in
            guard index < store.profiles.count else { return }
            Task { await store.launch(store.profiles[index]) }
        }
        if UserDefaults.standard.bool(forKey: "openAllOnLaunch") {
            Task { await store.openAll() }
        }
    }

    // Keeps running in the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// System-wide ⌃⌥1–9, so switching works from any app. Carbon hot keys need no Accessibility permission.
enum HotKeys {
    private static var onPress: (Int) -> Void = { _ in }

    static func register(_ handler: @escaping (Int) -> Void) {
        onPress = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            MainActor.assumeIsolated { HotKeys.onPress(Int(id.id)) }
            return noErr
        }, 1, &spec, nil, nil)

        let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                    kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, key) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5743_4C44), id: UInt32(index)) // 'WCLD'
            RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey), id, GetEventDispatcherTarget(), 0, &ref)
        }
    }
}

@main
struct WhichClaudeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Which Claude", id: "main") {
            ContentView()
                .environmentObject(delegate.store)
                .frame(minWidth: 860, minHeight: 560)
                .preferredColorScheme(.dark)
                .containerBackground(Theme.bg, for: .window)
        }
        .defaultSize(width: 1000, height: 680)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            // Frees ⌘N for "New profile" instead of "New Window".
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("Which Claude", systemImage: "sparkle") {
            MenuContent().environmentObject(delegate.store)
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("openAllOnLaunch") private var openAllOnLaunch = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        ForEach(Array(store.profiles.enumerated()), id: \.element.id) { index, profile in
            // Checkmark = running. (Menu bar menus drop SF Symbol icons, so no dot here.)
            Toggle(profile.name, isOn: Binding(get: { store.running.contains(profile.id) },
                                               set: { _ in Task { await store.launch(profile) } }))
            .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.control, .option]) : nil)
        }
        Divider()
        Button("Open All") { Task { await store.openAll() } }
        Button("Quit All Claudes") { Launcher.quitAll() }
        Divider()
        Button("Show Which Claude…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Toggle("Launch at Login", isOn: Binding(get: { launchAtLogin }, set: { on in
            if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }))
        Toggle("Open All on Launch", isOn: $openAllOnLaunch)
        Divider()
        Button("Quit Which Claude") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject private var store: ProfileStore
    @State private var selectedID: UUID?
    @State private var editing: Profile?
    @State private var status = (ok: true, text: "Ready")
    @AppStorage("closeAfterOpening") private var closeAfterOpening = false
    @Environment(\.dismissWindow) private var dismissWindow

    private var selected: Profile? {
        store.profiles.first { $0.id == selectedID } ?? store.profiles.first
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(onNew: newProfile)
            HStack(spacing: 0) {
                sidebar
                detail
            }
            statusBar
        }
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
        .ignoresSafeArea()
        .background(shortcuts)
        .sheet(item: $editing) { profile in
            let isNew = !store.contains(profile.id)
            ProfileEditor(
                draft: profile,
                isNew: isNew,
                canDelete: !isNew && store.profiles.count > 1,
                onSave: { saved in
                    store.upsert(saved)
                    selectedID = saved.id
                },
                onDelete: {
                    store.delete(profile.id)
                    selectedID = store.profiles.first?.id
                }
            )
        }
    }

    // MARK: Keyboard shortcuts (⌘1–9 select, esc closes)

    private var shortcuts: some View {
        ZStack {
            ForEach(Array(store.profiles.prefix(9).enumerated()), id: \.element.id) { index, profile in
                Button("") { selectedID = profile.id }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Button("") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    private func shortcutLabel(_ profile: Profile) -> String {
        guard let i = store.profiles.firstIndex(where: { $0.id == profile.id }), i < 9 else { return "" }
        return "⌘\(i + 1)"
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("PROFILES")
                    .font(Theme.label())
                    .tracking(1.1)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.profiles) { profile in
                            ProfileRow(
                                profile: profile,
                                shortcut: shortcutLabel(profile),
                                isSelected: profile.id == selected?.id,
                                isRunning: store.running.contains(profile.id),
                                onSelect: { selectedID = profile.id },
                                onOpen: { launch(profile) }
                            )
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Button(action: newProfile) {
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                    Text("New profile").font(.system(size: 14))
                    Spacer()
                }
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 12)
                .frame(height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(width: 270)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.divider).frame(width: 1)
        }
    }

    // MARK: Detail

    private var detail: some View {
        Group {
            if let p = selected {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 32) {
                        HStack(spacing: 24) {
                            Monogram(profile: p, size: 112, radius: 26)
                                .shadow(color: .black.opacity(0.45), radius: 15, y: 10)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(p.name)
                                    .font(Theme.serif(40))
                                    .lineLimit(1)
                                Text(p.blurb.isEmpty ? "No description" : p.blurb)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.muted)
                            }
                        }

                        HStack(spacing: 12) {
                            StatCard(title: "DATA FOLDER") {
                                Text(p.dataFolder.isEmpty ? "Default" : p.dataFolder)
                                    .font(Theme.mono(18))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            StatCard(title: "FROM ANY APP") {
                                Text(shortcutLabel(p).isEmpty ? "—" : shortcutLabel(p).replacingOccurrences(of: "⌘", with: "⌃⌥"))
                                    .font(.system(size: 20, weight: .medium))
                            }
                            StatCard(title: "LAST OPENED") {
                                Text(lastOpenedText(p.lastOpened))
                                    .font(.system(size: 20, weight: .medium))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.top, 40)
                    .padding(.horizontal, 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    HStack(spacing: 10) {
                        Button { launch(p) } label: {
                            HStack(spacing: 12) {
                                Text("\(store.running.contains(p.id) ? "Switch to" : "Open") \(p.name)")
                                    .font(.system(size: 15, weight: .semibold))
                                KeyCap(text: "↵", filled: true)
                            }
                            .foregroundStyle(p.foreground)
                            .padding(.leading, 22)
                            .padding(.trailing, 16)
                            .frame(height: 46)
                            .background(p.color, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.defaultAction)

                        Button { editing = p } label: {
                            Text("Edit")
                                .font(.system(size: 15, weight: .medium))
                                .padding(.horizontal, 18)
                                .frame(height: 46)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("e", modifiers: .command)

                        Spacer()

                        HStack(spacing: 8) {
                            KeyCap(text: "⌘1–9")
                            Text("switch")
                            KeyCap(text: "esc").padding(.leading, 12)
                            Text("close")
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 44)
                    .padding(.vertical, 18)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Theme.divider).frame(height: 1)
                    }
                }
            }
        }
        .background(
            RadialGradient(colors: [Color(hex: "241D16"), Theme.bg],
                           center: .topLeading, startRadius: 0, endRadius: 700)
        )
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: status.ok ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(status.ok ? Theme.ok : Theme.warn)
            Text(status.text).lineLimit(1)
            Spacer()
            Toggle("Close after opening", isOn: $closeAfterOpening)
                .toggleStyle(.checkbox)
            Text("v0.1.0")
                .font(Theme.mono(12))
                .padding(.leading, 12)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 18)
        .frame(height: 38)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    // MARK: Actions

    private func newProfile() {
        let color = Theme.swatches[store.profiles.count % Theme.swatches.count]
        editing = Profile(name: "", blurb: "", dataFolder: "", colorHex: color)
    }

    private func launch(_ profile: Profile) {
        Task {
            switch await store.launch(profile) {
            case .opened:
                status = (true, "Opened \(profile.name)")
            case .focused:
                status = (true, "Switched to \(profile.name) (already running)")
            case .failed(let message):
                status = (false, message)
                return
            }
            if closeAfterOpening { dismissWindow(id: "main") }
        }
    }

    private func lastOpenedText(_ date: Date?) -> String {
        guard let date else { return "Never" }
        if Date().timeIntervalSince(date) < 60 { return "Just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.formattingContext = .beginningOfSentence
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Pieces

struct TopBar: View {
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text("Which Claude")
                .font(Theme.serif(19, italic: true))
            Spacer()
            Button { Launcher.quitAll() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "power").font(.system(size: 12, weight: .semibold))
                    Text("Quit all Claudes").font(.system(size: 13))
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onNew) {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    Text("New profile").font(.system(size: 13))
                    KeyCap(text: "⌘N")
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(height: 32)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.leading, 84) // room for the traffic lights
        .padding(.trailing, 16)
        .frame(height: 52)
        .background(
            LinearGradient(colors: [Color(hex: "2A221B"), Color(hex: "221C16")],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: "332B24")).frame(height: 1)
        }
    }
}

struct ProfileRow: View {
    let profile: Profile
    let shortcut: String
    let isSelected: Bool
    let isRunning: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Monogram(profile: profile, size: 26, radius: 7)
                Text(profile.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                if isRunning {
                    Circle().fill(Theme.ok).frame(width: 7, height: 7)
                        .help("Running")
                }
                Spacer()
                Text(shortcut)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted.opacity(0.8))
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Theme.rowSelected : (hovering ? Theme.rowSelected.opacity(0.5) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Theme.rowSelectedBorder : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded(onOpen))
    }
}

struct Monogram: View {
    let profile: Profile
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(profile.color)
            .frame(width: size, height: size)
            .overlay(
                Text(profile.initials)
                    .font(Theme.serif(size * (profile.initials.count > 1 ? 0.36 : 0.46)))
                    .foregroundStyle(profile.foreground)
            )
    }
}

struct StatCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.label())
                .tracking(1.1)
                .foregroundStyle(Theme.muted)
            content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "2E2720")))
    }
}

struct KeyCap: View {
    let text: String
    var filled = false

    var body: some View {
        Text(text)
            .font(Theme.mono(11))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(filled ? Color.white.opacity(0.18) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(filled ? .clear : Theme.line))
    }
}

// MARK: - Editor sheet

struct ProfileEditor: View {
    @State var draft: Profile
    let isNew: Bool
    let canDelete: Bool
    let onSave: (Profile) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var trimmed: Profile {
        var p = draft
        p.name = p.name.trimmingCharacters(in: .whitespaces)
        p.blurb = p.blurb.trimmingCharacters(in: .whitespaces)
        p.dataFolder = p.dataFolder.trimmingCharacters(in: .whitespaces)
        return p
    }

    private var isValid: Bool { !trimmed.name.isEmpty && !trimmed.dataFolder.contains("/") }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Monogram(profile: draft, size: 44, radius: 11)
                Text(isNew ? "New profile" : "Edit profile")
                    .font(Theme.serif(24))
            }

            field("NAME", text: $draft.name, placeholder: "Personal")
            field("DESCRIPTION", text: $draft.blurb, placeholder: "What this account is for")
            VStack(alignment: .leading, spacing: 6) {
                field("DATA FOLDER", text: $draft.dataFolder, placeholder: "Default", mono: true)
                Text("Folder in ~/Library/Application Support that holds this account's login. Leave blank for Claude's default.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("COLOR").font(Theme.label()).tracking(1.1).foregroundStyle(Theme.muted)
                HStack(spacing: 14) {
                    ForEach(Theme.swatches, id: \.self) { hex in
                        Button { draft.colorHex = hex } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 26, height: 26)
                                .padding(3)
                                .overlay(Circle().stroke(Theme.text, lineWidth: draft.colorHex == hex ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Color #\(hex)")
                    }
                }
            }

            HStack {
                if canDelete {
                    Button("Delete", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(draft.color)
                .disabled(!isValid)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 440)
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(Theme.label()).tracking(1.1).foregroundStyle(Theme.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(mono ? Theme.mono(14) : .system(size: 14))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        }
    }
}
