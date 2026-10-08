import SwiftUI
import Charts
import VisionKit
import AVFoundation

private struct CompanionTaskSelection: Hashable {
    let macID: String
    let taskID: String
}

struct CompanionHome: View {
    private enum Tab: Hashable { case overview, tasks, activity }
    @Bindable var store: CompanionStore
    @State private var selectedAccountID: String?
    @State private var selectedActivityScope: CompanionActivityScope?
    @State private var selectedTab = Tab.overview
    @State private var overviewPath: [CompanionTaskSelection] = []
    @State private var taskPath: [CompanionTaskSelection] = []
    @State private var showsSettings = false
    @State private var pairingFromSettings = false
    @State private var pairingPending = false
    @State private var showsScanner = false
    @State private var scannerError: String?
    @State private var showsPairing = false
    @State private var pairingTask: Task<Void, Never>?
    @State private var scannedLink: String?
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $overviewPath) {
                TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 15)) { context in
                    List {
                        if store.isPreview { Section { Label("Simulator preview", systemImage: "iphone.gen3") } }
                        if store.accounts.isEmpty {
                            if store.links.isEmpty {
                                ContentUnavailableView("Link your Mac", systemImage: "laptopcomputer.and.iphone",
                                    description: Text("Add a viewing link from CodexGauge on your Mac to see usage and tasks."))
                                Button("Link a Mac") { showsPairing = true }
                            } else {
                                ContentUnavailableView("Waiting for usage", systemImage: "gauge.with.needle",
                                    description: Text("Keep CodexGauge running and connected to Codex on your Mac. Task updates can arrive before account usage."))
                            }
                        }
                        accountPickerSection
                        allowanceSections(now: context.date)
                        activeSections(now: context.date, accountID: selectedAccount?.id)
                    }
                }
                .contentMargins(.top, 8, for: .scrollContent)
                .listSectionSpacing(.compact)
                .navigationTitle("Overview")
                .navigationDestination(for: CompanionTaskSelection.self) { selection in
                    CompanionTaskDetail(store: store, macID: selection.macID, taskID: selection.taskID, onSettings: { showsSettings = true })
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Settings", systemImage: "gearshape") { showsSettings = true } }
            }.tabItem { Label("Overview", systemImage: "gauge.with.needle") }.tag(Tab.overview)
            NavigationStack(path: $taskPath) {
                TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 15)) { context in
                    List {
                        activeSections(now: context.date)
                        if store.orderedSnapshots.flatMap(\.activeTasks).isEmpty {
                            ContentUnavailableView("No active tasks", systemImage: "checkmark.circle",
                                description: Text("Working tasks and requests for input or approval appear here."))
                        }
                    }
                }.contentMargins(.top, 8, for: .scrollContent).listSectionSpacing(.compact)
                .navigationTitle("Tasks").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Settings", systemImage: "gearshape") { showsSettings = true } }
                .navigationDestination(for: CompanionTaskSelection.self) { selection in
                    CompanionTaskDetail(store: store, macID: selection.macID, taskID: selection.taskID, onSettings: { showsSettings = true })
                }
            }.tabItem { Label("Tasks", systemImage: "bubble.left.and.bubble.right") }.tag(Tab.tasks)
            NavigationStack {
                TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 15)) { context in
                List {
                    activityScopeSection(now: context.date)
                    if let account = activityAccount {
                        Section {
                            if let total = account.lifetimeTokens { LabeledContent("Lifetime tokens", value: total.formatted()) }
                            if activityScope?.accountID == CompanionMerge.allAccountsID {
                                let unknown = store.accounts.filter { !$0.hasVerifiedIdentity }.count
                                if unknown > 0 { Text("Totals exclude \(unknown) Mac account\(unknown == 1 ? "" : "s") with unverified identity.").font(.footnote).foregroundStyle(.secondary) }
                            }
                            CompanionAccountChart(account: account).equatable()
                            accountMetrics(account.metrics)
                            if account.historyObservedAt == nil && account.hasHistoryEvidence {
                                Text("History observation time unavailable").font(.caption).foregroundStyle(.secondary)
                            } else if let observed = account.historyObservedAt, context.date.timeIntervalSince(observed) >= 1800 {
                                Text("Last known activity · updated \(observed.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            }
                        } header: { activityHeader(now: context.date) }
                    }
                    if store.accounts.isEmpty { ContentUnavailableView("No activity yet", systemImage: "chart.bar") }
                }
                }.contentMargins(.top, 8, for: .scrollContent).listSectionSpacing(.compact)
                .navigationTitle("Activity").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Settings", systemImage: "gearshape") { showsSettings = true } }
            }.tabItem { Label("Activity", systemImage: "chart.xyaxis.line") }.tag(Tab.activity)

        }
        .onChange(of: activityChoices) { _, choices in
            selectedActivityScope = CompanionActivityScope.resolve(selectedActivityScope, in: choices)
        }
        .onChange(of: store.accounts.map(\.id)) { _, ids in
            if ids.count <= 1 || (selectedAccountID != nil && selectedAccountID != CompanionMerge.allAccountsID && !ids.contains(selectedAccountID!)) {
                selectedAccountID = ids.first
            }
        }
        .sheet(isPresented: $showsSettings, onDismiss: {
            if pairingPending { pairingPending = false; showsPairing = true }
        }) { settingsView }
        .onChange(of: CompanionPush.shared.pendingRoute, initial: true) { _, route in
            guard let route else { return }
            CompanionPush.shared.pendingRoute = nil
            guard route.isLinked(in: store.links) else { return }
            if let taskID = route.taskID {
                taskPath = [CompanionTaskSelection(macID: route.macID, taskID: taskID)]
                selectedTab = .tasks
            } else { overviewPath = []; selectedTab = .overview }
        }
        .onOpenURL { url in
            if url.scheme == "codexgauge", url.host == "tasks" {
                let macID = url.lastPathComponent.lowercased()
                guard store.links.contains(where: { $0.id == macID }) else { return }
                let taskID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "task" })?.value
                guard taskID.map({ !$0.isEmpty && $0.utf16.count <= 200 }) ?? true else { return }
                taskPath = taskID.map { [CompanionTaskSelection(macID: macID, taskID: $0)] } ?? []
                selectedTab = .tasks
                return
            }
            Task {
            await store.add(url)
            if store.error != nil {
                showsPairing = true
            } else {
                overviewPath = []; selectedTab = .overview
                showsPairing = false
            }
            }
        }
        .alert("Couldn’t unlink Mac", isPresented: Binding(
            get: { store.unlinkError != nil }, set: { if !$0 { store.unlinkError = nil } }
        )) {
            Button("OK", role: .cancel) { store.unlinkError = nil }
        } message: { Text(store.unlinkError ?? "") }
        .sheet(isPresented: $showsPairing, onDismiss: {
            if pairingFromSettings { pairingFromSettings = false; showsSettings = true }
        }) {
            pairingView
        }
    }
    private var pairingView: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Scan QR code", systemImage: "qrcode.viewfinder") { Task { await beginScan() } }
                        .disabled(store.isPairing)
                    PasteButton(payloadType: String.self) { strings in connectPairingLink(strings.first ?? "") }
                        .labelStyle(.titleAndIcon).disabled(store.isPairing)
                        .accessibilityLabel("Paste pairing link")
                        .accessibilityIdentifier("companion.pasteLink")
                } footer: {
                    Text("On your Mac, open CodexGauge Settings → Devices → Pair iPhone. Scan the code or copy its link and tap Paste.")
                }
                if store.isPairing {
                    Section { ProgressView("Connecting to Mac…") }
                }
                if let error = store.error ?? scannerError {
                    Section { Text(error).foregroundStyle(.red).lineLimit(nil).fixedSize(horizontal: false, vertical: true) }
                }
                Section {
                    Text("This gives your iPhone read-only access to account email, usage and task names.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Link a Mac").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { pairingTask?.cancel(); showsPairing = false }
                }
            }
        }.presentationDetents([.medium, .large])
        .sheet(isPresented: $showsScanner, onDismiss: {
            if let scannedLink { self.scannedLink = nil; connectPairingLink(scannedLink) }
        }) {
            NavigationStack {
                CompanionQRScanner(onError: { message in
                    scannerError = message; showsScanner = false
                }) { code in
                    scannedLink = code; showsScanner = false
                }.ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan pairing code").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showsScanner = false } } }
            }
        }
    }
    private func connectPairingLink(_ text: String) {
        guard !store.isPairing else { return }
        scannerError = nil; store.error = nil
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              (try? CompanionLink(url: url)) != nil else {
            store.error = "That isn’t a CodexGauge pairing link. Copy a new link from Pair iPhone on your Mac, then tap Paste."; return
        }
        pairingTask = Task {
            await store.add(url)
            guard !Task.isCancelled else { return }
            if store.error == nil { showsPairing = false }
        }
    }
    @MainActor private func beginScan() async {
        store.error = nil
        guard DataScannerViewController.isSupported else { scannerError = "QR scanning isn’t available on this device. Tap Paste instead."; return }
        var allowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
        guard allowed, DataScannerViewController.isAvailable else { scannerError = "Camera access is unavailable. Allow Camera in iPhone Settings or paste the viewing link."; return }
        scannerError = nil; showsScanner = true
    }
    private var settingsView: some View {
            NavigationStack {
                List {
                    Section("Linked Macs") {
                        ForEach(store.links) { link in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(store.snapshots[link.id]?.name ?? link.name)
                                Text(store.removingLinks.contains(link.id) ? "Unlinking…" : store.connectionStatus[link.id] ?? "Disconnected")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.swipeActions {
                                Button("Remove", role: .destructive) { Task { await store.remove(link) } }
                                    .disabled(store.removingLinks.contains(link.id))
                            }
                        }
                        Button("Link a Mac", systemImage: "plus") {
                            store.error = nil; pairingFromSettings = true; pairingPending = true; showsSettings = false
                        }
                    }
                    Section("Alerts") {
                        ForEach(CompanionPush.choices, id: \.0) { kind, title in
                            Toggle(title, isOn: Binding(get: { CompanionPush.shared.kinds.contains(kind) }, set: { value in
                                Task { await CompanionPush.shared.set(kind, enabled: value) }
                            }))
                        }
                        if !CompanionPush.shared.kinds.isEmpty && CompanionPush.shared.status != "Enabled" {
                            Text(CompanionPush.shared.status).font(.caption).foregroundStyle(.secondary)
                        }

                    }
                    Section("Live Activities") {
                        Toggle("Follow active tasks", isOn: Binding(get: { CompanionLiveActivities.shared.enabled }, set: { CompanionLiveActivities.shared.setEnabled($0) }))
                    }
                    Section {
                        Text("Viewing links disclose account email and grant read-only access. They cannot send instructions or approve actions on a Mac.")
                        Text("A Mac must be awake and running CodexGauge to provide fresh data.")
                        Text("Shows local Codex tasks. Cloud-only Work chats and live compaction status aren’t available.")
                    }.font(.footnote).foregroundStyle(.secondary)
                }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsSettings = false } } }
            }
    }
    @ViewBuilder private func accountMetrics(_ metrics: CompanionAccountMetrics?) -> some View {
        if let metrics {
            if let value = metrics.peakDailyTokens { LabeledContent("Peak day", value: value.formatted() + " tokens") }
            if let value = metrics.currentStreakDays { LabeledContent("Current streak", value: "\(value) days") }
            if let value = metrics.longestStreakDays { LabeledContent("Longest streak", value: "\(value) days") }
            if let value = metrics.longestTurnSeconds { LabeledContent("Longest turn", value: CompanionTime.duration(Double(value))) }
        }
    }
    private var showsAllAccounts: Bool { selectedAccountID == CompanionMerge.allAccountsID && store.accounts.count > 1 }
    private var selectedAccount: CompanionAccount? {
        if showsAllAccounts { return CompanionMerge.combinedActivity(store.accounts) }
        return store.accounts.first { $0.id == selectedAccountID } ?? store.accounts.first
    }
    private func selectorLabel(_ account: CompanionAccount) -> String {
        let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let email, !email.isEmpty else { return "\(account.displayName) · \(account.id.suffix(6))" }
        let repeated = store.accounts.filter { $0.displayName == account.displayName }.count > 1
        return repeated ? "\(email) · \(account.id.suffix(6))" : email
    }
    @ViewBuilder private var accountPickerSection: some View {
        if store.accounts.count > 1, let account = selectedAccount {
            Section {
                Picker("Account", selection: Binding(get: { selectedAccount?.id ?? account.id }, set: { selectedAccountID = $0 })) {
                    Text("All accounts").tag(CompanionMerge.allAccountsID)
                    ForEach(store.accounts) { item in Text(selectorLabel(item)).tag(item.id) }
                }.pickerStyle(.menu).accessibilityIdentifier("companion.accountSelector")
            }
        }
    }
    private var activityChoices: [CompanionActivityScope] { store.activityChoices }
    private var activityScope: CompanionActivityScope? { CompanionActivityScope.resolve(selectedActivityScope ?? selectedAccountID.map { .init(accountID: $0, deviceID: nil) }, in: activityChoices) }
    private var activityAccount: CompanionAccount? { activityScope?.account(in: store.orderedSnapshots) }
    private func scopeLabel(_ scope: CompanionActivityScope) -> String {
        scope.label(in: store.orderedSnapshots)
    }
    @ViewBuilder private func activityScopeSection(now: Date) -> some View {
        if let scope = activityScope, activityChoices.count > 1 {
            Section {
                Picker("Account and device", selection: Binding(get: { scope }, set: { selectedActivityScope = $0 })) {
                    if store.accounts.count > 1 {
                        Text("All accounts").tag(CompanionActivityScope(accountID: CompanionMerge.allAccountsID, deviceID: nil))
                    }
                    ForEach(activityChoices) { item in Text(scopeLabel(item)).tag(item) }
                }.pickerStyle(.menu).accessibilityIdentifier("companion.activityScopeSelector")
            }
        }
    }
    @ViewBuilder private func activityHeader(now: Date) -> some View {
        if let scope = activityScope, let account = activityAccount {
            let mac = store.snapshots[scope.deviceID ?? ""]
            CompanionDeviceHeader(name: mac?.name ?? (scope.accountID == CompanionMerge.allAccountsID ? "All devices" : "All devices for this account"), account: account.displayName)
                .accessibilityIdentifier("companion.activityDevice")
            if mac?.isStale(at: now) == true { Text("Device offline or no recent update").font(.caption).textCase(nil) }
        }
    }
    @ViewBuilder private func allowanceSections(now: Date) -> some View {
        ForEach(showsAllAccounts ? store.accounts : selectedAccount.map { [$0] } ?? []) { account in
            Section {
                ForEach(account.windows) { window in
                    NavigationLink(destination: CompanionLimitsDetail(store: store, accountID: account.id, selectedID: window.id)) {
                        AllowanceRow(window: window, now: now)
                    }
                }
                if let resets = account.bankedResets { LabeledContent("Limit resets", value: "\(resets)") }
                ForEach(account.credits ?? []) { credit in
                    LabeledContent((account.credits?.count ?? 0) > 1 ? "\(credit.name) credits" : "Credits available", value: credit.displayBalance)
                }
                CompanionAccountIdentity(account: account)
            } header: {
                Text("Allowances")
            } footer: {
                if account.isStale(at: now) { Text("Last known usage · updated \(account.observedAt.formatted(date: .abbreviated, time: .shortened))") }
            }
        }
    }
    @ViewBuilder private func activeSections(now: Date, accountID: String? = nil) -> some View {
        ForEach(store.orderedSnapshots.filter { accountID == nil || accountID == CompanionMerge.allAccountsID || $0.account?.id == accountID }) { mac in
            if !mac.activeTasks.isEmpty {
                Section {
                    ForEach(mac.activeTasks) { task in
                        NavigationLink(value: CompanionTaskSelection(macID: mac.id, taskID: task.id)) {
                            TaskRow(task: task, stale: mac.isStale(at: now) || task.isStale(at: now), snapshotObservedAt: mac.observedAt)
                        }
                    }
                } header: {
                    CompanionDeviceHeader(name: mac.name, account: mac.account?.displayName)
                        .accessibilityIdentifier("companion.taskDevice.\(mac.id)")
                }
                  footer: { if mac.isStale(at: now) { Text("Mac offline or no recent update · showing last known tasks") } }
            }
        }
    }
}

struct AllowanceRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let window: CompanionWindow
    let now: Date
    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 16))
        layout {
            Gauge(value: Double(window.remainingPercent), in: 0...100) {
                Text(window.name)
            } currentValueLabel: { Image(systemName: "gauge.with.needle") }
                .gaugeStyle(.accessoryCircularCapacity).tint(window.remainingPercent <= 10 ? .orange : .blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(window.name).font(.headline)
                if let reset = window.resetsAt {
                    Text(reset > now ? "Resets \(reset.formatted(.relative(presentation: .numeric)))" : "Reset awaiting confirmation")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            Text("\(window.remainingPercent)%").font(.title2.weight(.semibold)).monospacedDigit()
        }.padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(window.name), \(window.remainingPercent) percent remaining")
            .accessibilityValue(window.resetsAt.map { $0 > now ? "Resets \($0.formatted())" : "Reset awaiting confirmation" } ?? "")
    }
}

/// Resolve identifiers against the observable store so an open detail follows
/// subsequent snapshots, including completion after it leaves the active list.
struct CompanionTaskDetail: View {
    @Bindable var store: CompanionStore
    let macID: String
    let taskID: String
    var onSettings: (() -> Void)? = nil
    @ViewBuilder private func metric(_ title: String, _ value: Int64?) -> some View {
        if let value { LabeledContent(title, value: value.formatted()) }
    }
    var body: some View {
        TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 15)) { context in
            if let mac = store.snapshots[macID], let task = mac.tasks.first(where: { $0.id == taskID }) {
                List {
                    Section {
                        TaskRow(task: task, compact: false, stale: mac.isStale(at: context.date) || task.isStale(at: context.date), snapshotObservedAt: mac.observedAt)
                        LabeledContent("Mac", value: mac.name)
                    }
                    Section {
                        LabeledContent("Recorded tokens", value: task.hasTokenObservation == true || task.totalTokens > 0 ? task.totalTokens.formatted() : "Unavailable")

                        LabeledContent("Linked agents", value: "\(task.agentCount)")
                        if let m = task.metrics {
                            if let value = m.model { LabeledContent("Model", value: value) }
                            if let value = m.fiveMinuteRate { LabeledContent("Five-minute pace", value: "\(Int(value).formatted()) tok/min") }
                            if let value = m.callsPerMinute { LabeledContent("Model calls", value: "\(value.formatted(.number.precision(.fractionLength(0...1)))) / min") }
                            if let value = m.latestOutput { LabeledContent("Latest output", value: value.formatted() + " tokens") }
                            if let value = m.firstTokenMilliseconds { LabeledContent("Began responding", value: "\((Double(value) / 1000).formatted(.number.precision(.fractionLength(0...2)))) sec") }
                            if let value = m.lastTurnSeconds { LabeledContent("Last turn", value: CompanionTime.duration(value)) }
                            DisclosureGroup("Recorded token mix · last five minutes") {
                                metric("Input", m.input); metric("Cached input", m.cachedInput); metric("Cache write", m.cacheWriteInput)
                                metric("Output", m.output); metric("Reasoning output", m.reasoning)
                            }
                        }
                    } header: { Text("Statistics") }
                    footer: {
                        if task.metrics?.contextIncludesAgent == true { Text("Phase, model, context and elapsed describe the active linked agent.") }
                        Text(task.metrics?.tokenTotalsComplete == false ? "Some linked tasks have no token usage yet; totals are incomplete." : "Includes linked agents.")
                    }
                    Section {
                        CompanionRateChart(samples: store.taskHistory.samples(mac: macID, task: taskID).filter { context.date.timeIntervalSince($0.date) <= 300 },
                            isCollecting: task.state == .running && task.hasRate && !task.isStale(at: context.date) && !mac.isStale(at: context.date))
                    } header: { Text("Tokens per minute") }
                    footer: { Text("Last five minutes · gaps show unavailable data.") }
                    if mac.isStale(at: context.date) {
                        Section { Text("Mac offline or no recent update · showing last known task").foregroundStyle(.secondary) }
                    } else if task.isStale(at: context.date) {
                        Section { Text("Mac connected · no recent task update. Showing the last known state.").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            } else if store.snapshots[macID] == nil && store.links.contains(where: { $0.id == macID }) {
                ContentUnavailableView("Waiting for task", systemImage: "bubble.left",
                    description: Text("Reconnect to the Mac’s feed to load this task’s latest update."))
            } else {
                ContentUnavailableView("Task unavailable", systemImage: "bubble.left",
                    description: Text("This task is no longer included in the Mac’s latest update."))
            }
        }
        .navigationTitle("Task").navigationBarTitleDisplayMode(.inline)
        .toolbar { if let onSettings { Button("Settings", systemImage: "gearshape", action: onSettings) } }
    }
}

struct TaskRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let task: CompanionTask
    var compact = true
    var stale = false
    var snapshotObservedAt: Date? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).font(.headline).lineLimit(compact && !dynamicTypeSize.isAccessibilitySize ? 2 : nil)
                    let metadata = [task.project, task.metrics?.model].compactMap { $0 }.joined(separator: " · ")
                    if !metadata.isEmpty { Text(metadata).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                if task.state == .running && !stale && task.hasRate {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(task.tokensPerMinute.formatted(.number.precision(.fractionLength(0)))).font(.subheadline.weight(.semibold)).monospacedDigit()
                        Text("tokens/min").font(.caption2).foregroundStyle(.secondary)
                    }.fixedSize().accessibilityElement(children: .combine)
                }
            }
            let metricsLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            metricsLayout {
                phase
                HStack(spacing: 12) { contextAndTime }
            }.font(.caption).foregroundStyle(.secondary)
            if !task.hasRate && task.state == .running { Text("No token observation").font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 6)
    }
    private var phase: some View {
        HStack(spacing: 5) {
            if task.state == .running && !stale { CompanionWorkingIndicator().accessibilityIdentifier("companion.workingIndicator.\(task.id)").accessibilityHidden(true) }
            else { Image(systemName: task.state.symbol).accessibilityHidden(true) }
            Text(stale ? "Last seen: \(task.state.title.lowercased())" : task.state == .running ? task.displayActivity : task.state.title)
                .foregroundStyle(task.state == .needsApproval || task.state == .needsInput ? Color.orange : Color.secondary)
        }
    }
    @ViewBuilder private var contextAndTime: some View {
        if let value = task.contextPercent {
            HStack(spacing: 4) {
                Image(systemName: "circle.dashed").accessibilityHidden(true)
                Text("\(Int(value))% \(task.metrics?.contextIncludesAgent == true ? "agent context" : "context")").monospacedDigit()
                    .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
            }.accessibilityElement(children: .combine)
        }
        if let start = task.startedAt {
            if task.state == .completed {
                if let duration = task.metrics?.lastTurnSeconds { Label(CompanionTime.duration(duration), systemImage: "clock") }
                else { Label("Elapsed unavailable", systemImage: "clock") }
            } else if stale {
                if let elapsed = CompanionTaskTiming.observedElapsed(start: start, task: task.observedAt, snapshot: snapshotObservedAt) {
                    Label(CompanionTime.duration(elapsed), systemImage: "clock")
                } else { Label("Elapsed unavailable", systemImage: "clock") }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    CompanionElapsedClock(start: start).fixedSize()
                }.accessibilityLabel("Current turn elapsed")
            }
        }
    }
}

/// A native progress view can stop drawing after its list is detached by a tab
/// switch. Keep the glyph in SwiftUI and animate only its transform.
private struct CompanionWorkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false
    var body: some View {
        Circle().trim(from: 0.12, to: 0.9)
            .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(rotating && !reduceMotion ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: rotating)
            .onAppear { rotating = true }
            .onDisappear { rotating = false }
    }
}


/// Keep the clock's one-second refresh inside its text. In a fitting layout,
/// the system interval text can continually invalidate the list on iOS 27.
private struct CompanionElapsedClock: View {
    let start: Date
    var body: some View {
        TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(start))
            Text(Duration.seconds(elapsed).formatted(.time(pattern: elapsed >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                .monospacedDigit()
        }
    }
}

private struct CompanionLimitsDetail: View {
    @Bindable var store: CompanionStore
    let accountID: String
    let selectedID: String
    var body: some View {
        TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 15)) { context in
            List {
                if let account = store.accounts.first(where: { $0.id == accountID }) {
                    ForEach(account.windows.sorted { ($0.id == selectedID ? 0 : 1) < ($1.id == selectedID ? 0 : 1) }) { window in
                        Section(window.name) {
                            LabeledContent("Remaining", value: "\(window.remainingPercent)%")
                            LabeledContent("Used", value: "\(100 - window.remainingPercent)%")
                            if let reset = window.resetsAt { LabeledContent("Next reset", value: reset.formatted(date: .abbreviated, time: .shortened)) }
                        }
                    }
                    if let banked = account.bankedResets { LabeledContent("Limit resets", value: "\(banked)") }
                    ForEach(account.credits ?? []) { credit in LabeledContent(credit.name + " credits", value: credit.displayBalance) }
                    Section {
                        CompanionAccountIdentity(account: account)
                    } footer: {
                        Text("Updated \(account.observedAt.formatted(date: .abbreviated, time: .shortened))")
                        if account.isStale(at: context.date) { Text("Last known usage · waiting for an update") }
                    }
                } else { ContentUnavailableView("Usage unavailable", systemImage: "gauge.with.needle") }
            }
        }.navigationTitle("Limits").navigationBarTitleDisplayMode(.inline)
    }
}

private struct CompanionQRScanner: UIViewControllerRepresentable {
    let onError: (String) -> Void
    let onScan: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onError: onError, onScan: onScan) }
    func makeUIViewController(context: Context) -> ScannerHost {
        ScannerHost(coordinator: context.coordinator)
    }
    func updateUIViewController(_ controller: ScannerHost, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerHost, coordinator: Coordinator) {
        controller.stopScanning()
    }

    // The representable is created before its sheet joins a window. Let UIKit
    // finish presenting the scanner before starting its camera and recognition.
    @MainActor final class ScannerHost: UIViewController {
        private let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        private let coordinator: Coordinator
        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
            scanner.delegate = coordinator
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(scanner)
            scanner.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(scanner.view)
            NSLayoutConstraint.activate([
                scanner.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scanner.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scanner.view.topAnchor.constraint(equalTo: view.topAnchor),
                scanner.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            scanner.didMove(toParent: self)
            NotificationCenter.default.addObserver(self, selector: #selector(resumeScanning), name: UIApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(stopScanning), name: UIApplication.willResignActiveNotification, object: nil)
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            resumeScanning()
        }
        override func viewWillDisappear(_ animated: Bool) {
            stopScanning()
            super.viewWillDisappear(animated)
        }
        @objc private func resumeScanning() {
            guard viewIfLoaded?.window != nil, !coordinator.handled, !scanner.isScanning,
                  UIApplication.shared.applicationState == .active else { return }
            do { try scanner.startScanning() }
            catch { coordinator.fail("Scanning couldn’t start. Paste the viewing link instead.") }
        }
        @objc func stopScanning() { scanner.stopScanning() }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private(set) var handled = false
        let onError: (String) -> Void
        init(onError: @escaping (String) -> Void, onScan: @escaping (String) -> Void) { self.onError = onError; self.onScan = onScan }
        func fail(_ message: String) {
            guard !handled else { return }
            handled = true
            onError(message)
        }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            fail("Scanning is unavailable. Paste the viewing link instead.")
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            recognize(allItems, using: dataScanner)
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            recognize(allItems, using: dataScanner)
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            recognize([item], using: dataScanner)
        }
        private func recognize(_ items: [RecognizedItem], using scanner: DataScannerViewController) {
            guard !handled else { return }
            for item in items {
                if case .barcode(let barcode) = item, let code = barcode.payloadStringValue, !code.isEmpty {
                    handled = true
                    scanner.stopScanning()
                    onScan(code)
                    return
                }
            }
        }
    }
}

private enum CompanionTime {
    static func duration(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .hourMinuteSecond))
    }
}

private struct CompanionAccountIdentity: View {
    let account: CompanionAccount
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.displayName).font(.caption).textSelection(.enabled)
                .accessibilityIdentifier("companion.accountIdentity")
            if !account.detail.isEmpty { Text(account.detail).font(.caption2) }
        }.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct CompanionDeviceHeader: View {
    let name: String
    let account: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(name, systemImage: "laptopcomputer").font(.subheadline.weight(.semibold))
            if let account { Text(account).font(.caption) }
        }.textCase(nil)
    }
}
