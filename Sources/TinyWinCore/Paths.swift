import Foundation

/// Centralized, deterministic file system layout for TinyWin.
/// Everything lives inside `~/Library/Application Support/TinyWin` by default
/// (or `$TINYWIN_HOME` for testing/portable setups), keeping macOS completely clean.
public struct TinyWinPaths: Sendable {
    public let rootDir: URL

    public init(rootDir: URL? = nil) {
        if let rootDir {
            self.rootDir = rootDir
        } else if let override = ProcessInfo.processInfo.environment["TINYWIN_HOME"], !override.isEmpty {
            self.rootDir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.rootDir = appSupport.appendingPathComponent("TinyWin", isDirectory: true)
        }
    }

    public var runtimeDir: URL { rootDir.appendingPathComponent("Runtime", isDirectory: true) }
    public var wineAppDir: URL { runtimeDir.appendingPathComponent("Wine.app", isDirectory: true) }
    public var wineRootDir: URL { wineAppDir.appendingPathComponent("Contents/Resources/wine", isDirectory: true) }
    public var wineBinDir: URL { wineRootDir.appendingPathComponent("bin", isDirectory: true) }
    public var wineExecutable: URL { wineBinDir.appendingPathComponent("wine") }
    public var wineserverExecutable: URL { wineBinDir.appendingPathComponent("wineserver") }
    public var wineLibDir: URL { wineRootDir.appendingPathComponent("lib/wine", isDirectory: true) }

    public var dxmtDir: URL { runtimeDir.appendingPathComponent("DXMT", isDirectory: true) }
    public var d3dMetalDir: URL { runtimeDir.appendingPathComponent("D3DMetal", isDirectory: true) }
    public var runtimeManifestURL: URL { runtimeDir.appendingPathComponent("manifest.json") }

    public var templateBottleDir: URL { rootDir.appendingPathComponent("Template", isDirectory: true) }
    public var bottlesDir: URL { rootDir.appendingPathComponent("Bottles", isDirectory: true) }
    public var cacheDir: URL { rootDir.appendingPathComponent("Cache", isDirectory: true) }
    public var logsDir: URL { rootDir.appendingPathComponent("Logs", isDirectory: true) }
    public var defaultAppsExportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/TinyWin Apps", isDirectory: true)
    }

    public func bottleDir(id: String) -> URL {
        bottlesDir.appendingPathComponent(id, isDirectory: true)
    }

    public func bottlePrefixDir(id: String) -> URL {
        bottleDir(id: id).appendingPathComponent("prefix", isDirectory: true)
    }

    public func bottleConfigURL(id: String) -> URL {
        bottleDir(id: id).appendingPathComponent("bottle.json")
    }

    public func bottleSandboxProfileURL(id: String) -> URL {
        bottleDir(id: id).appendingPathComponent("sandbox.sb")
    }

    public func bottleShaderCacheDir(id: String) -> URL {
        bottleDir(id: id).appendingPathComponent("shader_cache", isDirectory: true)
    }

    public func ensureBaseDirectories() throws {
        let fm = FileManager.default
        for dir in [rootDir, runtimeDir, bottlesDir, cacheDir, logsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
