import Foundation
import Metal

public struct SystemDiagnostics: Sendable {
    public let macOSVersion: String
    public let architecture: String
    public let cpuBrand: String
    public let isAppleSilicon: Bool
    public let rosettaInstalled: Bool
    public let metalDeviceName: String?
    public let supportsMetal3: Bool
    public let sandboxExecAvailable: Bool
    public let totalMemoryGB: Double
    public let freeDiskGB: Double

    public var isReadyForWindowsApps: Bool {
        (!isAppleSilicon || rosettaInstalled) && metalDeviceName != nil
    }
}

public enum SystemCheck {
    public static func run() -> SystemDiagnostics {
        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"

        var arch = "unknown"
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #endif
        let isAppleSilicon = (arch == "arm64")

        let cpuBrand = sysctlString("machdep.cpu.brand_string") ?? arch
        let rosettaInstalled = !isAppleSilicon || checkRosetta()

        let device = MTLCreateSystemDefaultDevice()
        let metalName = device?.name
        let supportsMetal3 = device?.supportsFamily(.metal3) ?? false

        let sandboxAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")
        let totalMemGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        let freeDiskGB = freeDiskSpaceGB()

        return SystemDiagnostics(
            macOSVersion: osString,
            architecture: arch,
            cpuBrand: cpuBrand,
            isAppleSilicon: isAppleSilicon,
            rosettaInstalled: rosettaInstalled,
            metalDeviceName: metalName,
            supportsMetal3: supportsMetal3,
            sandboxExecAvailable: sandboxAvailable,
            totalMemoryGB: totalMemGB,
            freeDiskGB: freeDiskGB
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func checkRosetta() -> Bool {
        // Fast check: Apple's Rosetta 2 runtime binary exists at /Library/Apple/usr/libexec/oah/libRosettaRuntime
        if FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime") {
            return true
        }
        // Fallback: probe via `arch -x86_64 /usr/bin/true`
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        proc.arguments = ["-x86_64", "/usr/bin/true"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func freeDiskSpaceGB() -> Double {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = values.volumeAvailableCapacityForImportantUsage {
            return Double(cap) / (1024 * 1024 * 1024)
        }
        return 0
    }
}
