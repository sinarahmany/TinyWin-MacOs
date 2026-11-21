import Foundation

public struct BottleStats: Sendable {
    public let id: String
    public let diskUsageBytes: Int64
    public let isRunning: Bool
    public let runningProcessCount: Int
    public let totalRSSBytes: Int64
}

/// Manages ultra-lean, bloat-stripped Windows bottles with instant APFS copy-on-write cloning.
public final class BottleManager: Sendable {
    public let paths: TinyWinPaths
    public let runtime: RuntimeManager

    public init(paths: TinyWinPaths = TinyWinPaths()) {
        self.paths = paths
        self.runtime = RuntimeManager(paths: paths)
    }

    public func listBottles() throws -> [BottleConfig] {
        try paths.ensureBaseDirectories()
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: paths.bottlesDir, includingPropertiesForKeys: nil) else {
            return []
        }

        let decoder = JSONDecoder()
        var bottles: [BottleConfig] = []
        for dir in dirs {
            let cfgURL = dir.appendingPathComponent("bottle.json")
            guard let data = try? Data(contentsOf: cfgURL),
                  let config = try? decoder.decode(BottleConfig.self, from: data) else {
                continue
            }
            bottles.append(config)
        }
        return bottles.sorted { $0.createdAt < $1.createdAt }
    }

    public func loadBottle(idOrName: String) throws -> BottleConfig {
        let bottles = try listBottles()
        let lowered = idOrName.lowercased()
        if let exact = bottles.first(where: { $0.id.lowercased() == lowered || $0.name.lowercased() == lowered }) {
            return exact
        }
        throw TinyWinError.bottleNotFound(idOrName)
    }

    public func saveBottle(_ bottle: BottleConfig) throws {
        let dir = paths.bottleDir(id: bottle.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bottle)
        try data.write(to: paths.bottleConfigURL(id: bottle.id), options: .atomic)
    }

    /// Initializes the shared ultra-minimal template Wine prefix once (no Mono/Gecko bloat).
    /// Subsequent bottles clone from this template via APFS CoW (`cp -cR`) in ~0.1s using ~0 extra disk bytes.
    public func ensureTemplatePrefix() throws {
        guard runtime.isInstalled else { throw TinyWinError.runtimeNotInstalled }
        let fm = FileManager.default
        let marker = paths.templateBottleDir.appendingPathComponent(".tinywin_template_v1")
        if fm.fileExists(atPath: marker.path) && fm.fileExists(atPath: paths.templateBottleDir.appendingPathComponent("system.reg").path) {
            return
        }

        if fm.fileExists(atPath: paths.templateBottleDir.path) {
            try fm.removeItem(at: paths.templateBottleDir)
        }
        try fm.createDirectory(at: paths.templateBottleDir, withIntermediateDirectories: true)

        // Initialize minimal 64-bit WoW64 prefix with Mono & Gecko disabled (`mscoree,mshtml=`)
        try runWineInitCommand(
            prefixDir: paths.templateBottleDir,
            args: ["wineboot", "--init"]
        )

        // Wait cleanly for wineserver to flush registry files and exit
        try waitAndShutdownServer(prefixDir: paths.templateBottleDir)

        // Sync DXMT winemetal.dll into template so all clones have Metal ready out of the box
        try runtime.syncDXMTIntoPrefix(paths.templateBottleDir)

        // Apply universal zero-bloat registry tweaks (disable crash dialogs, enable font smoothing, full-size Retina 192 DPI)
        try applyRegistryTweaks(
            prefixDir: paths.templateBottleDir,
            retinaMode: true,
            dpi: 192,
            windowsVersion: .win10
        )

        // Enforce strict isolation on template itself
        try SandboxBuilder.enforcePrefixIsolation(
            prefixDir: paths.templateBottleDir,
            security: BottleSecurityConfig()
        )

        try "v1\n".write(to: marker, atomically: true, encoding: .utf8)
    }

    /// Creates a new isolated, zero-bloat bottle by APFS copy-on-write cloning the clean template.
    public func createBottle(
        name: String,
        preset: BottlePreset = .app,
        windowsVersion: WindowsVersion = .win10,
        security: BottleSecurityConfig = BottleSecurityConfig(),
        graphics: BottleGraphicsConfig? = nil
    ) throws -> BottleConfig {
        guard runtime.isInstalled else { throw TinyWinError.runtimeNotInstalled }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = sanitizeBottleID(trimmed)
        guard !trimmed.isEmpty, !id.isEmpty else {
            throw TinyWinError.invalidBottleName(name)
        }

        try paths.ensureBaseDirectories()
        let existing = try listBottles()
        if existing.contains(where: { $0.id == id || $0.name.lowercased() == trimmed.lowercased() }) {
            throw TinyWinError.bottleAlreadyExists(trimmed)
        }

        // Ensure clean minimal template exists
        try ensureTemplatePrefix()

        let bottleDir = paths.bottleDir(id: id)
        let prefixDir = paths.bottlePrefixDir(id: id)
        let shaderCache = paths.bottleShaderCacheDir(id: id)

        let fm = FileManager.default
        try fm.createDirectory(at: bottleDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: shaderCache, withIntermediateDirectories: true)

        // APFS Copy-on-Write clone: instant + ~0 extra disk space!
        do {
            try cloneDirectoryAPFS(from: paths.templateBottleDir, to: prefixDir)
        } catch {
            try? fm.removeItem(at: bottleDir)
            throw error
        }

        let bottle = BottleConfig(
            id: id,
            name: trimmed,
            preset: preset,
            windowsVersion: windowsVersion,
            security: security,
            graphics: graphics
        )

        // Apply bottle-specific Retina / DPI / Windows version settings if different from template defaults
        if bottle.graphics.retinaMode != true || bottle.graphics.dpi != 192 || bottle.windowsVersion != .win10 {
            try applyRegistryTweaks(
                prefixDir: prefixDir,
                retinaMode: bottle.graphics.retinaMode,
                dpi: bottle.graphics.dpi,
                windowsVersion: bottle.windowsVersion
            )
        }

        // Enforce bottle-specific filesystem isolation & Seatbelt profile
        try SandboxBuilder.enforcePrefixIsolation(prefixDir: prefixDir, security: bottle.security)
        _ = try SandboxBuilder.writeProfile(bottle: bottle, paths: paths)
        try saveBottle(bottle)

        return bottle
    }

    public func updateBottle(_ bottle: BottleConfig) throws {
        let prefixDir = paths.bottlePrefixDir(id: bottle.id)
        try SandboxBuilder.enforcePrefixIsolation(prefixDir: prefixDir, security: bottle.security)
        try applyRegistryTweaks(
            prefixDir: prefixDir,
            retinaMode: bottle.graphics.retinaMode,
            dpi: bottle.graphics.dpi,
            windowsVersion: bottle.windowsVersion
        )
        _ = try SandboxBuilder.writeProfile(bottle: bottle, paths: paths)
        try saveBottle(bottle)
    }

    public func deleteBottle(id: String) throws {
        let bottle = try loadBottle(idOrName: id)
        let runner = ProcessRunner(paths: paths)
        try? runner.killBottleProcesses(bottle: bottle)
        try FileManager.default.removeItem(at: paths.bottleDir(id: bottle.id))
    }

    public func pinApp(
        bottleID: String,
        name: String,
        executablePath: String,
        arguments: [String] = [],
        nativeBundlePath: String? = nil
    ) throws -> BottleConfig {
        var bottle = try loadBottle(idOrName: bottleID)
        let app = PinnedWindowsApp(
            name: name,
            executablePath: executablePath,
            arguments: arguments,
            nativeBundlePath: nativeBundlePath
        )
        bottle.pinnedApps.removeAll { $0.executablePath == executablePath }
        bottle.pinnedApps.append(app)
        try saveBottle(bottle)
        return bottle
    }

    public func removePinnedApp(bottleID: String, appID: String) throws -> BottleConfig {
        var bottle = try loadBottle(idOrName: bottleID)
        bottle.pinnedApps.removeAll { $0.id == appID }
        try saveBottle(bottle)
        return bottle
    }

    /// Computes live disk footprint and running process / RAM usage for a bottle.
    public func stats(for bottle: BottleConfig) -> BottleStats {
        let dir = paths.bottleDir(id: bottle.id)
        let disk = RuntimeManager.directorySize(url: dir)
        let procs = Self.inspectWineProcesses(forBottleID: bottle.id)
        let totalRSS = procs.reduce(Int64(0)) { $0 + $1.rssBytes }
        return BottleStats(
            id: bottle.id,
            diskUsageBytes: disk,
            isRunning: !procs.isEmpty,
            runningProcessCount: procs.count,
            totalRSSBytes: totalRSS
        )
    }

    public func sanitizeBottleID(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = name.lowercased().unicodeScalars.map { scalar -> Character in
            if allowed.contains(scalar) {
                return Character(scalar)
            }
            if CharacterSet.whitespaces.contains(scalar) {
                return "-"
            }
            return "-"
        }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(collapsed.prefix(48))
    }

    /// Uses macOS APFS `cp -cR` (clonefile) with graceful fallback to standard copy on non-APFS volumes.
    private func cloneDirectoryAPFS(from source: URL, to destination: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/cp")
        proc.arguments = ["-cR", source.path, destination.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            // Fallback for non-APFS volumes
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private func applyRegistryTweaks(
        prefixDir: URL,
        retinaMode: Bool,
        dpi: Int,
        windowsVersion: WindowsVersion
    ) throws {
        // Write a tiny .reg file and apply via `wine regedit` (clean, fast, zero bloat)
        let retinaVal = retinaMode ? "y" : "n"
        let clampedDPI = max(96, min(384, dpi))
        let dpiHex = String(format: "%08x", clampedDPI)
        // Scale console font height proportionally so cmd.exe windows are readable (16px @ 96 DPI, 32px @ 192 DPI)
        let consoleFontPx = max(14, (clampedDPI * 16) / 96)
        let consoleFontHex = String(format: "%04x0000", consoleFontPx)

        let winVerString: String
        switch windowsVersion {
        case .win11: winVerString = "win11"
        case .win10: winVerString = "win10"
        case .win7:  winVerString = "win7"
        }

        let regContent = """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]
        "RetinaMode"="\(retinaVal)"
        "AllowVerticalSync"="y"
        "LeftOptionIsAlt"="n"
        "RightOptionIsAlt"="n"

        [HKEY_CURRENT_USER\\Software\\Wine\\Fonts]
        "LogPixels"=dword:\(dpiHex)

        [HKEY_CURRENT_USER\\Control Panel\\Desktop]
        "LogPixels"=dword:\(dpiHex)
        "FontSmoothing"="2"
        "FontSmoothingType"=dword:00000002
        "FontSmoothingGamma"=dword:00000578
        "FontSmoothingOrientation"=dword:00000001

        [HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Hardware Profiles\\Current\\Software\\Fonts]
        "LogPixels"=dword:\(dpiHex)

        [HKEY_CURRENT_USER\\Console]
        "FontSize"=dword:\(consoleFontHex)

        [HKEY_CURRENT_USER\\Software\\Wine\\WineDbg]
        "ShowCrashDialog"=dword:00000000

        [HKEY_CURRENT_USER\\Software\\Wine]
        "Version"="\(winVerString)"
        """

        let regFile = prefixDir.appendingPathComponent("tinywin_tune.reg")
        try regContent.write(to: regFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: regFile) }

        try runWineInitCommand(prefixDir: prefixDir, args: ["regedit", "/S", regFile.path])
        try waitAndShutdownServer(prefixDir: prefixDir)
    }

    private func runWineInitCommand(prefixDir: URL, args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        proc.arguments = ["-x86_64", paths.wineExecutable.path] + args
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefixDir.path
        env["WINEARCH"] = "win64"
        env["WINEDEBUG"] = "-all"
        // Prevent automatic 400 MB Mono & Gecko popups/downloads during minimal prefix init
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml="
        env["PATH"] = "\(paths.wineBinDir.path):/usr/bin:/bin:/usr/sbin:/sbin"
        proc.environment = env
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        try proc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let err = String(decoding: errData, as: UTF8.self)
            throw TinyWinError.commandFailed(command: "wine \(args.joined(separator: " "))", code: proc.terminationStatus, stderr: err)
        }
    }

    private func waitAndShutdownServer(prefixDir: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        proc.arguments = ["-x86_64", paths.wineserverExecutable.path, "-w"]
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefixDir.path
        env["WINEDEBUG"] = "-all"
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
    }

    public struct RunningProcInfo: Sendable {
        public let pid: Int32
        public let rssBytes: Int64
        public let command: String
    }

    /// Inspects active Wine processes tagged with `TINYWIN_BOTTLE=<id>` (or matching prefix path).
    public static func inspectWineProcesses(forBottleID bottleID: String) -> [RunningProcInfo] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axww", "-o", "pid=,rss=,command="]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        let data: Data
        do {
            try proc.run()
            // Drain stdout BEFORE waitUntilExit to prevent 64KB pipe buffer deadlock
            data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
        } catch {
            return []
        }
        let text = String(decoding: data, as: UTF8.self)
        var results: [RunningProcInfo] = []
        let needle = "/Bottles/\(bottleID)/prefix"
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(needle) || (trimmed.contains("wineserver") && trimmed.contains(bottleID)) else {
                continue
            }
            let parts = trimmed.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            if parts.count == 3, let pid = Int32(parts[0]), let rssKB = Int64(parts[1]) {
                results.append(RunningProcInfo(pid: pid, rssBytes: rssKB * 1024, command: String(parts[2])))
            }
        }
        return results
    }
}
