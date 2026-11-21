import Foundation

public enum BottlePreset: String, Codable, CaseIterable, Sendable {
    case app = "app"
    case game = "game"

    public var displayName: String {
        switch self {
        case .app: return "Desktop Apps (Ultra-Lean)"
        case .game: return "Games (Metal + High Perf)"
        }
    }
}

public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    case dxmt = "dxmt"
    case wined3d = "wined3d"
    case d3dmetal = "d3dmetal"

    public var displayName: String {
        switch self {
        case .dxmt: return "DXMT (DirectX 10/11 → Metal)"
        case .wined3d: return "WineD3D (OpenGL / 2D Apps)"
        case .d3dmetal: return "D3DMetal (DirectX 12 → Metal)"
        }
    }
}

public enum WindowsVersion: String, Codable, CaseIterable, Sendable {
    case win10 = "win10"
    case win11 = "win11"
    case win7 = "win7"

    public var displayName: String {
        switch self {
        case .win10: return "Windows 10"
        case .win11: return "Windows 11"
        case .win7: return "Windows 7"
        }
    }
}

public struct BottleSecurityConfig: Codable, Equatable, Sendable {
    /// Enforce macOS Seatbelt sandbox-exec around Wine processes.
    public var enableSandbox: Bool
    /// Remove Wine's default `Z:\ -> /` host root mapping.
    public var disableHostRootDrive: Bool
    /// Replace Wine's default symlinks to macOS Desktop/Documents/Downloads with isolated dirs.
    public var isolateUserFolders: Bool
    /// Block all outbound and inbound network access in the Seatbelt sandbox.
    public var offlineMode: Bool
    /// Optional explicit host folder exposed read/write as `S:\` inside Windows.
    public var sharedFolderPath: String?

    public init(
        enableSandbox: Bool = true,
        disableHostRootDrive: Bool = true,
        isolateUserFolders: Bool = true,
        offlineMode: Bool = false,
        sharedFolderPath: String? = nil
    ) {
        self.enableSandbox = enableSandbox
        self.disableHostRootDrive = disableHostRootDrive
        self.isolateUserFolders = isolateUserFolders
        self.offlineMode = offlineMode
        self.sharedFolderPath = sharedFolderPath
    }
}

public struct BottleGraphicsConfig: Codable, Equatable, Sendable {
    public var backend: GraphicsBackend
    /// Crisp HiDPI rendering on Retina displays (paired with 192 DPI by default so windows stay full size).
    public var retinaMode: Bool
    /// Windows DPI scaling (96 = 100%, 120 = 125%, 144 = 150%, 192 = 200% for Retina).
    public var dpi: Int
    /// Show Apple Metal Performance HUD overlay.
    public var metalHUD: Bool
    /// Enable ESync/MSync low-latency synchronization.
    public var fastSync: Bool
    /// Disable Wine debug spam (`WINEDEBUG=-all`) for lower CPU usage.
    public var quietLogs: Bool

    public init(
        backend: GraphicsBackend = .dxmt,
        retinaMode: Bool = true,
        dpi: Int? = nil,
        metalHUD: Bool = false,
        fastSync: Bool = true,
        quietLogs: Bool = true
    ) {
        self.backend = backend
        self.retinaMode = retinaMode
        self.dpi = dpi ?? (retinaMode ? 192 : 96)
        self.metalHUD = metalHUD
        self.fastSync = fastSync
        self.quietLogs = quietLogs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.backend = try c.decodeIfPresent(GraphicsBackend.self, forKey: .backend) ?? .dxmt
        self.retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? true
        self.dpi = try c.decodeIfPresent(Int.self, forKey: .dpi) ?? (self.retinaMode ? 192 : 96)
        self.metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        self.fastSync = try c.decodeIfPresent(Bool.self, forKey: .fastSync) ?? true
        self.quietLogs = try c.decodeIfPresent(Bool.self, forKey: .quietLogs) ?? true
    }
}

public struct PinnedWindowsApp: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Path to executable (either absolute macOS path or relative inside `prefix/drive_c/...`).
    public var executablePath: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var nativeBundlePath: String?
    public var addedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        executablePath: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        nativeBundlePath: String? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.nativeBundlePath = nativeBundlePath
        self.addedAt = addedAt
    }
}

public struct BottleConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var preset: BottlePreset
    public var windowsVersion: WindowsVersion
    public var security: BottleSecurityConfig
    public var graphics: BottleGraphicsConfig
    /// Kill wineserver cleanly once the launched Windows process exits so zero background processes remain.
    public var autoReapServer: Bool
    public var pinnedApps: [PinnedWindowsApp]
    public var createdAt: Date

    public init(
        id: String,
        name: String,
        preset: BottlePreset = .app,
        windowsVersion: WindowsVersion = .win10,
        security: BottleSecurityConfig = BottleSecurityConfig(),
        graphics: BottleGraphicsConfig? = nil,
        autoReapServer: Bool = true,
        pinnedApps: [PinnedWindowsApp] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.preset = preset
        self.windowsVersion = windowsVersion
        self.security = security
        self.graphics = graphics ?? BottleGraphicsConfig(
            backend: preset == .game ? .dxmt : .dxmt,
            retinaMode: preset == .app,
            metalHUD: false,
            fastSync: true,
            quietLogs: true
        )
        self.autoReapServer = autoReapServer
        self.pinnedApps = pinnedApps
        self.createdAt = createdAt
    }
}

public struct RuntimeManifest: Codable, Equatable, Sendable {
    public var wineVersion: String
    public var wineSourceURL: String
    public var dxmtVersion: String
    public var dxmtSourceURL: String
    public var d3dMetalInstalled: Bool
    public var installedAt: Date

    public init(
        wineVersion: String,
        wineSourceURL: String,
        dxmtVersion: String,
        dxmtSourceURL: String,
        d3dMetalInstalled: Bool = false,
        installedAt: Date = Date()
    ) {
        self.wineVersion = wineVersion
        self.wineSourceURL = wineSourceURL
        self.dxmtVersion = dxmtVersion
        self.dxmtSourceURL = dxmtSourceURL
        self.d3dMetalInstalled = d3dMetalInstalled
        self.installedAt = installedAt
    }
}

public enum TinyWinError: LocalizedError, Sendable {
    case runtimeNotInstalled
    case rosettaNotInstalled
    case invalidBottleName(String)
    case bottleAlreadyExists(String)
    case bottleNotFound(String)
    case executableNotFound(String)
    case invalidPEFile(String)
    case commandFailed(command: String, code: Int32, stderr: String)
    case downloadFailed(String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .runtimeNotInstalled:
            return "TinyWin runtime (Wine + DXMT) is not installed. Run `tinywin setup` or click Install Runtime."
        case .rosettaNotInstalled:
            return "Apple Rosetta 2 is required to run x86/x64 Windows apps on Apple Silicon. Install it with: softwareupdate --install-rosetta"
        case .invalidBottleName(let name):
            return "Invalid bottle name '\(name)'. Use letters, numbers, spaces, hyphens, or underscores."
        case .bottleAlreadyExists(let name):
            return "A bottle named '\(name)' already exists."
        case .bottleNotFound(let name):
            return "Bottle '\(name)' was not found."
        case .executableNotFound(let path):
            return "Executable not found at path: \(path)"
        case .invalidPEFile(let reason):
            return "Invalid Windows executable: \(reason)"
        case .commandFailed(let cmd, let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Command `\(cmd)` failed with exit code \(code)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .ioError(let msg):
            return "Filesystem error: \(msg)"
        }
    }
}
