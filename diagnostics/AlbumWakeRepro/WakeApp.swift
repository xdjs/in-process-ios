import SwiftUI
import Photos

@main struct WakeApp: App {
    init() { ProbeLog.shared.emit("initialize") }
    var body: some Scene { WindowGroup { WakeView() } }
}
struct WakeView: View {
    @Environment(\.scenePhase) private var phase
    @State private var status = "Non-publishing PhotoKit reproduction. No network or upload jobs."
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(status).accessibilityIdentifier("probeStatus") }
                Section("Explicit setup") {
                    Button("1. Request full Photos access") { action {
                        try Probe.physical()
                        let result = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                        guard result == .authorized else { throw ProbeError.authorization }
                        return "Full Photos access granted."
                    } }
                    Button("2. Create isolated empty album") { action {
                        try Probe.physical()
                        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw ProbeError.authorization }
                        if FileManager.default.fileExists(atPath: try Probe.directory().appendingPathComponent("configuration.json").path) {
                            let config = try Probe.read()
                            _ = try Probe.album(config)
                            return "Using the previously created Album Wake Repro album."
                        }
                        var identifier: String?
                        try await PHPhotoLibrary.shared().performChanges {
                            identifier = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "Album Wake Repro").placeholderForCreatedAssetCollection.localIdentifier
                        }
                        guard let identifier else { throw ProbeError.missingAlbum }
                        try Probe.save(ProbeConfiguration(albumID: identifier))
                        ProbeLog.shared.emit("album.created", members: 0)
                        return "Empty Album Wake Repro album created. No photo was created or changed."
                    } }
                    Button("3. Enable once and set baseline") { action {
                        try Probe.physical()
                        var config = try Probe.read()
                        guard PHAsset.fetchAssets(in: try Probe.album(config), options: nil).count == 0 else { throw ProbeError.emptyAlbumRequired }
                        let library = PHPhotoLibrary.shared()
                        // Explicit baseline only; no automatic re-enablement or loop.
                        if library.uploadJobExtensionEnabled { try library.disableUploadJobExtension() }
                        config.baseline = try NSKeyedArchiver.archivedData(withRootObject: library.currentChangeToken, requiringSecureCoding: true)
                        try Probe.save(config)
                        ProbeLog.shared.emit("enable.request")
                        try library.enableUploadJobExtension(with: PHAssetResourceUploadJobOptions())
                        ProbeLog.shared.emit("enable.returned", enabled: library.uploadJobExtensionEnabled)
                        return "Enabled. Wait for an initial extension completed event before adding the existing fixture in Apple Photos."
                    } }
                }
                Section("Readback and cleanup") {
                    Button("Inspect Photos history now") { action {
                        let count = try Probe.snapshot()
                        return "Foreground readback: \(count) album members. This is not a background wake."
                    } }
                    Button("Export event log") { action {
                        _ = try ProbeLog.shared.export()
                        return "Saved Documents/WakeEvents.jsonl. No Photos scan or settings change."
                    } }
                    Button("Disable reproduction extension") { action {
                        try Probe.physical()
                        try PHPhotoLibrary.shared().disableUploadJobExtension()
                        ProbeLog.shared.emit("disable.returned", enabled: PHPhotoLibrary.shared().uploadJobExtensionEnabled)
                        return "Reproduction extension disabled. Album and photos preserved."
                    } }
                }
            }.navigationTitle("Album Wake Repro").disabled(busy)
        }.onChange(of: phase) { _, value in
            ProbeLog.shared.emit(value == .active ? "scene.active" : value == .background ? "scene.background" : "scene.inactive")
        }
    }
    private func action(_ body: @escaping () async throws -> String) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { status = try await body() }
            catch {
                ProbeLog.shared.emit("host.error", errorCode: (error as NSError).code)
                status = "Stopped: \(String(describing: error is ProbeError ? error : ProbeError.missingAlbum)). No retry was performed."
            }
        }
    }
}
