import SwiftUI

/// MenuBarExtra's panel doesn't shrink its window when the SwiftUI content
/// gets shorter — it keeps the taller frame and paints the leftover area with
/// its background material, which is the grey rectangle left hanging below the
/// panel. Resizing the window to match the content (and invalidating the stale
/// shadow) removes it.
///
/// Also makes the app active when the panel opens, so the first click lands on
/// a control instead of being spent focusing the window, and so the shortcut
/// recorder can see key events.
private struct PanelWindowFixer: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let target = NSSize(width: width, height: height)
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.contentLayoutRect.size.height != target.height {
                window.setContentSize(target)
            }
            window.invalidateShadow()
            window.displayIfNeeded()
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// One row of the grouped settings list: title left, control right.
private struct SettingRow<Control: View>: View {
    let title: String
    let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.callout)
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }
}

/// The subtle rounded fill macOS uses behind grouped controls.
private struct GroupBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(0.06))
    }
}

struct MenuBarView: View {
    @ObservedObject var device: DeviceManager
    @ObservedObject private var hotKeys = HotKeyManager.shared
    @State private var showLog = false
    @State private var showingEQ = false
    @State private var naming: NamingMode?
    @State private var nameDraft = ""
    @FocusState private var nameFieldFocused: Bool

    /// Inline naming in the preset row: a new preset, or renaming one.
    private enum NamingMode: Equatable {
        case new
        case rename(UUID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
            Divider()

            if device.isConnected {
                controls
            } else if device.isConnecting {
                connectingState
            } else {
                connectPrompt
            }

            Spacer(minLength: 0)
            Divider()
            footer
        }
        .padding(12)
        // One discrete height per state rather than a continuously resizing
        // panel: MenuBarExtra's window ghosts if it resizes while animating.
        .frame(width: 300, height: panelHeight, alignment: .top)
        .background(PanelWindowFixer(width: 300, height: panelHeight))
        .animation(nil, value: device.isConnected)
        .animation(nil, value: showLog)
        // The recorder lives on the main page: stop it if that page goes away
        // (panel closed, or switched to the EQ page) mid-recording.
        .onDisappear { hotKeys.stopRecording() }
        .onChange(of: showingEQ) { _, _ in hotKeys.stopRecording() }
        .onChange(of: device.isConnected) { _, connected in
            // Reconnecting should land on the main controls, not wherever the
            // last session was left.
            if !connected {
                showingEQ = false
                naming = nil
            }
        }
        .onAppear {
            if !device.isConnected {
                device.refreshPairedDevices()
            }
        }
    }

    private var panelHeight: CGFloat {
        let base: CGFloat = device.isConnected ? 428 : 175
        return base + (showLog ? 120 : 0)
    }

    // MARK: - Header

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
            }
            if let battery = batteryText {
                Text(battery)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                    .help(device.caseReadingNote ?? "")
            }
        }
        .padding(.bottom, 8)
    }

    private var batteryText: String? {
        guard device.isConnected else { return nil }
        return device.batterySummary
    }

    /// Shown while the channel is opening. Offering "Turn On Controls" here
    /// would just queue a second connect on top of the one in flight.
    private var connectingState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Opening controls…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("This can take a few seconds after the earbuds reconnect.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("Cancel") {
                device.disconnect()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Not connected

    /// One action, picked from the situation: connect if the earbuds are
    /// already linked to the Mac, otherwise send the user to Bluetooth
    /// settings to turn them on or pair them.
    private var connectPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let target = device.target, target.inRange {
                Text("\(target.name) is connected to your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Turn On Controls") {
                    device.connectToTarget()
                }
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity)
            } else {
                Text(device.target == nil
                     ? "No earbuds paired yet. Pair them in Bluetooth settings first."
                     : "\(device.target?.name ?? "Your earbuds") aren't connected to this Mac. Put them in and connect from Bluetooth settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Bluetooth Settings") {
                    device.openBluetoothSettings()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Connected

    /// macOS's own motion curve for a push between panels.
    private static let pageAnimation: Animation = .snappy(duration: 0.32)
    /// Both pages share this height, so sliding between them never resizes
    /// the window mid-animation — a resizing MenuBarExtra panel ghosts.
    private static let controlsHeight: CGFloat = 300

    /// Two pages in one fixed area, like Control Center's drill-in: the main
    /// controls, and the equalizer pushed in from the right.
    private var controls: some View {
        ZStack(alignment: .top) {
            if showingEQ {
                equalizerPage
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                mainPage
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(height: Self.controlsHeight, alignment: .top)
        .clipped()
        .padding(.vertical, 8)
    }

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            noiseControl
            equalizerRow
            settingsGroup
            releaseControl
        }
    }

    private var noiseControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Noise Control")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { device.ancMode },
                set: { device.setAncMode($0) }
            )) {
                ForEach(AncMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // The system segmented control at its largest size: the capsule
            // Liquid Glass style, centred. SwiftUI won't stretch a segmented
            // control, and the AppKit version that does stretch only comes at
            // normal height. (The draggable glass lens only exists for tabs in
            // a window title bar, which a menu bar panel doesn't have.)
            .controlSize(.extraLarge)
            .frame(maxWidth: .infinity)
        }
    }

    private var equalizerRow: some View {
        Button {
            withAnimation(Self.pageAnimation) { showingEQ = true }
        } label: {
            HStack(spacing: 6) {
                Text("Equalizer")
                Spacer()
                Text(device.activeSelectionName ?? "Custom")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(GroupBackground())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Every setting on one grid: same row height, title on the left, its
    /// control right-aligned — the System Settings grouped-list layout.
    private var settingsGroup: some View {
        VStack(spacing: 0) {
            SettingRow("In-Ear Detection") {
                Toggle("", isOn: Binding(
                    get: { device.inEarDetection },
                    set: { device.setInEarDetection($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }
            Divider().padding(.leading, 10)
            SettingRow("Connect Automatically") {
                Toggle("", isOn: $device.autoConnect)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            Divider().padding(.leading, 10)
            SettingRow("Open at Login") {
                Toggle("", isOn: Binding(
                    get: { device.openAtLogin },
                    set: { device.setOpenAtLogin($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }
            Divider().padding(.leading, 10)
            SettingRow("Cycle ANC Shortcut") {
                shortcutControl
            }
        }
        .background(GroupBackground())
    }

    private var releaseControl: some View {
        VStack(spacing: 2) {
            Button("Release Control") {
                device.disconnect()
            }
            .frame(maxWidth: .infinity)
            Text("Earbuds stay connected to your Mac")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Equalizer page

    private var equalizerPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Text("Equalizer")
                    .font(.headline)
                HStack {
                    Button {
                        naming = nil
                        withAnimation(Self.pageAnimation) { showingEQ = false }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                                .font(.callout.weight(.semibold))
                            Text("Back")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    Spacer()
                    // Only for hand-tuned curves; kept in the layout either
                    // way so the title doesn't shift when it appears.
                    Button("Flat") { device.select(.builtIn(.signature)) }
                        .buttonStyle(.link)
                        .opacity(device.activeSelection == nil ? 1 : 0)
                        .disabled(device.activeSelection != nil)
                }
                .font(.callout)
            }
            .frame(height: 22)

            Group {
                if naming != nil {
                    nameField
                        .transition(.opacity)
                } else {
                    presetPickerRow
                        .transition(.opacity)
                }
            }
            .frame(height: 22)

            VStack(spacing: 3) {
                ForEach(Array(WuqiProtocol.bandFrequencies.enumerated()), id: \.offset) { index, frequency in
                    bandSlider(index: index, frequency: frequency)
                }
            }
        }
    }

    private var presetPickerRow: some View {
        HStack(spacing: 6) {
            // A hand-tuned curve matches no preset, so selection is optional
            // and the picker simply shows nothing selected.
            Picker("", selection: Binding<EqSelection?>(
                get: { device.activeSelection },
                set: { if let selection = $0 { device.select(selection) } }
            )) {
                ForEach(EqPreset.allCases) { preset in
                    Text(preset.label).tag(EqSelection?.some(.builtIn(preset)))
                }
                if !device.customPresets.isEmpty {
                    Divider()
                    ForEach(device.customPresets) { preset in
                        Text(preset.name).tag(EqSelection?.some(.custom(preset.id)))
                    }
                }
            }
            .labelsHidden()

            presetActionsMenu
        }
    }

    private var presetActionsMenu: some View {
        Menu {
            Button("Save as New Preset…") {
                beginNaming(.new)
            }
            // Saving a curve that's already a preset would just duplicate it.
            .disabled(device.activeSelection != nil)

            if let modified = device.modifiedCustomPreset {
                Button("Save Changes to “\(modified.name)”") {
                    device.updatePreset(modified.id)
                }
            }

            if case .custom(let id) = device.activeSelection {
                Button("Rename…") {
                    beginNaming(.rename(id))
                }
                Divider()
                Button("Delete Preset", role: .destructive) {
                    device.deletePreset(id)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Save, rename or delete presets")
    }

    private var nameField: some View {
        HStack(spacing: 6) {
            TextField(naming == .new ? "Preset name" : "New name", text: $nameDraft)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onSubmit(commitNaming)
                .onExitCommand(perform: cancelNaming)
            Button("Save", action: commitNaming)
            Button("Cancel", action: cancelNaming)
        }
        .controlSize(.small)
    }

    private func beginNaming(_ mode: NamingMode) {
        switch mode {
        case .new:
            nameDraft = device.suggestedPresetName
        case .rename(let id):
            nameDraft = device.customPresets.first { $0.id == id }?.name ?? ""
        }
        withAnimation(Self.pageAnimation) { naming = mode }
        // Focus once the field exists, so typing replaces the suggestion.
        DispatchQueue.main.async { nameFieldFocused = true }
    }

    private func commitNaming() {
        switch naming {
        case .new: device.saveCurrentCurveAsPreset(named: nameDraft)
        case .rename(let id): device.renamePreset(id, to: nameDraft)
        case nil: break
        }
        withAnimation(Self.pageAnimation) { naming = nil }
    }

    private func cancelNaming() {
        withAnimation(Self.pageAnimation) { naming = nil }
    }

    private func bandSlider(index: Int, frequency: Int) -> some View {
        HStack(spacing: 6) {
            Text(label(for: frequency))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { Double(device.eqGains[index]) },
                    set: { device.setGain(band: index, to: Int8($0.rounded())) }
                ),
                in: Double(WuqiProtocol.gainRange.lowerBound)...Double(WuqiProtocol.gainRange.upperBound),
                step: 1,
                onEditingChanged: { editing in
                    if !editing { device.commitEq() }
                }
            )
            .controlSize(.small)

            Text("\(device.eqGains[index] > 0 ? "+" : "")\(device.eqGains[index])")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
        }
        .frame(height: 18)
    }

    private func label(for frequency: Int) -> String {
        frequency >= 1000 ? "\(frequency / 1000)k" : "\(frequency)"
    }

    // MARK: - Shortcut

    private var shortcutControl: some View {
        HStack(spacing: 4) {
            // Sits left of the key so the key itself lines up with the
            // switches above it.
            if hotKeys.combo != nil, !hotKeys.isRecording {
                Button {
                    hotKeys.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }
            Button(shortcutButtonTitle) {
                if hotKeys.isRecording {
                    hotKeys.stopRecording()
                } else {
                    hotKeys.startRecording()
                }
            }
            .controlSize(.small)
        }
    }

    private var shortcutButtonTitle: String {
        if hotKeys.isRecording { return "Press keys…" }
        return hotKeys.combo?.displayString ?? "Record"
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showLog, !device.recentLogLines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(device.recentLogLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 110)
            }

            HStack(spacing: 12) {
                Button(showLog ? "Hide Log" : "Show Log") {
                    showLog.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
                Button("Save Logs…") {
                    device.saveLogs()
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(device.logEntries.isEmpty)
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(.top, 8)
    }

    private var statusColor: Color {
        switch device.status {
        case .connected: return .green
        case .connecting, .searching: return .yellow
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var statusText: String {
        switch device.status {
        case .connected(let name): return name
        case .connecting: return "Connecting…"
        case .searching: return "Searching…"
        case .failed(let message): return message
        case .disconnected: return "Not connected"
        }
    }
}
