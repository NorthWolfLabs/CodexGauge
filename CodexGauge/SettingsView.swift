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
    @State private var confirmsMenuBarReset = false
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
            case .menuBar: menuBar
            case .notifications: notifications
            }
        }
        .frame(width: 600, height: 430)
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
            Section("Allowance updates") {
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
                Text("This controls only how often CodexGauge checks account allowances. Live tasks update automatically as work happens on this Mac.")
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

    private var menuBar: some View {
        Form {
            Section("Preview") {
                menuBarPreview
            }

            Section {
                Toggle("Show gauge icon", isOn: gaugeVisibilityBinding)
                    .accessibilityIdentifier("menu-bar-show-gauge")
                    .help("Show or hide the gauge symbol in the menu bar.")
                Toggle("Show remaining percentage", isOn: percentageVisibilityBinding)
                    .accessibilityIdentifier("menu-bar-show-percentage")
                    .help("Show the remaining percentage for the selected allowance.")

                if shouldShowPrimaryAllowance {
                    Picker(primaryAllowancePickerLabel, selection: primaryAllowanceBinding) {
                        ForEach(primaryAllowanceOptions) { option in
                            Text(option.title).tag(option.selection)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("menu-bar-primary-allowance")
                    .help("Choose the allowance used for the main percentage, reset timing, suggested pace, and status.")
                }

                if settings.menuBarConfiguration.showsPercentage {
                    Picker("Additional percentage", selection: secondaryAllowanceBinding) {
                        Text("Hidden").tag(nil as AllowanceSelection?)
                        ForEach(secondaryAllowanceOptions) { option in
                            Text(option.title).tag(option.selection as AllowanceSelection?)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("menu-bar-secondary-allowance")
                    .help("Optionally show one more allowance percentage after the main percentage.")
                }

                Picker("Reset timing", selection: menuBarBinding(\.resetDisplay)) {
                    ForEach(ResetDisplayStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("menu-bar-reset-style")
                .help("Show when the selected allowance resets as a countdown, a date, or both.")

                Toggle("Show suggested pace", isOn: menuBarBinding(\.showsSuggestedPace))
                    .disabled(!primarySupportsSuggestedPace && !settings.menuBarConfiguration.showsSuggestedPace)
                    .accessibilityIdentifier("menu-bar-show-pace")
                    .help("Show a local estimate for spreading this allowance evenly until it resets.")

                if settings.menuBarConfiguration.showsSuggestedPace {
                    Picker("Pace display", selection: menuBarBinding(\.suggestedPaceDisplay)) {
                        ForEach(SuggestedPaceDisplayStyle.allCases, id: \.self) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("menu-bar-pace-display")
                    .help("Available per Day or Hour shows percentage points you can use at an even pace. Remaining Target shows where the allowance should be at the end of the current allowance day or hour.")
                }

                if !primarySupportsSuggestedPace {
                    Text("Suggested pace is available for allowances lasting at least one day with a known reset time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if menuBarPresentation.primarySelectionUnavailable {
                    Label(
                        "The selected primary allowance is currently unavailable. The most constrained Codex allowance is shown instead.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("menu-bar-primary-fallback")
                }
                if menuBarPresentation.secondarySelectionUnavailable {
                    Label(
                        "The selected additional allowance is currently unavailable. CodexGauge temporarily uses the most constrained Codex allowance when it does not duplicate the primary.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("menu-bar-secondary-fallback")
                }
            } header: {
                Text("Contents")
            } footer: {
                if settings.menuBarConfiguration.showsPercentage {
                    Text("The main allowance also supplies reset timing, suggested pace, and status colors.")
                } else if shouldShowPrimaryAllowance {
                    Text("The reference allowance supplies reset timing, suggested pace, and status colors. Its percentage remains hidden.")
                } else {
                    Text("At least one menu-bar item stays visible.")
                }
            }

            Section("Status colors") {
                Picker("Color", selection: menuBarBinding(\.colorMode)) {
                    ForEach(StatusColorMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("menu-bar-color-mode")

                if settings.menuBarConfiguration.colorMode != .off {
                    Picker("Based on", selection: menuBarBinding(\.colorBasis)) {
                        ForEach(StatusColorBasis.allCases, id: \.self) { basis in
                            Text(basis.title).tag(basis)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("menu-bar-color-basis")
                    .help(statusColorBasisHelp)

                    if canChooseColorTarget {
                        Picker("Apply color to", selection: menuBarBinding(\.colorTarget)) {
                            ForEach(StatusColorTarget.allCases, id: \.self) { target in
                                Text(target.title).tag(target)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("menu-bar-color-target")
                        .help("Choose whether status color appears on the gauge, the displayed values, or both.")
                    }

                    Text(statusColorExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Restore Defaults…") {
                    confirmsMenuBarReset = true
                }
                .accessibilityIdentifier("menu-bar-restore-defaults")
            }
        }
        .formStyle(.grouped)
        .alert("Restore Menu Bar Defaults?", isPresented: $confirmsMenuBarReset) {
            Button("Cancel", role: .cancel) {}
            Button("Restore", role: .destructive) {
                settings.restoreMenuBarDefaults()
            }
        } message: {
            Text("This resets all menu-bar content, timing, pace, and color choices.")
        }
    }

    private var menuBarPreview: some View {
        let presentation = menuBarPresentation
        return HStack(spacing: 5) {
            if let symbol = presentation.symbolName {
                Image(systemName: symbol)
                    .foregroundStyle(previewColor(presentation.symbolSeverity))
                    .accessibilityHidden(true)
            }
            HStack(spacing: 0) {
                ForEach(Array(presentation.segments.enumerated()), id: \.offset) { _, segment in
                    Text(segment.text)
                        .font(segment.usesMonospacedDigits ? .body.monospacedDigit() : .body)
                        .foregroundStyle(previewColor(segment.severity))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier("menu-bar-preview")
    }

    private var menuBarPresentation: MenuBarPresentation {
        MenuBarPresentationBuilder.make(
            snapshot: state.accountSnapshot,
            freshness: state.displayFreshness,
            configuration: settings.menuBarConfiguration,
            now: .now
        )
    }

    private var primaryAllowanceOptions: [AllowanceOption] {
        options(including: settings.menuBarConfiguration.primaryAllowance)
    }

    private var secondaryAllowanceOptions: [AllowanceOption] {
        let primaryID = AllowanceResolver.resolve(
            settings.menuBarConfiguration.primaryAllowance,
            in: state.accountSnapshot
        )?.id
        return options(including: settings.menuBarConfiguration.secondaryAllowance).filter { option in
            guard option.selection != settings.menuBarConfiguration.secondaryAllowance else { return true }
            guard let primaryID else { return true }
            return AllowanceResolver.resolve(option.selection, in: state.accountSnapshot)?.id != primaryID
        }
    }

    private func options(including selection: AllowanceSelection?) -> [AllowanceOption] {
        var options = AllowanceResolver.options(in: state.accountSnapshot)
        if let selection, !options.contains(where: { $0.selection == selection }) {
            options.append(AllowanceOption(selection: selection, title: "Previous Selection · Unavailable"))
        }
        return options
    }

    private var primarySupportsSuggestedPace: Bool {
        let selected = AllowanceResolver.resolve(settings.menuBarConfiguration.primaryAllowance, in: state.accountSnapshot)
            ?? AllowanceResolver.limitingCodex(in: state.accountSnapshot)
        guard let window = selected?.window else { return false }
        return (window.durationMinutes ?? 0) >= 1_440 && window.resetsAt != nil
    }

    private var shouldShowPrimaryAllowance: Bool {
        let configuration = settings.menuBarConfiguration
        return configuration.showsPercentage
            || configuration.resetDisplay != .hidden
            || configuration.showsSuggestedPace
            || configuration.colorMode != .off
    }

    private var primaryAllowancePickerLabel: String {
        settings.menuBarConfiguration.showsPercentage ? "Main percentage" : "Reference allowance"
    }

    private var canChooseColorTarget: Bool {
        let configuration = settings.menuBarConfiguration
        return configuration.showsGauge && configuration.hasConfiguredTextContent
    }

    private var statusColorExplanation: String {
        let configuration = settings.menuBarConfiguration
        switch configuration.colorMode {
        case .off:
            return ""
        case .warningsOnly:
            return "Color appears only when the selected allowance needs attention."
        case .trafficLight:
            return "Green, yellow, and red show the selected allowance’s status."
        }
    }

    private var statusColorBasisHelp: String {
        switch settings.menuBarConfiguration.colorBasis {
        case .remainingAllowance:
            return "Yellow appears at 20% remaining and red at 10% remaining."
        case .usagePace:
            return "Yellow appears when projected usage reaches 90% by reset. Red means the allowance may run out before reset. Estimates are hidden immediately after a reset while the available data is too coarse."
        case .combined:
            return "Uses whichever is more urgent: the amount remaining or projected usage through reset. Estimates are hidden immediately after a reset while the available data is too coarse."
        }
    }

    private var gaugeVisibilityBinding: Binding<Bool> {
        Binding(
            get: { settings.menuBarConfiguration.showsGauge },
            set: { shown in
                var configuration = settings.menuBarConfiguration
                configuration.showsGauge = shown
                if !shown, !configuration.hasConfiguredTextContent {
                    configuration.showsPercentage = true
                }
                settings.menuBarConfiguration = configuration
            }
        )
    }

    private var percentageVisibilityBinding: Binding<Bool> {
        Binding(
            get: { settings.menuBarConfiguration.showsPercentage },
            set: { shown in
                var configuration = settings.menuBarConfiguration
                configuration.showsPercentage = shown
                if !shown {
                    if !configuration.showsGauge,
                       configuration.resetDisplay == .hidden,
                       !configuration.showsSuggestedPace {
                        configuration.showsGauge = true
                    }
                }
                settings.menuBarConfiguration = configuration
            }
        )
    }

    private var primaryAllowanceBinding: Binding<AllowanceSelection> {
        Binding(
            get: { settings.menuBarConfiguration.primaryAllowance },
            set: { selection in
                var configuration = settings.menuBarConfiguration
                configuration.primaryAllowance = selection
                if let secondary = configuration.secondaryAllowance,
                   resolvedID(selection) == resolvedID(secondary) {
                    configuration.secondaryAllowance = nil
                }
                settings.menuBarConfiguration = configuration
            }
        )
    }

    private var secondaryAllowanceBinding: Binding<AllowanceSelection?> {
        Binding(
            get: { settings.menuBarConfiguration.secondaryAllowance },
            set: { selection in
                var configuration = settings.menuBarConfiguration
                if let selection, resolvedID(selection) == resolvedID(configuration.primaryAllowance) {
                    configuration.secondaryAllowance = nil
                } else {
                    configuration.secondaryAllowance = selection
                }
                settings.menuBarConfiguration = configuration
            }
        )
    }

    private func resolvedID(_ selection: AllowanceSelection) -> String? {
        AllowanceResolver.resolve(selection, in: state.accountSnapshot)?.id
    }

    private func menuBarBinding<Value>(_ keyPath: WritableKeyPath<MenuBarConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { settings.menuBarConfiguration[keyPath: keyPath] },
            set: { value in
                var configuration = settings.menuBarConfiguration
                configuration[keyPath: keyPath] = value
                settings.menuBarConfiguration = configuration
            }
        )
    }

    private func previewColor(_ severity: MenuBarSeverity) -> Color {
        switch severity {
        case .neutral: .primary
        case .normal: .green
        case .caution: .yellow
        case .critical: .red
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
