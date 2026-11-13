import Foundation
import Darwin

struct NetworkEnvironment: Equatable {
    enum Hardware: String { case intel, appleSilicon, unknown }
    let osMajor: Int
    let hardware: Hardware
    let executionArchitecture: String

    static var current: Self {
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0)
        let errorNumber = status == 0 ? 0 : errno
        let execution = ShellCommands.machineArchitecture()
        let hardware = classifyHardware(sysctlStatus: status, errorNumber: errorNumber,
                                        arm64Flag: arm64, executionArchitecture: execution)
        return Self(osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                    hardware: hardware, executionArchitecture: execution)
    }

    /// Apple silicon kernels always define `hw.optional.arm64` (also under Rosetta), so a
    /// missing key (ENOENT) cannot be Apple silicon. Any other read failure stays unknown.
    static func classifyHardware(sysctlStatus: Int32, errorNumber: Int32, arm64Flag: Int32,
                                 executionArchitecture: String) -> Hardware {
        if sysctlStatus == 0 && arm64Flag == 1 { return .appleSilicon }
        let established = sysctlStatus == 0 || errorNumber == ENOENT
        return established && executionArchitecture == "x86_64" ? .intel : .unknown
    }

    var isTranslated: Bool { hardware == .appleSilicon && executionArchitecture == "x86_64" }
}

struct NetworkCapability: Equatable {
    enum Mechanism: Equatable { case legacyAttempt, manualPrivateWiFiAddress, unavailable }
    enum PrivateAddressMode: String { case off = "Off", fixed = "Fixed", rotating = "Rotating" }
    let mechanism: Mechanism
    let availableModes: [PrivateAddressMode]
    let explanation: String

    static func resolve(environment: NetworkEnvironment, interface: ShellCommands.InterfaceKind?) -> Self {
        guard environment.osMajor >= 13, environment.hardware != .unknown, let interface,
              ["arm64", "x86_64"].contains(environment.executionArchitecture),
              !(environment.hardware == .intel && environment.executionArchitecture == "arm64") else {
            return Self(mechanism: .unavailable, availableModes: [], explanation: "Network identity capability is unknown for this OS, hardware, execution architecture, or interface.")
        }
        if environment.osMajor == 13 {
            return Self(mechanism: .legacyAttempt, availableModes: [], explanation: "Legacy MAC change can be attempted on macOS 13; driver support and the resulting address must be checked.")
        }
        if interface == .wifi && environment.osMajor >= 15 {
            return Self(mechanism: .manualPrivateWiFiAddress, availableModes: [.off, .fixed, .rotating],
                explanation: "macOS 15+ offers Off, Fixed, and Rotating Private Wi-Fi Address modes in System Settings > Wi-Fi. This app cannot verify or configure the mode automatically. Reconnecting does not guarantee an immediate new address.")
        }
        return Self(mechanism: .unavailable, availableModes: [], explanation: "No verified automatic network identity mechanism is available on this macOS/interface. Network settings are unchanged.")
    }
}

struct NetworkIdentityObservation: Equatable {
    let reconnected: Bool
    let previousAddress: String?
    let currentAddress: String?
    let verifiedMode: NetworkCapability.PrivateAddressMode?

    var addressChanged: Bool? {
        guard let previousAddress, let currentAddress else { return nil }
        return previousAddress != currentAddress
    }

    var summary: String {
        let address: String
        switch addressChanged {
        case true?: address = "An address change was observed."
        case false?: address = "The observed address did not change."
        case nil: address = "Address change could not be established."
        }
        return "\(reconnected ? "Interface reconnection verified." : "Interface reconnection unverified.") \(address) \(verifiedMode.map { "Private Wi-Fi Address mode verified: \($0.rawValue)." } ?? "Private Wi-Fi Address mode unverified.")"
    }
}
