import SwiftUI
import TranscriptionEngines
import DictationCore

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var controller: DictationController

    var body: some View {
        TabView {
            GeneralTab(model: model, controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelTab(model: model, controller: controller)
                .tabItem { Label("Model", systemImage: "waveform") }
            PermissionsTab(controller: controller)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        // Both dimensions need constraining. With only a width, the hosting
        // view is handed a zero-height layout and the window collapses to just
        // the tab bar. maxHeight lets the tabs take the window's height, and
        // each grouped Form scrolls within it.
        .frame(minWidth: 540, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var controller: DictationController

    var body: some View {
        Form {
            Section("Shortcut") {
                HStack {
                    Picker("Trigger key", selection: presetSelection) {
                        ForEach(HotkeyTrigger.presets, id: \.keyCode) { preset in
                            Text(preset.label).tag(preset.keyCode as UInt16?)
                        }
                        if !HotkeyTrigger.presets.contains(where: { $0.keyCode == model.preferences.trigger.keyCode }) {
                            Text(model.preferences.trigger.label).tag(model.preferences.trigger.keyCode as UInt16?)
                        }
                    }
                    Button(model.isRecordingKey ? "Press a key…" : "Set…") {
                        model.isRecordingKey ? model.endRecordingKey() : model.beginRecordingKey()
                    }
                }
                Text(triggerHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Activation", selection: $model.preferences.activationMode) {
                    ForEach(ActivationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Toggle("Stop the key from reaching other apps", isOn: $model.preferences.suppressTriggerKey)
                Text("Leave this off for Fn unless the Globe key is doing something unwanted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Timing") {
                Stepper(
                    "Hold delay: \(model.preferences.holdDelayMilliseconds) ms",
                    value: $model.preferences.holdDelayMilliseconds, in: 0...800, step: 20)
                Stepper(
                    "Double-tap window: \(model.preferences.doubleTapWindowMilliseconds) ms",
                    value: $model.preferences.doubleTapWindowMilliseconds, in: 150...800, step: 20)
                Stepper(
                    "Maximum recording: \(model.preferences.maximumRecordingSeconds) s",
                    value: $model.preferences.maximumRecordingSeconds, in: 30...1800, step: 30)
            }

            Section("Output") {
                Toggle("Paste into the focused app", isOn: $model.preferences.pasteIntoFocusedApp)
                Toggle("Copy to clipboard", isOn: $model.preferences.copyToClipboard)
                Toggle("Restore the previous clipboard after pasting", isOn: $model.preferences.restoreClipboardAfterPaste)
                    .disabled(!model.preferences.pasteIntoFocusedApp)
            }

            Section("Appearance") {
                Toggle("Show an icon in the Dock", isOn: $model.preferences.showDockIcon)
                Text("Turn this on if the menu bar icon is hidden. When the menu bar is full, macOS can place the icon behind the notch and not draw it. Launching OpenWhisperFlow again also reopens these preferences.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Feedback") {
                Toggle("Show the on-screen indicator", isOn: $model.preferences.showOverlay)
                Toggle("Play sounds", isOn: $model.preferences.playSounds)
                Toggle("Launch at login", isOn: launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }

    private var presetSelection: Binding<UInt16?> {
        Binding(
            get: { model.preferences.trigger.keyCode },
            set: { newValue in
                guard let newValue else { return }
                model.preferences.trigger = HotkeyTrigger(
                    keyCode: newValue,
                    label: HotkeyTrigger.label(forKeyCode: newValue))
            })
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { model.preferences.launchAtLogin },
            set: { newValue in
                model.preferences.launchAtLogin = newValue
                model.applyLaunchAtLogin(newValue)
            })
    }

    private var triggerHint: String {
        let key = model.preferences.trigger.label
        switch model.preferences.activationMode {
        case .hold:
            return "Hold \(key) and speak. Release to transcribe."
        case .doubleTapToggle:
            return "Double-tap \(key) to start, tap once to stop."
        case .holdAndDoubleTap:
            return "Hold \(key) and speak, or double-tap to keep recording hands-free."
        }
    }
}

// MARK: - Model

private struct ModelTab: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var controller: DictationController

    var body: some View {
        Form {
            Section("Choose a speech model") {
                ForEach(EngineCatalog.selectable) { option in
                    EngineRow(
                        option: option,
                        isSelected: option.id == controller.selectedOption.id,
                        isInstalled: model.installedEngineIDs.contains(option.id))
                    { model.preferences.engineID = option.id }
                }
            }

            Section("Selected model") {
                SetupRow(model: model, controller: controller)
            }

            if !model.orphanedDownloads.isEmpty {
                Section("Unused downloads") {
                    Text("These were downloaded by an earlier version and are no longer offered. Removing them frees \(model.orphanedTotalMB) MB.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(model.orphanedDownloads) { orphan in
                        HStack {
                            Text(orphan.name).font(.callout)
                            Spacer()
                            Text("\(orphan.sizeMB) MB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Remove") {
                                Task { await model.removeOrphan(orphan) }
                            }
                        }
                    }
                }
            }

            Section {
                Text("Every option transcribes English on this Mac. No audio is sent anywhere, and there are no usage limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshInstalledEngines() }
        .onChange(of: model.preferences.engineID) { _, _ in
            Task { await model.refreshInstalledEngines() }
        }
        .onChange(of: controller.selectedEngineIsInstalled) { _, _ in
            Task { await model.refreshInstalledEngines() }
        }
    }
}

/// One selectable model, described in plain language.
private struct EngineRow: View {
    let option: EngineOption
    let isSelected: Bool
    let isInstalled: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.system(size: 15))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(option.name)
                            .font(.callout.weight(.medium))
                        if isInstalled {
                            Text("Ready")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }
                    HStack(spacing: 6) {
                        Badge(text: option.download, emphasis: option.approximateMB == 0)
                        Badge(text: "\(option.accuracy) accuracy", emphasis: option.accuracy == "Best")
                        Badge(text: option.speed, emphasis: false)
                    }
                    Text(option.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct Badge: View {
    let text: String
    let emphasis: Bool

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (emphasis ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12)),
                in: Capsule())
            .foregroundStyle(emphasis ? Color.accentColor : .secondary)
    }
}

/// Download / ready state for whichever model is selected.
private struct SetupRow: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var controller: DictationController

    var body: some View {
        let option = controller.selectedOption
        let installed = model.installedEngineIDs.contains(option.id)

        VStack(alignment: .leading, spacing: 8) {
            if let fraction = controller.downloadFraction {
                ProgressView(value: fraction)
                Text(controller.status.menuLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .preparing(let detail) = controller.status {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(detail).font(.caption)
                }
            } else if case .failed(let message) = controller.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Try again") { controller.prepareSelectedEngine() }
            } else if installed {
                Label("\(option.name) is ready to use", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                if option.approximateMB > 0 {
                    Button("Remove download") {
                        Task {
                            await controller.removeDownload(option)
                            await model.refreshInstalledEngines()
                        }
                    }
                }
            } else {
                Text(setupPrompt(for: option))
                    .font(.callout)
                Button(option.approximateMB == 0 ? "Set up" : "Download \(option.download)") {
                    controller.prepareSelectedEngine()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func setupPrompt(for option: EngineOption) -> String {
        option.approximateMB == 0
            ? "macOS will fetch its speech files the first time you use this, which usually takes a few seconds."
            : "\(option.name) has not been downloaded yet. This is a \(option.download) download and only happens once."
    }
}

// MARK: - Permissions

private struct PermissionsTab: View {
    @ObservedObject var controller: DictationController
    @State private var accessibility = Permissions.hasAccessibility
    @State private var microphone = Permissions.hasMicrophone

    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Accessibility") {
                row(
                    granted: accessibility,
                    title: "Monitor the trigger key and paste text",
                    detail: "OpenWhisperFlow needs Accessibility access to notice the trigger key in any app and to send Command-V.")
                HStack {
                    Button("Open System Settings") { Permissions.openAccessibilitySettings() }
                    Button("Request") { Permissions.requestAccessibility() }
                }
            }

            Section("Microphone") {
                row(
                    granted: microphone,
                    title: "Record your voice",
                    detail: "Audio is transcribed locally and never uploaded.")
                HStack {
                    Button("Open System Settings") { Permissions.openMicrophoneSettings() }
                    Button("Request") {
                        Task { _ = await AudioRecorder.requestMicrophoneAccess() }
                    }
                }
            }

            if accessibility, !controller.isMonitoring {
                Section {
                    Text("Accessibility is granted but the key monitor is not running yet.")
                        .font(.caption)
                    Button("Start the key monitor") { controller.recheck() }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in
            let nowAccessibility = Permissions.hasAccessibility
            let nowMicrophone = Permissions.hasMicrophone
            // Picking up a freshly granted permission without a restart.
            if nowAccessibility != accessibility || nowMicrophone != microphone {
                accessibility = nowAccessibility
                microphone = nowMicrophone
                controller.recheck()
            }
        }
    }

    @ViewBuilder
    private func row(granted: Bool, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                granted ? "Granted" : "Not granted",
                systemImage: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(title).font(.callout)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
