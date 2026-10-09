import Foundation
import IOKit.ps

/// Where the Mac gets its power from (IOKit power sources).
enum PowerSource: Hashable, Sendable {
    case ac(batteryPercent: Int?)
    case battery(percent: Int?)
    case ups
    case unknown

    var isOnBattery: Bool { if case .battery = self { return true } else { return false } }

    /// "Power adapter", "On battery (54%)".
    var title: String {
        switch self {
        case .ac: return "Power adapter"
        case .battery(let p?): return "On battery (\(p)%)"
        case .battery(nil): return "On battery"
        case .ups: return "Uninterruptible power supply"
        case .unknown: return "Power source unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .ac: return "powerplug"
        case .battery: return "battery.50"
        case .ups: return "bolt"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Reads the providing power source with IOPSCopyPowerSourcesInfo.
    static func current() -> PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .unknown }
        var batteryPercent: Int?
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                      let current = desc[kIOPSCurrentCapacityKey] as? Int,
                      let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                batteryPercent = current * 100 / max
            }
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        switch providing {
        case kIOPSBatteryPowerValue: return .battery(percent: batteryPercent)
        case kIOPSACPowerValue: return .ac(batteryPercent: batteryPercent)
        case "UPS Power": return .ups   // kIOPSUPSPowerValue (not imported into Swift)
        default: return .unknown
        }
    }
}

extension ProcessInfo.ThermalState {
    /// "Normal", "Warm", "Hot", "Very hot".
    var title: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Very hot"
        @unknown default: return "Unknown"
        }
    }

    /// One-line explanation for the job screen, nil when nothing needs saying.
    var explanation: String? {
        switch self {
        case .nominal, .fair: return nil
        case .serious: return "The Mac is slowing down to cool off; the conversion will take longer."
        case .critical: return "The Mac is very hot and running much slower. Make sure its vents are clear."
        @unknown default: return nil
        }
    }

    /// True when macOS is throttling (serious or critical).
    var isThrottling: Bool { self == .serious || self == .critical }

    var systemImage: String {
        switch self {
        case .nominal: return "thermometer.low"
        case .fair: return "thermometer.medium"
        case .serious, .critical: return "thermometer.high"
        @unknown default: return "thermometer.medium"
        }
    }
}

/// Machine status shown on the job screen: thermal state and power source.
/// Polls every few seconds while started (both reads are cheap and need no notifications).
@MainActor
@Observable
final class SystemStatus {
    private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private(set) var powerSource: PowerSource = .unknown

    var isOnBattery: Bool { powerSource.isOnBattery }

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init() {}

    /// Starts polling (idempotent).
    func start(interval: Duration = .seconds(5)) {
        guard pollTask == nil else { return }
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal != thermalState { thermalState = thermal }
        let power = PowerSource.current()
        if power != powerSource { powerSource = power }
    }
}
