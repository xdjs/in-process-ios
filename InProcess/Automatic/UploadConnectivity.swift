import Network
import Foundation

@MainActor final class UploadConnectivity {
    private let monitor = NWPathMonitor()
    init(coordinator: UploadCoordinator) {
        monitor.pathUpdateHandler = { [weak coordinator] path in
            Task { @MainActor in
                if coordinator?.online != (path.status == .satisfied) || coordinator?.expensive != path.isExpensive {
                    DevelopmentLog.shared.emit(.connectivity, .network, [.online: .flag(path.status == .satisfied), .expensive: .flag(path.isExpensive)])
                }
                coordinator?.online = path.status == .satisfied
                coordinator?.expensive = path.isExpensive
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.xdjs.InProcess.connectivity"))
    }
    deinit { monitor.cancel() }
    static func current() async -> (online: Bool, expensive: Bool) {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.pathUpdateHandler = nil; monitor.cancel()
                continuation.resume(returning: (path.status == .satisfied, path.isExpensive))
            }
            monitor.start(queue: DispatchQueue(label: "com.xdjs.InProcess.extension-connectivity"))
        }
    }
}
