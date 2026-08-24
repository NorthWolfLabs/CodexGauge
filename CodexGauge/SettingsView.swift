import AppKit
import SwiftUI

struct SettingsView: View {
    private struct ThresholdRule: Identifiable, Equatable {
        let id = UUID()
        var percentage: Int
    }

    @Bindable var state: AppState
    @Bindable var settings: SettingsStore
    @Bindable var navigation: SettingsNavigationModel
    @State private var thresholdRules: [ThresholdRule]
    @FocusState private var codexHomeFocused: Bool
    @FocusState private var focusedThresholdID: UUID?

    init(state: AppState, navigation: SettingsNavigationModel = SettingsNavigationModel()) {
        self.state = state
        settings = state.settings
        self.navigation = navigation
        _thresholdRules = State(initialValue: state.settings.notificationThresholds.map {
            ThresholdRule(percentage: $0)
        })
    }

    var body: some View {
        Group {
            switch navigation.selection {
            case .general: general
            case .notifications: notifications
            }
        }
        .frame(width: 600, height: 380)
    }

    private var general: some View {
        Form {
            Section("Startup") {
                Toggle("Launch CodexGauge at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.updateLaunchAtLogin($0) }
                ))
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Refresh") {
                Picker("Check allowances", selection: $settings.refreshInterval) {
                    Text("Every second").tag(TimeInterval(1))
                    Text("Every 5 seconds").tag(TimeInterval(5))
                    Text("Every 15 seconds").tag(TimeInterval(15))
                    Text("Every 30 seconds").tag(TimeInterval(30))
                    Text("Every 60 seconds").tag(TimeInterval(60))
                    Text("Every 120 seconds").tag(TimeInterval(120))
                }
                .pickerStyle(.menu)
                .onChange(of: settings.refreshInterval) { _, _ in
                    state.rescheduleRefresh()
                }
                Text("Live task status updates separately as work happens on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Codex") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Codex helper")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Text(state.executableURL?.path ?? "Not found")
                            .foregroundStyle(state.executableURL == nil ? .red : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…", action: chooseExecutable)
                            .fixedSize()
                    }
                }
                TextField("Codex data folder", text: $settings.codexHomeOverride, prompt: Text("~/.codex"))
                    .focused($codexHomeFocused)
                    .onSubmit { Task { await state.reconnect() } }
                    .onChange(of: codexHomeFocused) { _, focused in
                        if !focused { Task { await state.reconnect() } }
                    }
                if let error = state.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if state.executableURL != nil, state.displayFreshness == .fresh {
                    Label("Connected to Codex.", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let message = state.executableValidationMessage {
                    let verified = message == "OpenAI-signed Codex helper verified."
                    if message == "Checking Codex helper…" {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(message)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Label(
                            message,
                            systemImage: verified ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(verified ? .green : .red)
                    }
                }
                Button("Check again") { Task { await state.reconnect() } }
            }
        }
        .formStyle(.grouped)
    }

    private var notifications: some View {
        Form {
            Section("Notification permission") {
                LabeledContent("Status", value: notificationStatusLabel)
                if state.notificationAuthorization == .denied {
                    Button("Open Notification Settings") {
                        state.openNotificationSettings()
                    }
                } else if state.notificationAuthorization == .notDetermined {
                    Button("Allow Notifications") {
                        Task { _ = await state.requestNotificationPermission() }
                    }
                }
            }

            Section {
                Toggle("Notify me when an allowance runs low", isOn: $settings.quotaNotificationsEnabled)
                    .accessibilityIdentifier("allowance-alerts-toggle")
                    .onChange(of: settings.quotaNotificationsEnabled) { _, enabled in
                        if enabled { Task { _ = await state.requestNotificationPermission() } }
                    }

                if settings.quotaNotificationsEnabled {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach($thresholdRules) { $rule in
                            HStack(spacing: 6) {
                                Image(systemName: "bell.badge")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                    .accessibilityHidden(true)
                                TextField("", text: Binding(
                                    get: { String(rule.percentage) },
                                    set: { value in
                                        let trimmed = value.trimmingCharacters(in: .whitespaces)
                                        if trimmed.isEmpty {
                                            rule.percentage = 0
                                        } else if let percentage = Int(trimmed) {
                                            rule.percentage = percentage
                                        }
                                    }
                                ))
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .monospacedDigit()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 52)
                                    .focused($focusedThresholdID, equals: rule.id)
                                    .onSubmit(normalizeThresholds)
                                    .accessibilityIdentifier("allowance-threshold-field")
                                    .accessibilityLabel("Remaining percentage")
                                    .help("Percentage remaining")
                                Text("% remaining")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    removeThreshold(rule.id)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Remove this alert")
                                .accessibilityLabel("Remove \(rule.percentage) percent alert")
                                .disabled(thresholdRules.count == 1)
                            }
                            .frame(minHeight: 32)
                            if rule.id != thresholdRules.last?.id { Divider() }
                        }

                        Divider()
                        Button(action: addThreshold) {
                            Label("Add alert", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, 8)
                        .disabled(thresholdRules.count >= 99)
                    }
                }
            } header: {
                Text("Allowance alerts")
            } footer: {
                if settings.quotaNotificationsEnabled {
                    Text("Each alert is sent once per allowance window and becomes available again after the allowance resets.")
                }
            }

            Section("Task alerts") {
                Toggle("Notify me when a task asks for input or approval", isOn: $settings.attentionNotificationsEnabled)
                    .onChange(of: settings.attentionNotificationsEnabled) { _, enabled in
                        if enabled { Task { _ = await state.requestNotificationPermission() } }
                    }
            }
        }
        .formStyle(.grouped)
        .onChange(of: focusedThresholdID) { oldValue, newValue in
            if oldValue != nil, newValue == nil { normalizeThresholds() }
        }
    }

    private func addThreshold() {
        let preferred = [25, 15, 30, 8, 3, 40, 50, 2, 1]
        let existing = Set(thresholdRules.map(\.percentage))
        let value = preferred.first { !existing.contains($0) }
            ?? (1...99).first { !existing.contains($0) }
        if let value {
            thresholdRules.append(ThresholdRule(percentage: value))
            persistThresholds()
        }
    }

    private func removeThreshold(_ id: UUID) {
        guard thresholdRules.count > 1 else { return }
        thresholdRules.removeAll { $0.id == id }
        persistThresholds()
    }

    private func persistThresholds() {
        settings.notificationThresholds = thresholdRules.map { max(1, min(99, $0.percentage)) }
    }

    private func normalizeThresholds() {
        var seen = Set<Int>()
        thresholdRules = thresholdRules
            .map { rule in
                var normalized = rule
                normalized.percentage = max(1, min(99, normalized.percentage))
                return normalized
            }
            .filter { seen.insert($0.percentage).inserted }
            .sorted { $0.percentage > $1.percentage }
        persistThresholds()
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose Codex Helper"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.executableValidationMessage = "Checking Codex helper…"
            Task { _ = await state.validateAndUseExecutable(url) }
        }
    }

    private var notificationStatusLabel: String {
        switch state.notificationAuthorization {
        case .notDetermined: "Not requested"
        case .denied: "Not allowed"
        case .authorized: "Allowed"
        case .provisional: "Delivered quietly"
        case .unavailable: "Unavailable"
        }
    }
}

#Preview("General Settings") {
    SettingsView(state: DemoData.state())
}
