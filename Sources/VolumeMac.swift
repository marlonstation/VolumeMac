import AppKit
import SwiftUI
import CoreAudio
import Combine

@main
enum Launcher {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            for direction in [AudioDirection.output, .input] {
                let devices = Audio.endpoints(direction)
                let selected = Audio.selection(direction)
                print("\(direction.title): \(devices.map(\.name).joined(separator: ", "))")
                print("  Default: \(devices.first { $0.id == selected }?.name ?? "unavailable")")
                if let selected, let level = Audio.volume(selected, direction: direction) {
                    print("  \(direction.levelTitle): \(Int((level * 100).rounded()))%")
                } else {
                    print("  Level control unavailable")
                }
            }
            let apps = Audio.applications(on: Audio.selection(.output))
            print("Open apps: \(apps.map(\.name).joined(separator: ", "))")
            print("Active audio: \(apps.filter(\.playing).map(\.name).joined(separator: ", "))")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = VolumeMacDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class VolumeMacDelegate: NSObject, NSApplicationDelegate {
    private let model = MixerModel.shared
    private let mixer = StatusMixerPanel(
        contentRect: NSRect(x: 0, y: 0, width: 312, height: 180),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    private var contentHeight: CGFloat = 180
    private var outsideClickMonitor: Any?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "speaker.wave.1", accessibilityDescription: "VolumeMac")
            image?.isTemplate = true
            button.image = image
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.setAccessibilityLabel("VolumeMac")
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        configureMixer()
        model.refresh()
        if CommandLine.arguments.contains("--show-floating") { model.showFloatingPanel() }
        if CommandLine.arguments.contains("--show-app-volume") {
            model.expanded = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.openMixer() }
        }
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            closeMixer()
            sender.highlight(false)
            let menu = NSMenu()
            let shortcut = model.floating ? "Hide floating shortcut" : "Show floating shortcut"
            let open = menu.addItem(withTitle: "Open Mixer", action: #selector(openMixer), keyEquivalent: "")
            open.target = self
            let toggle = menu.addItem(withTitle: shortcut, action: #selector(toggleFloating), keyEquivalent: "")
            toggle.target = self
            let themeMenu = NSMenu()
            for theme in MixerTheme.allCases {
                let item = themeMenu.addItem(withTitle: theme.title, action: #selector(selectTheme(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = theme.rawValue
                item.state = model.theme == theme ? .on : .off
            }
            menu.addItem(withTitle: "Appearance", action: nil, keyEquivalent: "").submenu = themeMenu
            menu.addItem(.separator())
            let quit = menu.addItem(withTitle: "Quit VolumeMac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.target = NSApp
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY), in: sender)
        } else if mixer.isVisible {
            closeMixer()
        } else {
            openMixer()
        }
    }

    private func configureMixer() {
        mixer.title = "VolumeMac Mixer"
        mixer.level = .popUpMenu
        mixer.isOpaque = false
        mixer.backgroundColor = .clear
        mixer.hasShadow = true
        mixer.hidesOnDeactivate = false
        mixer.isReleasedWhenClosed = false
        mixer.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        mixer.dismiss = { [weak self] in self?.closeMixer() }
        let surface = MixerSurface(frame: .zero, cornerRadius: 16, model: model)
        let content = NSHostingView(rootView: MixerPanel(model: model, measure: { [weak self] height in
            guard let self, height > 0, abs(height - self.contentHeight) > 0.5 else { return }
            self.contentHeight = height
            DispatchQueue.main.async { [weak self] in
                if let self, self.mixer.isVisible { self.positionMixer() }
            }
        }))
        content.sizingOptions = []
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            content.topAnchor.constraint(equalTo: surface.topAnchor),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        mixer.contentView = surface
        mixer.initialFirstResponder = surface
        NotificationCenter.default.addObserver(
            self, selector: #selector(repositionVisibleMixer),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    @objc private func openMixer() {
        guard !mixer.isVisible, positionMixer() else { return }
        model.refresh()
        mixer.makeKeyAndOrderFront(nil)
        mixer.makeFirstResponder(mixer.contentView)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            let pointer = NSEvent.mouseLocation
            if let button = self.statusItem?.button, let window = button.window,
               window.convertToScreen(button.convert(button.bounds, to: nil)).contains(pointer) { return }
            self.closeMixer()
        }
    }

    private func closeMixer() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        mixer.orderOut(nil)
        statusItem?.button?.highlight(false)
    }

    @objc private func repositionVisibleMixer() {
        if mixer.isVisible { _ = positionMixer() }
    }

    @discardableResult
    private func positionMixer() -> Bool {
        guard let button = statusItem?.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return false }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let frame = StatusMixerLayout.frame(under: anchor, in: screen.visibleFrame, contentHeight: contentHeight)
        mixer.setFrame(frame, display: true)
        return true
    }

    @objc private func toggleFloating() { model.toggleFloatingPanel() }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let theme = MixerTheme(rawValue: id) else { return }
        model.selectTheme(theme)
    }
}

enum StatusMixerLayout {
    static func frame(under anchor: NSRect, in visible: NSRect, contentHeight: CGFloat) -> NSRect {
        let inset: CGFloat = 8
        let width = min(312, max(1, visible.width - inset * 2))
        let top = min(anchor.minY - 4, visible.maxY - 2)
        let available = max(1, top - visible.minY - inset)
        let height = min(max(1, contentHeight.rounded(.up)), available, 520)
        let x = min(max(anchor.midX - width / 2, visible.minX + inset), visible.maxX - width - inset)
        return NSRect(x: x, y: top - height, width: width, height: height)
    }
}

enum ShortcutMixerLayout {
    static func frame(nextTo anchor: NSRect, in visible: NSRect, size: NSSize) -> NSRect {
        let inset: CGFloat = 8
        let gap: CGFloat = 5
        let width = min(max(1, size.width), max(1, visible.width - inset * 2))
        let below = anchor.minY - gap - visible.minY - inset
        let above = visible.maxY - inset - anchor.maxY - gap
        let opensBelow = below >= size.height || below >= above
        let height = min(max(1, size.height), max(1, opensBelow ? below : above))
        let x = min(max(anchor.midX - width / 2, visible.minX + inset), visible.maxX - inset - width)
        return NSRect(x: x, y: opensBelow ? anchor.minY - gap - height : anchor.maxY + gap,
                      width: width, height: height)
    }
}

enum MixerTheme: String, CaseIterable {
    case light, gta6

    var title: String { self == .gta6 ? "GTA 6 Mode" : "Light" }
    var peach: NSColor { NSColor(srgbRed: 0.99, green: 0.79, blue: 0.61, alpha: 1) }
    var rose: NSColor { NSColor(srgbRed: 0.95, green: 0.62, blue: 0.71, alpha: 1) }
    var controls: Color { Color(nsColor: self == .gta6 ? peach : .labelColor) }
    var slider: Color {
        self == .gta6 ? Color(nsColor: rose) : Color(red: 0.48, green: 0.52, blue: 0.57)
    }
}

private final class MixerSurface: NSView {
    private let sunset = CAGradientLayer()
    private var themeObservation: AnyCancellable?

    init(frame: NSRect, cornerRadius: CGFloat, model: MixerModel) {
        super.init(frame: frame)
        focusRingType = .none
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        sunset.colors = [
            NSColor(srgbRed: 0.33, green: 0.18, blue: 0.31, alpha: 1).cgColor,
            NSColor(srgbRed: 0.12, green: 0.11, blue: 0.21, alpha: 1).cgColor
        ]
        sunset.startPoint = CGPoint(x: 1, y: 1)
        sunset.endPoint = CGPoint(x: 0, y: 0)
        layer?.insertSublayer(sunset, at: 0)
        themeObservation = model.$theme.sink { [weak self] in self?.applyTheme($0) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sunset.frame = bounds
        CATransaction.commit()
    }

    private func applyTheme(_ theme: MixerTheme) {
        let isGTA6 = theme == .gta6
        appearance = NSAppearance(named: isGTA6 ? .darkAqua : .aqua)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sunset.isHidden = !isGTA6
        layer?.borderColor = (isGTA6 ? theme.rose.withAlphaComponent(0.58) : NSColor(white: 0, alpha: 0.08)).cgColor
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
}

private final class StatusMixerPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

struct DeviceControlState {
    var devices: [AudioEndpoint] = []
    var selected: AudioObjectID?
    var volume: Double?

    var name: String? { devices.first { $0.id == selected }?.name }
}

final class MixerModel: NSObject, ObservableObject {
    static let shared = MixerModel()
    @Published private(set) var output = DeviceControlState()
    @Published private(set) var input = DeviceControlState()
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var appOutputs: [String: AudioObjectID] = [:]
    @Published private(set) var levels: [String: Double] = [:]
    @Published private(set) var states: [String: MixState] = [:]
    @Published private(set) var floating = false
    @Published private(set) var deviceError: String?
    @Published private(set) var theme = MixerTheme(rawValue: UserDefaults.standard.string(forKey: "mixerTheme") ?? "") ?? .light
    @Published var expanded = false

    private let engine = AppMixer()
    private var timer: Timer?
    private var previousVolume: [String: Double] = [:]
    private var panel: FloatingShortcutPanel?
    private var floatingControls: StatusMixerPanel?
    private var floatingControlsHost: NSHostingView<FloatingMixer>?
    private var floatingClickMonitor: Any?
    private var updateInFlight = false
    private var pendingUpdate = false

    func selectTheme(_ theme: MixerTheme) {
        self.theme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: "mixerTheme")
    }

    private override init() {
        super.init()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        output = deviceState(.output)
        let connected = Set(output.devices.map(\.id))
        let availableRoutes = appOutputs.filter { connected.contains($0.value) }
        if availableRoutes != appOutputs { appOutputs = availableRoutes }
        input = deviceState(.input)
        apps = Audio.applications(on: output.selected)
        updateMix()
    }

    func selectDevice(_ device: AudioObjectID, direction: AudioDirection) {
        deviceError = Audio.select(device, direction: direction)
            ? nil : "Could not change the \(direction.title.lowercased()) device."
        refresh()
    }

    func changeLevel(_ value: Double, direction: AudioDirection) {
        let selected = direction == .output ? output.selected : input.selected
        guard let selected else { return }
        if Audio.setVolume(value, on: selected, direction: direction) {
            if direction == .output { output.volume = value }
            else { input.volume = value }
            deviceError = nil
        } else {
            deviceError = "Could not adjust the level for this device."
        }
    }

    private func deviceState(_ direction: AudioDirection) -> DeviceControlState {
        let selected = Audio.selection(direction)
        return DeviceControlState(
            devices: Audio.endpoints(direction),
            selected: selected,
            volume: selected.flatMap { Audio.volume($0, direction: direction) }
        )
    }

    func selectAppOutput(_ device: AudioObjectID?, for app: AudioApp) {
        if let device, !output.devices.contains(where: { $0.id == device }) { return }
        appOutputs[app.id] = device
        updateMix()
    }

    func changeApp(_ app: AudioApp, volume: Double) {
        levels[app.id] = volume.clamped(to: 0...1)
        updateMix()
    }

    func toggleMute(_ app: AudioApp) {
        let gain = levels[app.id] ?? 1
        if gain > 0 {
            previousVolume[app.id] = gain
            changeApp(app, volume: 0)
        } else {
            changeApp(app, volume: previousVolume[app.id] ?? 1)
        }
    }

    func showFloatingPanel() {
        if let panel {
            panel.orderFrontRegardless()
        } else {
            let side: CGFloat = 38
            let panel = FloatingShortcutPanel(
                contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.title = "VolumeMac Shortcut"
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

            let surround = MixerSurface(frame: NSRect(x: 0, y: 0, width: side, height: side), cornerRadius: 11, model: self)

            let shortcut = FloatingShortcutIcon(frame: surround.bounds)
            shortcut.onPress = { [weak self] view in self?.toggleShortcutControls(view) }
            shortcut.onDragStart = { [weak self] in self?.closeShortcutControls() }
            shortcut.onHide = { [weak self] in self?.toggleFloatingPanel() }
            surround.addSubview(shortcut)
            panel.contentView = surround
            if !panel.setFrameUsingName("VolumeMac-shortcut"), let screen = NSScreen.main {
                let area = screen.visibleFrame
                panel.setFrameTopLeftPoint(NSPoint(x: area.maxX - side - 18, y: area.maxY - 20))
            }
            panel.setContentSize(NSSize(width: side, height: side))
            if !NSScreen.screens.contains(where: { $0.visibleFrame.contains(panel.frame) }) {
                panel.center()
            }
            panel.setFrameAutosaveName("VolumeMac-shortcut")
            self.panel = panel
            panel.orderFrontRegardless()
        }
        floating = true
    }

    func toggleFloatingPanel() {
        if floating {
            closeShortcutControls()
            panel?.orderOut(nil)
            floating = false
        } else {
            showFloatingPanel()
        }
    }

    private func toggleShortcutControls(_ sender: NSView) {
        if floatingControls?.isVisible == true {
            closeShortcutControls()
            return
        }
        guard let window = sender.window, let screen = window.screen else { return }
        refresh()
        if floatingControls == nil { prepareShortcutControls() }
        guard let controls = floatingControls, let host = floatingControlsHost else { return }
        let anchor = window.convertToScreen(sender.convert(sender.bounds, to: nil))
        let frame = ShortcutMixerLayout.frame(nextTo: anchor, in: screen.visibleFrame, size: host.fittingSize)
        controls.setFrame(frame, display: true)
        controls.makeKeyAndOrderFront(nil)
        controls.makeFirstResponder(controls.contentView)
        floatingClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak window] _ in
            guard window?.frame.contains(NSEvent.mouseLocation) != true else { return }
            self?.closeShortcutControls()
        }
    }

    private func prepareShortcutControls() {
        let controls = StatusMixerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 254, height: 140),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        controls.title = "VolumeMac Floating Controls"
        controls.level = .popUpMenu
        controls.isOpaque = false
        controls.backgroundColor = .clear
        controls.hasShadow = true
        controls.hidesOnDeactivate = false
        controls.isReleasedWhenClosed = false
        controls.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        controls.dismiss = { [weak self] in self?.closeShortcutControls() }

        let surface = MixerSurface(frame: .zero, cornerRadius: 16, model: self)

        let host = NSHostingView(rootView: FloatingMixer(model: self))
        host.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            host.topAnchor.constraint(equalTo: surface.topAnchor),
            host.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        controls.contentView = surface
        controls.initialFirstResponder = surface
        floatingControls = controls
        floatingControlsHost = host
    }

    private func closeShortcutControls() {
        if let monitor = floatingClickMonitor {
            NSEvent.removeMonitor(monitor)
            floatingClickMonitor = nil
        }
        floatingControls?.orderOut(nil)
    }

    private func updateMix() {
        guard !updateInFlight else {
            pendingUpdate = true
            return
        }
        var requests: [String: MixRequest] = [:]
        for app in apps {
            let level = levels[app.id] ?? 1
            if let destination = appOutputs[app.id], app.playing {
                requests[app.id] = MixRequest(source: nil, output: destination,
                                              processes: app.processes.sorted(), gain: level)
            } else if let selected = output.selected, level < 1, !app.defaultOutputProcesses.isEmpty {
                requests[app.id] = MixRequest(source: selected, output: selected,
                                              processes: app.defaultOutputProcesses.sorted(), gain: level)
            }
        }
        guard !requests.isEmpty || !states.isEmpty else { return }
        updateInFlight = true
        engine.update(requests) { [weak self] result in
            guard let self else { return }
            self.states = result
            self.updateInFlight = false
            if self.pendingUpdate {
                self.pendingUpdate = false
                self.updateMix()
            }
        }
    }
}

struct MixerPanel: View {
    @ObservedObject var model: MixerModel
    let measure: (CGFloat) -> Void

    var body: some View {
        ScrollView {
            content.padding(.horizontal, 16).padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: MixerHeightKey.self, value: geometry.size.height)
                })
        }
        .tint(model.theme.controls)
        .onPreferenceChange(MixerHeightKey.self, perform: measure)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sound").font(.headline)
                    .foregroundStyle(model.theme.controls)
                Spacer()
                Button(model.floating ? "Hide Floating Shortcut" : "Show Floating Shortcut") { model.toggleFloatingPanel() }
                    .buttonStyle(ShortcutButtonStyle(theme: model.theme))
                    .help(model.floating ? "Hide the floating volume shortcut" : "Show a floating volume shortcut")
            }
            DeviceControls(model: model, direction: .output)
            DeviceControls(model: model, direction: .input)
            if let error = model.deviceError { Text(error).font(.caption).foregroundStyle(.orange) }
            Divider()
            DisclosureGroup(isExpanded: $model.expanded) {
                VStack(alignment: .leading, spacing: 7) {
                    if model.apps.isEmpty {
                        Text("No apps open.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.apps) { app in
                                AppVolumeRow(app: app, model: model)
                                if app.id != model.apps.last?.id { Divider() }
                            }
                        }.padding(.trailing, 5)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("App Volume").font(.subheadline.weight(.semibold))
            }
        }
    }
}

private struct ShortcutButtonStyle: ButtonStyle {
    let theme: MixerTheme

    func makeBody(configuration: Configuration) -> some View {
        let foreground = theme == .gta6 ? theme.controls : .primary
        configuration.label
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(foreground)
            .background(theme == .gta6 ? Color.white.opacity(configuration.isPressed ? 0.16 : 0.07)
                        : configuration.isPressed ? Color.black.opacity(0.06) : .white,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(theme == .gta6 ? Color(nsColor: theme.rose).opacity(0.42) : Color.black.opacity(0.12))
            }
    }
}

private struct MixerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private final class FloatingShortcutPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class FloatingShortcutIcon: NSView {
    var onPress: ((NSView) -> Void)?
    var onDragStart: (() -> Void)?
    var onHide: (() -> Void)?
    private let symbol = NSImage(systemSymbolName: "speaker.wave.1", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))?
        .withSymbolConfiguration(.init(paletteColors: [.labelColor]))
    private var dragOrigin: (pointer: NSPoint, window: NSPoint)?
    private var moved = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open volume controls")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let symbol else { return }
        symbol.draw(in: NSRect(x: bounds.midX - symbol.size.width / 2,
                              y: bounds.midY - symbol.size.height / 2,
                              width: symbol.size.width, height: symbol.size.height))
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?(self)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.charactersIgnoringModifiers == " " { _ = accessibilityPerformPress() }
        else { super.keyDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Hide Floating Shortcut", action: #selector(hide), keyEquivalent: "")
        item.target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func hide() { onHide?() }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragOrigin = (NSEvent.mouseLocation, window.frame.origin)
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragOrigin else { return }
        let pointer = NSEvent.mouseLocation
        let dx = pointer.x - dragOrigin.pointer.x
        let dy = pointer.y - dragOrigin.pointer.y
        guard moved || hypot(dx, dy) > 3 else { return }
        if !moved { onDragStart?() }
        moved = true
        window.setFrameOrigin(NSPoint(x: dragOrigin.window.x + dx, y: dragOrigin.window.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
            moved = false
        }
        guard dragOrigin != nil else { return }
        if moved {
            if let window, let screen = window.screen {
                let frame = window.frame
                let area = screen.visibleFrame
                window.setFrameOrigin(NSPoint(
                    x: min(max(frame.minX, area.minX), area.maxX - frame.width),
                    y: min(max(frame.minY, area.minY), area.maxY - frame.height)
                ))
            }
            return
        }
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            _ = accessibilityPerformPress()
        }
    }
}

private struct FloatingMixer: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeviceControls(model: model, direction: .output)
            DeviceControls(model: model, direction: .input)
            if let error = model.deviceError { Text(error).font(.caption2).foregroundStyle(.orange) }
        }
        .padding(12)
        .frame(width: 254)
        .tint(model.theme.controls)
    }
}

private struct DeviceControls: View {
    @ObservedObject var model: MixerModel
    let direction: AudioDirection

    private var state: DeviceControlState { direction == .output ? model.output : model.input }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(direction.title).font(.subheadline.weight(.medium))
                Spacer(minLength: 5)
                Menu {
                    ForEach(state.devices) { device in
                        Button { model.selectDevice(device.id, direction: direction) } label: {
                            if device.id == state.selected { Label(device.name, systemImage: "checkmark") }
                            else { Text(device.name) }
                        }
                    }
                } label: {
                    Text(state.name ?? "Unavailable").lineLimit(1).truncationMode(.tail)
                }
                .disabled(state.devices.isEmpty)
                .frame(maxWidth: 184, alignment: .trailing)
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .accessibilityLabel("\(direction.title) Device")
            }
            if let volume = state.volume {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { state.volume ?? volume },
                                          set: { model.changeLevel($0, direction: direction) }), in: 0...1)
                        .tint(model.theme.slider)
                        .accessibilityLabel(direction.levelTitle)
                    VolumeValue(volume: volume)
                }
            } else if state.selected != nil {
                Text("Adjust the level on the device.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AppVolumeRow: View {
    let app: AudioApp
    @ObservedObject var model: MixerModel
    private var volume: Double { model.levels[app.id] ?? 1 }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = app.icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "app").resizable().foregroundStyle(.secondary) }
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(app.name).font(.caption.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    condition
                }
                HStack(spacing: 6) {
                    Slider(value: Binding(get: { volume }, set: { model.changeApp(app, volume: $0) }), in: 0...1)
                        .tint(model.theme.slider)
                        .accessibilityLabel("Volume for \(app.name)")
                    VolumeValue(volume: volume)
                    Button { model.toggleMute(app) } label: {
                        Image(systemName: volume == 0 ? "speaker.slash" : "speaker.wave.1")
                            .foregroundStyle(.secondary)
                            .frame(width: 19)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(volume == 0 ? "Unmute \(app.name)" : "Mute \(app.name)")
                }
                outputMenu
            }
        }
        .padding(.vertical, 5)
        .frame(minHeight: 54)
    }

    private var selectedOutput: AudioObjectID? { model.appOutputs[app.id] }

    private var outputMenu: some View {
        Menu {
            Button { model.selectAppOutput(nil, for: app) } label: {
                if selectedOutput == nil { Label("App Default", systemImage: "checkmark") }
                else { Text("App Default") }
            }
            Divider()
            ForEach(model.output.devices) { device in
                Button { model.selectAppOutput(device.id, for: app) } label: {
                    if selectedOutput == device.id { Label(device.name, systemImage: "checkmark") }
                    else { Text(device.name) }
                }
            }
        } label: {
            Label(model.output.devices.first { $0.id == selectedOutput }?.name ?? "App Default",
                  systemImage: "speaker")
                .font(.caption2)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .accessibilityLabel("Output for \(app.name)")
    }

    @ViewBuilder
    private var condition: some View {
        if case .failed(let message) = model.states[app.id] {
            Label("Unavailable", systemImage: "exclamationmark.circle")
                .font(.caption2).foregroundStyle(.orange)
                .help(message).accessibilityHint(message)
        } else if model.states[app.id] == .preparing {
            Text("Connecting…").font(.caption2).foregroundStyle(.secondary)
        } else if app.playing, selectedOutput == nil, volume < 1, app.defaultOutputProcesses.isEmpty {
            Text("Other output").font(.caption2).foregroundStyle(.secondary)
        } else if !app.playing, selectedOutput != nil || volume < 1 {
            Text("Waiting for audio").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct VolumeValue: View {
    let volume: Double
    var body: some View {
        Text("\(Int((volume * 100).rounded()))%")
            .monospacedDigit().font(.caption).foregroundStyle(.secondary)
            .frame(width: 34, alignment: .trailing)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
