import SwiftUI
import CoreImage.CIFilterBuiltins

struct CompanionSettingsView: View {
    @Bindable var publisher: CompanionPublisher
    @State private var showsQR = false
    @State private var removingDevice: CompanionPairedDevice?
    var body: some View {
        Form {
            Section {
                if publisher.viewingLink != nil {
                    Toggle("Share usage and task status", isOn: Binding(get: { publisher.enabled }, set: publisher.setEnabled))
                }
                Button("Pair iPhone…", systemImage: "plus") {
                    Task {
                        if publisher.viewingLink == nil { await publisher.create() }
                        if publisher.viewingLink != nil { showsQR = true }
                    }
                }.disabled(publisher.isBusy).accessibilityIdentifier("companion.pairPhone")
                if let error = publisher.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(nil).fixedSize(horizontal: false, vertical: true) }
            }
            if publisher.viewingLink != nil {
                Section("Paired Devices") {
                    if let error = publisher.devicesError {
                        Text(error).font(.callout).foregroundStyle(.secondary).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                        Button("Try Again") { Task { await publisher.refreshDevices() } }
                    } else if publisher.isLoadingDevices && publisher.devices.isEmpty {
                        ProgressView("Loading devices…")
                    } else if publisher.devices.isEmpty {
                        Text("No paired devices").foregroundStyle(.secondary)
                    }
                    ForEach(publisher.devices) { device in
                        HStack(spacing: 12) {
                            Image(systemName: "iphone").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name)
                                Text(device.connected ? "Connected" : "Last connected \(device.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if device.scope == "usage" { Text("Usage only").font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button("Remove…") { removingDevice = device }.disabled(publisher.isBusy)
                                .accessibilityLabel("Remove \(device.name)")
                        }.padding(.vertical, 4)
                    }
                }
            }
        }.formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                await publisher.refreshDevices()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .sheet(isPresented: $showsQR, onDismiss: { Task { await publisher.refreshDevices() } }) {
            VStack(alignment: .center, spacing: 16) {
                Text("Pair your iPhone").font(.headline)
                if let url = publisher.viewingLink, let image = viewingQR(url) {
                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 260, height: 260).padding(12).background(.white)
                        .privacySensitive().accessibilityLabel("Viewing link QR code")
                    Text("On your iPhone, open CodexGauge Settings → Link a Mac, then scan this code.")
                        .font(.callout).accessibilityIdentifier("companion.pairInstructions")
                    Text("Your iPhone can view account email, usage and task names. It cannot control this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("The code is unavailable. Try pairing again.") }
                HStack {
                    Button("Copy Link") { publisher.copyLink() }.disabled(publisher.viewingLink == nil)
                    Spacer()
                    Button("Done") { showsQR = false }.keyboardShortcut(.defaultAction)
                }
            }.lineLimit(nil).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(24).frame(width: 380)
        }
        .confirmationDialog("Remove this device?", isPresented: Binding(get: { removingDevice != nil }, set: { if !$0 { removingDevice = nil } })) {
            if let device = removingDevice {
                Button("Remove Device", role: .destructive) { Task { await publisher.removeDevice(device) } }
            }
        } message: { Text("This stops viewing access and notifications for this device. To reconnect, pair it again. Data already downloaded remains on the device.") }

    }
    private func viewingQR(_ url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}
