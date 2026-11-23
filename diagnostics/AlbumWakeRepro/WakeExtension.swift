import Photos
import ExtensionFoundation

// No observer, job, network request, actor, coordinator, retry, or shared lease.
@main final class WakeExtension: PHBackgroundResourceUploadJobExtension {
    required init() { ProbeLog.shared.emit("initialize") }
    func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
        ProbeLog.shared.emit("processJobs.begin")
        do {
            _ = try Probe.snapshot()
            ProbeLog.shared.emit("processJobs.completed")
            return .completed
        } catch {
            ProbeLog.shared.emit("processJobs.failure", errorCode: (error as NSError).code)
            return .failure
        }
    }
    func willTerminate() async { ProbeLog.shared.emit("willTerminate") }
}
