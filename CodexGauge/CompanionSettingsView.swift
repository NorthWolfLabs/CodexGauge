import SwiftUI
import CoreImage.CIFilterBuiltins

struct CompanionSettingsView: View {
    @Bindable var publisher: CompanionPublisher
    @State private var showsQR = false
    @State private var confirmsRevocation = false
    @State private var confirmsDisconnect = false
    var body: some View {
        Section("iPhone companion") {
            if publisher.viewingLink != nil {
                Toggle("Share this Mac’s usage and task status", isOn: Binding(get: { publisher.enabled }, set: publisher.setEnabled))
                LabeledContent("Connection", value: publisher.status)
                HStack {
                    Button("Copy viewing link") { publisher.copyLink(usageOnly: false) }
                    Button("Copy usage-only link") { publisher.copyLink(usageOnly: true) }
                }
                Button("Show viewing QR code", systemImage: "qrcode") { showsQR = true }
                Button("Replace viewing links…", role: .destructive) { confirmsRevocation = true }
                    .disabled(publisher.isBusy)
                Button("Disconnect and delete relay data…", role: .destructive) { confirmsDisconnect = true }
                    .disabled(publisher.isBusy)
                Text("Anyone with a viewing link can see its data. Both links include your account email. The usage-only link excludes task and project names. Replacing links disconnects existing viewers.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("Relay address", text: $publisher.serverText, prompt: Text("https://…"))
                Button("Connect relay") { Task { await publisher.create() } }.disabled(publisher.isBusy)
                Text("The companion receives usage and task status. It cannot send commands to this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = publisher.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .sheet(isPresented: $showsQR) {
            VStack(spacing: 16) {
                Text("Link your iPhone").font(.headline)
                if let url = publisher.viewingLink, let image = viewingQR(url) {
                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 260, height: 260).padding(12).background(.white)
                        .privacySensitive().accessibilityLabel("Viewing link QR code")
                    Text("In CodexGauge on your iPhone, open Settings → Link a Mac → Scan QR code.").font(.callout).multilineTextAlignment(.center)
                    Text("This code grants read-only access to account email, usage and task names.").font(.caption).foregroundStyle(.secondary)
                } else { Text("The viewing code is unavailable. Copy a viewing link instead.") }
                Button("Done") { showsQR = false }.keyboardShortcut(.defaultAction)
            }.padding(24).frame(width: 340)
        }
        .confirmationDialog("Replace all viewing links for this Mac?", isPresented: $confirmsRevocation) {
            Button("Replace links", role: .destructive) { Task { await publisher.revokeViewingLinks() } }
        } message: { Text("Existing viewers will need a new link. This does not change your Codex connection.") }
        .confirmationDialog("Disconnect this Mac and delete its relay data?", isPresented: $confirmsDisconnect) {
            Button("Disconnect and delete", role: .destructive) { Task { await publisher.disconnect() } }
        } message: { Text("This removes its stored snapshot and push subscriptions. Data already downloaded by a viewer cannot be erased remotely.") }
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
