#if DEBUG
import SwiftUI

/// Presentation reads only the diagnostic journal. No coordinator, Photos,
/// session or queue calls. The authenticated parent owns access to this sheet.
struct DiagnosticsView: View {
    let log: DevelopmentLog
    @Environment(\.dismiss) private var dismiss
    @State private var exported: URL?
    @State private var preview = ""
    @State private var summary = ""
    @State private var problem: String?
    @State private var loading = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Development diagnostics").font(Theme.title)
                    Text("App and upload extension events · UTC timestamps · bounded local history. Logs begin with this build; older missing history cannot be recovered.")
                    Text(summary).accessibilityIdentifier("diagnosticsSummary")
                    Text("No invocation in retained logs means none was observed here. It does not explain iOS scheduling. Resource Upload Test Mode is unknown to the app.").font(Theme.footnote)
                    Button("Refresh log file") { Task { await refresh() } }.disabled(loading)
                        .accessibilityIdentifier("refreshDiagnostics")
                    if let exported {
                        ShareLink("Share log file", item: exported).accessibilityIdentifier("shareDiagnostics")
                        Text("A copy is also saved in this app’s Documents/Diagnostics folder for development retrieval.").font(Theme.footnote)
                    }
                    if let problem { Text(problem).foregroundStyle(Theme.error) }
                    if loading { ProgressView() }
                    Text(preview).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }.padding()
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("closeDiagnostics") } }
            .task { await refresh() }
        }
    }
    private func refresh() async {
        guard !loading else { return }; loading = true; problem = nil
        defer { loading = false }
        do {
            let result = try await Task.detached {
                let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let url = try log.export(to: documents.appendingPathComponent("Diagnostics"))
                let text = try String(contentsOf: url, encoding: .utf8)
                let lines = text.split(separator: "\n")
                let rows = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                let invocation = rows.last { $0["event"] as? String == "extensionInvocation" && $0["phase"] as? String == "begin" }
                let job = rows.last { ["systemJob", "registration"].contains($0["event"] as? String ?? "") }
                let summary = "\(lines.count) retained events. File-write failures this process: \(log.fileFailures).\nLatest extension invocation: \(invocation?["timestamp"] as? String ?? "none observed in retained history").\nLatest PhotoKit job event: \(job?["timestamp"] as? String ?? "none observed in retained history")."
                return (url, lines.suffix(80).joined(separator: "\n"), summary)
            }.value
            exported = result.0; preview = result.1; summary = result.2
        } catch { problem = "Could not export diagnostics. No upload state was changed." }
    }
}
#endif
