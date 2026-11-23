#if DEBUG
import SwiftUI

struct PhotoDiagnosticView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var record: PhotoDiagnosticRecord?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("One-photo diagnostic").font(.largeTitle.bold())
                    Text("Debug build only. This creates one small geometric PNG in Photos, then tests a PhotoKit upload over Wi-Fi. It does not sign in, read other photos, upload metadata, or create a Moment.")
                    Text("The uploaded image will be publicly readable in the existing storage bucket. Its deletion may require the storage administrator. The generated photo stays in Photos until you remove it.").font(.callout).foregroundStyle(.secondary)
                    if let record {
                        Text(record.phase).font(.title2)
                        if let scenario = record.scenario { Text(scenario).font(.headline) }
                        if let gate = record.notBefore { Text("Upload gate: after \(gate.formatted(date: .omitted, time: .standard)), with this app backgrounded.").font(.footnote) }
                        if let preflight = record.preflight { Text(preflight).font(.callout.monospaced()) }
                        if let detail = record.detail { Text(detail).font(.callout) }
                        if let hash = record.sourceSHA256, let count = record.sourceByteCount {
                            Text("Photos resource: \(count) bytes\nSHA-256: \(hash)").font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Text("Object: \(record.objectPath)").font(.caption.monospaced()).textSelection(.enabled)
                        if record.phase == "Ready" {
                            Button("Upload this synthetic photo once") { perform { try await PhotoDiagnostic.start() } }.buttonStyle(PrimaryButtonStyle())
                        }
                        Button("Refresh diagnostic status") { refresh() }.buttonStyle(.bordered)
                        if ["Transfer succeeded", "Transfer failed", "Stopped"].contains(record.phase) {
                            Button("Check this photo’s source bytes") { perform { try await PhotoDiagnostic.verifySource() } }
                        }
                        Button("Stop diagnostic") { perform { try PhotoDiagnostic.stop() } }
                        Button("Finish and reopen the normal app") {
                            perform { try PhotoDiagnostic.finish(); error = "Diagnostic mode is finished. Relaunch without --photo-upload-diagnostic to use the normal app." }
                        }
                    } else {
                        Button("Prepare backgrounded-host test") { perform { try await PhotoDiagnostic.prepareScenario("Host backgrounded") } }.buttonStyle(.bordered)
                        Button("Prepare disconnected-mirroring test") { perform { try await PhotoDiagnostic.prepareScenario("Mirroring disconnected") } }.buttonStyle(.bordered)
                        Button("Create synthetic test photo") { perform { _ = try await PhotoDiagnostic.prepare() } }.buttonStyle(PrimaryButtonStyle())
                    }
                    Text("System Resource Upload Test Mode is managed in Settings → Developer → Photos; this app can’t read its state. Scheduling overrides require both app and extension to be built and run from Xcode with development signing. This one-photo diagnostic is separate. Testing with system test mode off is still needed to assess ordinary background scheduling.").font(.footnote).foregroundStyle(.secondary)
                    if busy { ProgressView() }
                    if let error { Text(error).foregroundStyle(.red) }
                }.padding(24)
            }.navigationTitle("In Process · Diagnostic").disabled(busy)
        }.task { refresh(); try? PhotoDiagnostic.recordHostState(background: false) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { try? PhotoDiagnostic.recordHostState(background: true) }
                if phase == .active { try? PhotoDiagnostic.recordHostState(background: false); refresh() }
            }
    }
    private func refresh() {
        do {
            record = try PhotoDiagnostic.read()
            if let record { try PhotoDiagnostic.exportEvidence(record) }
        } catch { self.error = error.localizedDescription }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false; refresh() }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
