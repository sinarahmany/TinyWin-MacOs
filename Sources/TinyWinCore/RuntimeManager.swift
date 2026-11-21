import Foundation

public struct RuntimeInstallProgress: Sendable {
    public let stage: String
    public let fraction: Double // 0.0 ... 1.0
    public let detail: String
}

public final class RuntimeManager: Sendable {
    public static let defaultWineVersion = "11.21"
    public static let defaultWineURL = "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.21/wine-staging-11.21-osx64.tar.xz"

    public static let defaultDXMTVersion = "v0.80"
    public static let defaultDXMTURL = "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz"

    public let paths: TinyWinPaths

    public init(paths: TinyWinPaths = TinyWinPaths()) {
        self.paths = paths
    }

    public var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: paths.wineExecutable.path)
            && fm.isExecutableFile(atPath: paths.wineserverExecutable.path)
            && fm.fileExists(atPath: paths.runtimeManifestURL.path)
    }

    public var isDXMTInstalled: Bool {
        let fm = FileManager.default
        let unixMetal = paths.wineLibDir.appendingPathComponent("x86_64-unix/winemetal.so")
        let d3d11 = paths.wineLibDir.appendingPathComponent("x86_64-windows/d3d11.dll")
        let dxgi = paths.wineLibDir.appendingPathComponent("x86_64-windows/dxgi.dll")
        return fm.fileExists(atPath: unixMetal.path)
            && fm.fileExists(atPath: d3d11.path)
            && fm.fileExists(atPath: dxgi.path)
    }

    public var isD3DMetalInstalled: Bool {
        let fm = FileManager.default
        let fw = paths.d3dMetalDir.appendingPathComponent("D3DMetal.framework")
        let lib = paths.d3dMetalDir.appendingPathComponent("libd3dshared.dylib")
        return fm.fileExists(atPath: fw.path) || fm.fileExists(atPath: lib.path)
    }

    public func loadManifest() -> RuntimeManifest? {
        guard let data = try? Data(contentsOf: paths.runtimeManifestURL) else { return nil }
        return try? JSONDecoder().decode(RuntimeManifest.self, from: data)
    }

    public func runtimeDiskUsageBytes() -> Int64 {
        Self.directorySize(url: paths.runtimeDir)
    }

    /// Downloads and installs the shared lean Wine 11.21 WoW64 + DXMT v0.80 Metal runtime.
    public func installRuntime(
        force: Bool = false,
        onProgress: (@Sendable (RuntimeInstallProgress) -> Void)? = nil
    ) throws {
        let sys = SystemCheck.run()
        if sys.isAppleSilicon && !sys.rosettaInstalled {
            throw TinyWinError.rosettaNotInstalled
        }

        if isInstalled && isDXMTInstalled && !force {
            onProgress?(RuntimeInstallProgress(stage: "Ready", fraction: 1.0, detail: "Runtime already installed"))
            return
        }

        try paths.ensureBaseDirectories()
        let fm = FileManager.default
        let stagingDir = paths.cacheDir.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        // 1. Download Wine
        let wineArchive = stagingDir.appendingPathComponent("wine.tar.xz")
        onProgress?(RuntimeInstallProgress(
            stage: "Downloading Wine \(Self.defaultWineVersion)",
            fraction: 0.05,
            detail: "Fetching shared WoW64 runtime (~218 MB)..."
        ))
        try downloadFile(from: Self.defaultWineURL, to: wineArchive) { frac in
            onProgress?(RuntimeInstallProgress(
                stage: "Downloading Wine \(Self.defaultWineVersion)",
                fraction: 0.05 + frac * 0.45,
                detail: String(format: "%.0f%% downloaded", frac * 100)
            ))
        }

        // 2. Download DXMT
        let dxmtArchive = stagingDir.appendingPathComponent("dxmt.tar.gz")
        onProgress?(RuntimeInstallProgress(
            stage: "Downloading DXMT \(Self.defaultDXMTVersion)",
            fraction: 0.52,
            detail: "Fetching DirectX 10/11 → Metal backend (~18 MB)..."
        ))
        try downloadFile(from: Self.defaultDXMTURL, to: dxmtArchive) { frac in
            onProgress?(RuntimeInstallProgress(
                stage: "Downloading DXMT \(Self.defaultDXMTVersion)",
                fraction: 0.52 + frac * 0.13,
                detail: String(format: "%.0f%% downloaded", frac * 100)
            ))
        }

        // 3. Extract Wine into staging
        onProgress?(RuntimeInstallProgress(
            stage: "Extracting Wine",
            fraction: 0.68,
            detail: "Unpacking Wine \(Self.defaultWineVersion) WoW64..."
        ))
        let wineExtractDir = stagingDir.appendingPathComponent("wine_extract", isDirectory: true)
        try fm.createDirectory(at: wineExtractDir, withIntermediateDirectories: true)
        try runHostTool("/usr/bin/tar", args: ["-xf", wineArchive.path, "-C", wineExtractDir.path])

        guard let extractedApp = try fm.contentsOfDirectory(at: wineExtractDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw TinyWinError.ioError("Downloaded Wine archive did not contain a .app bundle")
        }

        // Replace existing Wine.app atomically
        if fm.fileExists(atPath: paths.wineAppDir.path) {
            try fm.removeItem(at: paths.wineAppDir)
        }
        try fm.moveItem(at: extractedApp, to: paths.wineAppDir)

        // Strip macOS quarantine attribute ONLY on our downloaded runtime so Gatekeeper doesn't block Wine DLLs
        _ = try? runHostTool("/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", paths.wineAppDir.path])

        // Strip unnecessary bloat inside Wine.app (man pages, headers, docs) to keep it lean
        let bloatDirs = [
            paths.wineRootDir.appendingPathComponent("share/man"),
            paths.wineRootDir.appendingPathComponent("share/doc"),
            paths.wineRootDir.appendingPathComponent("include")
        ]
        for dir in bloatDirs where fm.fileExists(atPath: dir.path) {
            try? fm.removeItem(at: dir)
        }

        // 4. Extract & Install DXMT builtin DLLs into Wine
        onProgress?(RuntimeInstallProgress(
            stage: "Installing DXMT Metal Backend",
            fraction: 0.85,
            detail: "Wiring DirectX 10/11 → Apple Metal libraries..."
        ))
        let dxmtExtractDir = stagingDir.appendingPathComponent("dxmt_extract", isDirectory: true)
        try fm.createDirectory(at: dxmtExtractDir, withIntermediateDirectories: true)
        try runHostTool("/usr/bin/tar", args: ["-xzf", dxmtArchive.path, "-C", dxmtExtractDir.path])

        // Keep an unmodified backup of DXMT files in Runtime/DXMT for prefix syncing
        if fm.fileExists(atPath: paths.dxmtDir.path) {
            try fm.removeItem(at: paths.dxmtDir)
        }
        try fm.createDirectory(at: paths.dxmtDir, withIntermediateDirectories: true)
        try installDXMTFiles(from: dxmtExtractDir)

        _ = try? runHostTool("/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", paths.runtimeDir.path])

        // 4b. Apply surgical Wine 11.21 SysLink 1px-wrap infinite-loop hotfix in comctl32_v6.dll
        // Fixes UI thread 100% CPU freeze when Windows apps create 1x1 SysLink controls containing spaces.
        patchComctl32SysLinkBug(in: paths.wineLibDir.appendingPathComponent("x86_64-windows/comctl32_v6.dll"))

        // 5. Save manifest
        let manifest = RuntimeManifest(
            wineVersion: Self.defaultWineVersion,
            wineSourceURL: Self.defaultWineURL,
            dxmtVersion: Self.defaultDXMTVersion,
            dxmtSourceURL: Self.defaultDXMTURL,
            d3dMetalInstalled: isD3DMetalInstalled,
            installedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: paths.runtimeManifestURL, options: .atomic)

        // Verify installation
        guard isInstalled else {
            throw TinyWinError.ioError("Wine executable missing after extraction at \(paths.wineExecutable.path)")
        }

        onProgress?(RuntimeInstallProgress(
            stage: "Complete",
            fraction: 1.0,
            detail: "Wine \(Self.defaultWineVersion) + DXMT \(Self.defaultDXMTVersion) ready"
        ))
    }

    /// Locates DXMT architecture folders (`x86_64-unix`, `x86_64-windows`, `i386-windows`)
    /// inside the extracted archive and installs them cleanly into Wine's builtin library tree.
    private func installDXMTFiles(from extractDir: URL) throws {
        let fm = FileManager.default
        let archFolders = ["x86_64-unix", "x86_64-windows", "i386-windows", "i386-unix"]

        // Find root containing x86_64-unix
        var dxmtRoot = extractDir
        if !fm.fileExists(atPath: extractDir.appendingPathComponent("x86_64-unix").path) {
            if let children = try? fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil) {
                for child in children {
                    if fm.fileExists(atPath: child.appendingPathComponent("x86_64-unix").path) {
                        dxmtRoot = child
                        break
                    }
                }
            }
        }

        var installedCount = 0
        for folder in archFolders {
            let srcFolder = dxmtRoot.appendingPathComponent(folder, isDirectory: true)
            guard fm.fileExists(atPath: srcFolder.path) else { continue }

            // Save backup copy in paths.dxmtDir/<folder>
            let backupFolder = paths.dxmtDir.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)

            // Target inside Wine lib/wine/<folder>
            let wineTargetFolder = paths.wineLibDir.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: wineTargetFolder, withIntermediateDirectories: true)

            let files = try fm.contentsOfDirectory(at: srcFolder, includingPropertiesForKeys: nil)
            for file in files {
                let name = file.lastPathComponent
                let backupDest = backupFolder.appendingPathComponent(name)
                if fm.fileExists(atPath: backupDest.path) { try fm.removeItem(at: backupDest) }
                try fm.copyItem(at: file, to: backupDest)

                let wineDest = wineTargetFolder.appendingPathComponent(name)
                if fm.fileExists(atPath: wineDest.path) { try fm.removeItem(at: wineDest) }
                try fm.copyItem(at: file, to: wineDest)
                installedCount += 1
            }
        }

        if installedCount == 0 {
            throw TinyWinError.ioError("No DXMT libraries found in downloaded archive")
        }
    }

    /// Copies DXMT `winemetal.dll` into a Wine prefix's system32 (and syswow64 if present)
    /// so builtin DXMT hooks resolve seamlessly.
    public func syncDXMTIntoPrefix(_ prefixDir: URL) throws {
        let fm = FileManager.default
        let dll64 = paths.dxmtDir.appendingPathComponent("x86_64-windows/winemetal.dll")
        let sys32 = prefixDir.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        if fm.fileExists(atPath: dll64.path) && fm.fileExists(atPath: sys32.path) {
            let dest = sys32.appendingPathComponent("winemetal.dll")
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: dll64, to: dest)
        }

        let dll32 = paths.dxmtDir.appendingPathComponent("i386-windows/winemetal.dll")
        let syswow = prefixDir.appendingPathComponent("drive_c/windows/syswow64", isDirectory: true)
        if fm.fileExists(atPath: dll32.path) && fm.fileExists(atPath: syswow.path) {
            let dest = syswow.appendingPathComponent("winemetal.dll")
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: dll32, to: dest)
        }
    }

    /// Optional: Import Apple's proprietary Game Porting Toolkit (`D3DMetal.framework` + `libd3dshared.dylib`)
    /// from a user-provided folder (e.g. mounted GPTK DMG `redist/lib/external`) for DirectX 12 support.
    public func importD3DMetal(from externalLibDir: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: externalLibDir.path) else {
            throw TinyWinError.ioError("Folder not found: \(externalLibDir.path)")
        }
        if fm.fileExists(atPath: paths.d3dMetalDir.path) {
            try fm.removeItem(at: paths.d3dMetalDir)
        }
        try fm.createDirectory(at: paths.d3dMetalDir, withIntermediateDirectories: true)

        let items = try fm.contentsOfDirectory(at: externalLibDir, includingPropertiesForKeys: nil)
        var copied = 0
        for item in items {
            let dest = paths.d3dMetalDir.appendingPathComponent(item.lastPathComponent)
            try fm.copyItem(at: item, to: dest)
            copied += 1
        }
        guard copied > 0, isD3DMetalInstalled else {
            throw TinyWinError.ioError("Selected folder does not contain D3DMetal.framework or libd3dshared.dylib")
        }

        if var manifest = loadManifest() {
            manifest.d3dMetalInstalled = true
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: paths.runtimeManifestURL, options: .atomic)
        }
    }

    private func downloadFile(
        from urlString: String,
        to destination: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        // Use macOS built-in curl with HTTP/2, TLS verification, retries, and clean error reporting
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = [
            "-fsSL",
            "--retry", "3",
            "--retry-delay", "2",
            "--connect-timeout", "20",
            "-o", destination.path,
            urlString
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice

        try proc.run()

        // Drain stderr on a background queue so curl can never deadlock on pipe buffer
        let errBox = LockedDataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        if let onProgress {
            var lastReported = 0.0
            while proc.isRunning {
                Thread.sleep(forTimeInterval: 0.35)
                lastReported = min(0.95, lastReported + 0.03)
                onProgress(lastReported)
            }
            onProgress(1.0)
        } else {
            proc.waitUntilExit()
        }
        group.wait()

        if proc.terminationStatus != 0 {
            let errText = String(decoding: errBox.get(), as: UTF8.self)
            throw TinyWinError.downloadFailed("curl exit \(proc.terminationStatus): \(errText)")
        }
    }

    @discardableResult
    private func runHostTool(_ executable: String, args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()

        let outBox = LockedDataBox()
        let errBox = LockedDataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.wait()
        proc.waitUntilExit()

        let out = String(decoding: outBox.get(), as: UTF8.self)
        let err = String(decoding: errBox.get(), as: UTF8.self)
        if proc.terminationStatus != 0 {
            throw TinyWinError.commandFailed(command: executable, code: proc.terminationStatus, stderr: err)
        }
        return out
    }

    public static func directorySize(url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]),
                  vals.isRegularFile == true else { continue }
            total += Int64(vals.totalFileAllocatedSize ?? vals.fileSize ?? 0)
        }
        return total
    }

    /// Patches an upstream Wine 11.21 bug in `comctl32_v6.dll` (`SYSLINK_Render`):
    /// When a SysLink control is initialized at 1x1 pixels and its text contains a space,
    /// `GetTextExtentExPointW` returns `nFit == 0`, matching `BreakChar` without advancing,
    /// causing an infinite 100% CPU loop that freezes the app's UI thread and mouse input.
    /// Replaces 4 bytes of NOP padding (`0f 1f 40 00`) with `test ecx, ecx; jz +0x36` (`85 c9 74 36`).
    public func patchComctl32SysLinkBug(in dllURL: URL) {
        guard let data = try? Data(contentsOf: dllURL) else { return }
        let oldSig = Data([0x66, 0x41, 0x39, 0xD0, 0x75, 0x1F, 0x0F, 0x1F, 0x40, 0x00, 0x89, 0xCD, 0x85, 0xED])
        let newSig = Data([0x66, 0x41, 0x39, 0xD0, 0x75, 0x1F, 0x85, 0xC9, 0x74, 0x36, 0x89, 0xCD, 0x85, 0xED])
        guard let range = data.range(of: oldSig),
              data.range(of: oldSig, in: range.upperBound..<data.endIndex) == nil else {
            return
        }
        var patched = data
        patched.replaceSubrange(range, with: newSig)
        try? patched.write(to: dllURL, options: .atomic)
    }
}

final class LockedDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ newData: Data) {
        lock.lock()
        data = newData
        lock.unlock()
    }
    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
