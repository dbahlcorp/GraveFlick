import MetricKit
import os

final class DiagnosticsManager: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsManager()
    private let logger = Logger(subsystem: "com.bahlcorp.graveflick", category: "diagnostics")

    private override init() {
        super.init()
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        logger.info("Received \(payloads.count, privacy: .public) local performance metric payloads")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        logger.error("Received \(payloads.count, privacy: .public) local diagnostic payloads")
    }
}
