#if DEBUG
import SwiftUI

struct AlbumWakeProbeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var message = "Preparing non-publishing Photos wake diagnostic…"
    @State private var exportMessage: String?
    var body: some View {
        VStack(spacing: 20) {
            Text(message)
            Button("Export diagnostic log") {
                do {
                    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Diagnostics", isDirectory: true)
                    _ = try DevelopmentLog.shared.export(to: directory)
                    exportMessage = "Diagnostic log exported. No scan or publication was performed."
                } catch { exportMessage = "The diagnostic log could not be exported." }
            }
            if let exportMessage { Text(exportMessage).font(.caption) }
        }.padding().task {
            let span = DevelopmentLog.shared.begin(.setup, .diagnostics)
            do {
                if ProcessInfo.processInfo.arguments.contains("--album-wake-probe-stop") {
                    try AlbumWakeProbe.stop()
                    message = "Wake diagnostic ended. Upload settings restored. Reopen In Process normally."
                } else {
                    try await AlbumWakeProbe.start()
                    message = "Non-publishing wake diagnostic active. Production uploads are paused. Only the existing synthetic card is used."
                }
                span.end(.succeeded)
            } catch {
                span.fail(error)
                message = "Wake diagnostic stopped: \(error.localizedDescription)"
            }
        }.onChange(of: scenePhase) { _, phase in
            DevelopmentLog.shared.emit(.lifecycle, .diagnostics, [.stage: .tag(phase == .active ? .foreground : phase == .background ? .background : .inactive)])
        }
    }
}
#endif
