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
    @State private var selectedTab = Tab.overview
    @State private var overviewPath: [CompanionTaskSelection] = []
    @State private var taskPath: [CompanionTaskSelection] = []
    @State private var showsSettings = false
    @State private var pairingFromSettings = false
    @State private var pairingPending = false
    @State private var showsScanner = false
    @State private var scannerError: String?
    @State private var showsPairing = false
    @State private var linkText = ""
    @FocusState private var linkFocused: Bool
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $overviewPath) {
                TimelineView(.periodic(from: .now, by: 15)) { context in
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
                        accountIdentitySection
                        allowanceSections(now: context.date)
                        activeSections(now: context.date, accountID: selectedAccount?.id)
                    }
                }
                .navigationTitle("Overview")
                .navigationDestination(for: CompanionTaskSelection.self) { selection in
                    CompanionTaskDetail(store: store, macID: selection.macID, taskID: selection.taskID, onSettings: { showsSettings = true })
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Settings", systemImage: "gearshape") { showsSettings = true } }
            }.tabItem { Label("Overview", systemImage: "gauge.with.needle") }.tag(Tab.overview)
            NavigationStack(path: $taskPath) {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    List {
                        activeSections(now: context.date)
                        if store.orderedSnapshots.flatMap(\.activeTasks).isEmpty {
                            ContentUnavailableView("No active tasks", systemImage: "checkmark.circle",
                                description: Text("Working tasks and requests for input or approval appear here."))
                        }
                    }
                }.navigationTitle("Tasks").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Settings", systemImage: "gearshape") { showsSettings = true } }
                .navigationDestination(for: CompanionTaskSelection.self) { selection in
                    CompanionTaskDetail(store: store, macID: selection.macID, taskID: selection.taskID, onSettings: { showsSettings = true })
                }
            }.tabItem { Label("Tasks", systemImage: "bubble.left.and.bubble.right") }.tag(Tab.tasks)
            NavigationStack {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                List {
                    accountIdentitySection
                    if let account = selectedAccount {
                        Section("Token activity") {
                            if let total = account.lifetimeTokens { LabeledContent("Lifetime tokens", value: total.formatted()) }
                            if showsAllAccounts {
                                let unknown = store.accounts.filter { !$0.hasVerifiedIdentity }.count
                                if unknown > 0 { Text("Totals exclude \(unknown) Mac account\(unknown == 1 ? "" : "s") with unverified identity.").font(.footnote).foregroundStyle(.secondary) }
                            }
                            CompanionAccountChart(account: account)
                            accountMetrics(account.metrics)
                            if account.historyObservedAt == nil && account.hasHistoryEvidence {
                                Text("History observation time unavailable").font(.caption).foregroundStyle(.secondary)
                            } else if let observed = account.historyObservedAt, context.date.timeIntervalSince(observed) >= 1800 {
                                Text("Last known activity · updated \(observed.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if store.accounts.isEmpty { ContentUnavailableView("No activity yet", systemImage: "chart.bar") }
                }
                }.navigationTitle("Activity").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Settings", systemImage: "gearshape") { showsSettings = true } }
            }.tabItem { Label("Activity", systemImage: "chart.xyaxis.line") }.tag(Tab.activity)

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
            store.add(url)
            if store.error != nil {
                linkText = url.absoluteString
                showsPairing = true
            } else {
                overviewPath = []; selectedTab = .overview
                linkText = ""; showsPairing = false
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
                        if let scannerError { Text(scannerError).font(.footnote).foregroundStyle(.secondary) }
                    } footer: { Text("On your Mac, open CodexGauge Settings → General → iPhone companion and show the viewing QR code.") }
                    Section {
                        if let error = store.error { Text(error).foregroundStyle(.red) }
                        TextField("Viewing link", text: $linkText, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL).focused($linkFocused).privacySensitive()
                            .accessibilityIdentifier("companion.viewingLink")
                        PasteButton(payloadType: String.self) { strings in linkText = strings.first ?? "" }
                    } header: { Text("Or paste a viewing link") }
                      footer: { Text("Copy a viewing link from the same Mac settings, then paste it here.") }
                }.navigationTitle("Link a Mac").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showsPairing = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Link Mac") {
                                linkFocused = false
                                guard let url = URL(string: linkText.trimmingCharacters(in: .whitespacesAndNewlines)) else { store.error = "Enter a valid viewing link."; return }
                                store.add(url)
                                if store.error == nil { linkText = ""; showsPairing = false }
                            }.disabled(linkText.isEmpty)
                        }
                    }
            }.presentationDetents([.large])
                .sheet(isPresented: $showsScanner) {
                    NavigationStack {
                        CompanionQRScanner(onError: { message in
                            scannerError = message; showsScanner = false
                        }) { code in
                            showsScanner = false
                            linkText = code
                        }.ignoresSafeArea(edges: .bottom)
                        .navigationTitle("Scan viewing link").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showsScanner = false } } }
                    }
                }
    }
    @MainActor private func beginScan() async {
        guard DataScannerViewController.isSupported else { scannerError = "QR scanning isn’t available on this device. Paste the viewing link below."; return }
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
                        if CompanionPush.shared.status != "Enabled" { Text(CompanionPush.shared.status).font(.caption).foregroundStyle(.secondary) }
                        #if DEBUG
                        NavigationLink("Live Activity layout preview") { CompanionLivePreview() }
                        DisclosureGroup("Notification diagnostics") {
                        Button(CompanionPush.shared.isTesting ? "Sending…" : "Send test notification") {
                            Task { await CompanionPush.shared.sendTest() }
                        }.disabled(!CompanionPush.shared.canSendTest)
                        if let result = CompanionPush.shared.testStatus {
                            Text(result).font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("companion.pushTestResult")
                        }
                        }
                        #endif
                    }
                    Section("Live Activities") {
                        Toggle("Follow active tasks", isOn: Binding(get: { CompanionLiveActivities.shared.enabled }, set: { CompanionLiveActivities.shared.setEnabled($0) }))
                        Text(CompanionLiveActivities.shared.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Text("Viewing links disclose account email and grant read-only access. They cannot send instructions or approve actions on a Mac.")
                        Text("A Mac must be awake and running CodexGauge to provide fresh data.")
                        Text("Tasks are observed from local Codex activity. Cloud-only Work chats and live compaction phases aren’t available through this source.")
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
        guard let email, !email.isEmpty else { return "\(sourceNames(account)) · \(account.id.suffix(6))" }
        let repeated = store.accounts.filter { $0.displayName == account.displayName }.count > 1
        return repeated ? "\(email) · \(sourceNames(account)) · \(account.id.suffix(6))" : email
    }
    @ViewBuilder private var accountIdentitySection: some View {
        if let account = selectedAccount {
            Section {
                if store.accounts.count > 1 {
                    Picker("Account", selection: Binding(get: { selectedAccount?.id ?? account.id }, set: { selectedAccountID = $0 })) {
                        Text("All accounts").tag(CompanionMerge.allAccountsID)
                        ForEach(store.accounts) { item in Text(selectorLabel(item)).tag(item.id) }
                    }.pickerStyle(.menu).accessibilityIdentifier("companion.accountSelector")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.id == CompanionMerge.allAccountsID ? "All accounts" : account.displayName).font(.headline).textSelection(.enabled)
                        .accessibilityIdentifier("companion.accountIdentity")
                    if !account.detail.isEmpty { Text(account.detail).font(.subheadline).foregroundStyle(.secondary) }
                    Text(sourceNames(account)).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
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
                            } header: {
                                Text(showsAllAccounts ? account.displayName : "Allowances")
                            } footer: {
                                if account.isStale(at: now) { Text("Last known usage · updated \(account.observedAt.formatted(date: .abbreviated, time: .shortened))") }
                            }
                            if account.bankedResets != nil || !(account.credits ?? []).isEmpty {
                                Section("Account balances") {
                                if let banked = account.bankedResets { LabeledContent("Banked resets", value: "\(banked)") }
                                ForEach(account.credits ?? []) { credit in
                                    LabeledContent((account.credits?.count ?? 0) > 1 ? "\(credit.name) credits" : "Credits available", value: credit.displayBalance)
                                }
                                }
                            }
                        }
    }
    private func sourceNames(_ account: CompanionAccount) -> String {
        store.orderedSnapshots.filter { account.id == CompanionMerge.allAccountsID || $0.account?.id == account.id }.map(\.name).joined(separator: " · ")
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
                } header: { Label(mac.name, systemImage: "laptopcomputer") }
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
        TimelineView(.periodic(from: .now, by: 15)) { context in
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
                        Text(task.metrics?.tokenTotalsComplete == false ? "Recorded totals and mix are incomplete: some linked tasks have not reported token usage." : "Rates and recorded token totals include linked agents when present.")
                    }
                    Section {
                        CompanionRateChart(samples: store.taskHistory.samples(mac: macID, task: taskID).filter { context.date.timeIntervalSince($0.date) <= 300 },
                            isCollecting: task.state == .running && task.hasRate && !task.isStale(at: context.date) && !mac.isStale(at: context.date))
                    } header: { Text("Tokens per minute") }
                    footer: { Text("Last five minutes observed while this app is connected. Gaps indicate missing observations.") }
                    if mac.isStale(at: context.date) {
                        Section { Text("Mac offline or no recent update · showing last known task").foregroundStyle(.secondary) }
                    } else if task.isStale(at: context.date) {
                        Section { Text("Mac connected · no recent task observation. Its last state is retained until a lifecycle event changes it.").font(.footnote).foregroundStyle(.secondary) }
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { phase; contextAndTime }
                VStack(alignment: .leading, spacing: 6) { phase; contextAndTime }
            }.font(.caption).foregroundStyle(.secondary)
            if !task.hasRate && task.state == .running { Text("No token observation").font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 6)
    }
    private var phase: some View {
        HStack(spacing: 5) {
            if task.state == .running && !stale { ProgressView().controlSize(.mini).accessibilityHidden(true) }
            else { Image(systemName: task.state.symbol).accessibilityHidden(true) }
            Text(stale ? "Last seen: \(task.state.title.lowercased())" : task.state == .running ? task.activity : task.state.title)
                .foregroundStyle(task.state == .needsApproval || task.state == .needsInput ? Color.orange : Color.secondary)
        }
    }
    @ViewBuilder private var contextAndTime: some View {
        if let value = task.contextPercent {
            Label("\(Int(value))% \(task.metrics?.contextIncludesAgent == true ? "agent context" : "context")", systemImage: "circle.dashed")
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
                    Text(timerInterval: start...Date.distantFuture, countsDown: false).monospacedDigit().fixedSize()
                }.accessibilityLabel("Current turn elapsed")
            }
        }
    }
}


private struct CompanionLimitsDetail: View {
    @Bindable var store: CompanionStore
    let accountID: String
    let selectedID: String
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            List {
                if let account = store.accounts.first(where: { $0.id == accountID }) {
                    ForEach(account.windows.sorted { ($0.id == selectedID ? 0 : 1) < ($1.id == selectedID ? 0 : 1) }) { window in
                        Section(window.name) {
                            LabeledContent("Remaining", value: "\(window.remainingPercent)%")
                            LabeledContent("Used", value: "\(100 - window.remainingPercent)%")
                            if let reset = window.resetsAt { LabeledContent("Next reset", value: reset.formatted(date: .abbreviated, time: .shortened)) }
                        }
                    }
                    if let banked = account.bankedResets { LabeledContent("Banked resets", value: "\(banked)") }
                    ForEach(account.credits ?? []) { credit in LabeledContent(credit.name + " credits", value: credit.displayBalance) }
                    Section { Text("Updated \(account.observedAt.formatted(date: .abbreviated, time: .shortened))").font(.footnote).foregroundStyle(.secondary) }
                    if account.isStale(at: context.date) { Text("Last known usage. A reset is confirmed only when the Mac receives a fresh observation.").font(.footnote) }
                } else { ContentUnavailableView("Usage unavailable", systemImage: "gauge.with.needle") }
            }
        }.navigationTitle("Limits").navigationBarTitleDisplayMode(.inline)
    }
}

private struct CompanionQRScanner: UIViewControllerRepresentable {
    let onError: (String) -> Void
    let onScan: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onError: onError, onScan: onScan) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() } catch {
            Task { @MainActor in onError("Scanning couldn’t start. Paste the viewing link instead.") }
        }
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        var handled = false
        let onError: (String) -> Void
        init(onError: @escaping (String) -> Void, onScan: @escaping (String) -> Void) { self.onError = onError; self.onScan = onScan }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            guard !handled else { return }; handled = true; onError("Scanning is unavailable. Paste the viewing link instead.")
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !handled else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let code = barcode.payloadStringValue {
                    handled = true; dataScanner.stopScanning(); onScan(code); return
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

#if DEBUG
private struct CompanionLivePreview: View {
    var body: some View {
        let mac = CompanionFixtures.snapshots()[0]
        let state = CompanionLiveState.from(mac)
        let running: CompanionLiveState = {
            var value = state
            value.title = "Review cross-platform synchronization and recovery"
            value.state = "running"
            value.attention = 0
            value.running = 2
            value.startedAt = Date.now.addingTimeInterval(-127).timeIntervalSince1970
            value.activity = "Using tool"
            return value
        }()
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Synthetic preview · the same card renderer used by ActivityKit. This is not a hardware CarPlay test.").font(.footnote).foregroundStyle(.secondary)
                Text("Small family").font(.headline)
                CompanionLiveCard(state: state, macName: mac.name, stale: false, isSmall: true)
                    .frame(width: 200, height: 200, alignment: .topLeading).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                Text("Small family · running").font(.headline)
                CompanionLiveCard(state: running, macName: "George’s development MacBook Pro", stale: false, isSmall: true)
                    .frame(width: 200, height: 200, alignment: .topLeading).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                Text("Lock Screen").font(.headline)
                CompanionLiveCard(state: state, macName: mac.name, stale: false)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                Text("Stale observation").font(.headline)
                CompanionLiveCard(state: state, macName: mac.name, stale: true, isSmall: true)
                    .frame(width: 200, height: 200, alignment: .topLeading).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            }.padding()
        }.navigationTitle("Live Activity preview").navigationBarTitleDisplayMode(.inline)
    }
}
#endif
