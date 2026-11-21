import Foundation

public struct ExecutionResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let durationSeconds: Double
    public let peakNote: String
}

/// Runs Windows executables (.exe / .msi) inside an isolated, Metal-accelerated TinyWin bottle.
public final class ProcessRunner: Sendable {
    public let paths: TinyWinPaths
    public let runtime: RuntimeManager

    public init(paths: TinyWinPaths = TinyWinPaths()) {
        self.paths = paths
        self.runtime = RuntimeManager(paths: paths)
    }

    /// Launches a Windows executable or built-in Windows command (`cmd`, `notepad`, `winecfg`, etc.).
    public func run(
        bottle: BottleConfig,
        executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        captureOutput: Bool = true,
        validatePE: Bool = true,
        waitForExit: Bool = true
    ) throws -> ExecutionResult {
        guard runtime.isInstalled else { throw TinyWinError.runtimeNotInstalled }

        let prefixDir = paths.bottlePrefixDir(id: bottle.id)
        guard FileManager.default.fileExists(atPath: prefixDir.path) else {
            throw TinyWinError.bottleNotFound(bottle.name)
        }

        // Re-verify Wine-level filesystem isolation and graphics backend DLLs before every launch
        try SandboxBuilder.enforcePrefixIsolation(prefixDir: prefixDir, security: bottle.security)
        try runtime.applyGraphicsBackend(bottle.graphics.backend, toPrefix: prefixDir)

        // Resolve executable path (could be host file path, relative path inside drive_c, or builtin like `cmd`)
        let resolvedExeURL = resolveExecutableURL(executable, prefixDir: prefixDir)
        var extraReadOnlyPaths: [URL] = []
        var isMSI = false
        var wineTargetPath: String? = resolvedExeURL?.path

        if let exeURL = resolvedExeURL {
            if validatePE {
                let info = try PEInspector.inspect(url: exeURL)
                isMSI = info.isMSI
                if info.isDLL {
                    throw TinyWinError.invalidPEFile("Target is a DLL library, not an executable (.exe)")
                }
            } else {
                isMSI = exeURL.pathExtension.lowercased() == "msi"
            }

            // If executable lives outside the bottle, grant minimal read-only access in Seatbelt
            let bottleRoot = paths.bottleDir(id: bottle.id).standardizedFileURL.path
            let exePath = exeURL.standardizedFileURL.path
            if !exePath.hasPrefix(bottleRoot) {
                let parent = exeURL.deletingLastPathComponent().standardizedFileURL
                let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
                let sensitiveRoots = [
                    home,
                    "\(home)/Downloads",
                    "\(home)/Desktop",
                    "\(home)/Documents"
                ]
                if sensitiveRoots.contains(parent.path) {
                    // Only expose the single executable file, never the whole Downloads/Desktop folder!
                    extraReadOnlyPaths.append(exeURL)
                } else {
                    // App/installer lives in its own folder (e.g. multi-file installer with .bin/.cab/.dll siblings).
                    // Expose ONLY this folder read-only in Seatbelt and map it as I:\ so Windows installers
                    // can read sibling data files without needing Z:\ host root access!
                    extraReadOnlyPaths.append(parent)
                    let iDrive = prefixDir.appendingPathComponent("dosdevices/i:")
                    try? FileManager.default.removeItem(at: iDrive)
                    try? FileManager.default.createSymbolicLink(atPath: iDrive.path, withDestinationPath: parent.path)
                    wineTargetPath = "I:\\\(exeURL.lastPathComponent)"
                }
            }
        }

        // Build Wine arguments cleanly (zero shell interpolation!)
        var wineArgs: [String] = []
        if isMSI, let target = wineTargetPath {
            wineArgs = ["msiexec", "/i", target] + arguments
        } else {
            wineArgs = [wineTargetPath ?? executable] + arguments
        }

        // Construct environment
        let env = buildEnvironment(bottle: bottle, prefixDir: prefixDir)

        // Build command (either wrapped in Seatbelt sandbox-exec or direct Rosetta 2 -> Wine)
        let proc = Process()
        let sys = SystemCheck.run()
        let useSandbox = bottle.security.enableSandbox && sys.sandboxExecAvailable

        if useSandbox {
            let profileURL = try SandboxBuilder.writeProfile(
                bottle: bottle,
                paths: paths,
                extraReadOnlyPaths: extraReadOnlyPaths
            )
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            proc.arguments = ["-f", profileURL.path, "/usr/bin/arch", "-x86_64", paths.wineExecutable.path] + wineArgs
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
            proc.arguments = ["-x86_64", paths.wineExecutable.path] + wineArgs
        }

        proc.environment = env

        if let cwd = workingDirectory {
            proc.currentDirectoryURL = cwd
        } else if let exeURL = resolvedExeURL {
            proc.currentDirectoryURL = exeURL.deletingLastPathComponent()
        } else {
            proc.currentDirectoryURL = prefixDir.appendingPathComponent("drive_c", isDirectory: true)
        }

        let outPipe = captureOutput ? Pipe() : nil
        let errPipe = captureOutput ? Pipe() : nil
        var logFileHandle: FileHandle? = nil
        if captureOutput {
            proc.standardOutput = outPipe
            proc.standardError = errPipe
        } else if !waitForExit {
            // For GUI launches, capture stderr/stdout to a tiny single-run log file so users can inspect crashes
            try? FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
            let logURL = paths.logsDir.appendingPathComponent("\(bottle.id)-last.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            if let fh = try? FileHandle(forWritingTo: logURL) {
                logFileHandle = fh
                proc.standardOutput = fh
                proc.standardError = fh
            }
        }

        let start = Date()
        try proc.run()
        try? logFileHandle?.close()

        if !waitForExit {
            return ExecutionResult(
                exitCode: 0,
                stdout: "",
                stderr: "",
                durationSeconds: 0,
                peakNote: "Launched PID \(proc.processIdentifier) asynchronously"
            )
        }

        let outBox = LockedDataBox()
        let errBox = LockedDataBox()
        if captureOutput {
            let group = DispatchGroup()
            if let outPipe {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
            }
            if let errPipe {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
            }
            group.wait()
        }
        proc.waitUntilExit()
        let stdoutData = outBox.get()
        let stderrData = errBox.get()
        let elapsed = Date().timeIntervalSince(start)

        // Auto-reap wineserver cleanly if enabled so zero background daemons linger
        if bottle.autoReapServer {
            try? shutdownServerCleanly(prefixDir: prefixDir)
        }

        return ExecutionResult(
            exitCode: proc.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            durationSeconds: elapsed,
            peakNote: useSandbox ? "Sandboxed (Seatbelt)" : "Unsandboxed"
        )
    }

    /// Cleanly terminates wineserver and all Windows processes belonging to this bottle.
    public func killBottleProcesses(bottle: BottleConfig) throws {
        guard runtime.isInstalled else { return }
        let prefixDir = paths.bottlePrefixDir(id: bottle.id)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        proc.arguments = ["-x86_64", paths.wineserverExecutable.path, "-k"]
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefixDir.path
        env["WINEDEBUG"] = "-all"
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
    }

    private func shutdownServerCleanly(prefixDir: URL) throws {
        // Ask wineserver to exit gracefully once all Windows clients finish
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

    public func buildEnvironment(bottle: BottleConfig, prefixDir: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefixDir.path
        env["WINEARCH"] = "win64"
        env["TINYWIN_BOTTLE"] = bottle.id
        env["PATH"] = "\(paths.wineBinDir.path):/usr/bin:/bin:/usr/sbin:/sbin"
        env["WINEDEBUG"] = bottle.graphics.quietLogs ? "fixme-all,warn-all,err+all" : "fixme-all,err+all"

        // Low-overhead synchronization
        if bottle.graphics.fastSync {
            env["WINEESYNC"] = "1"
            env["WINEMSYNC"] = "1"
        }

        // Prevent automatic Mono/Gecko bloat prompts
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml="

        // Graphics backend configuration
        switch bottle.graphics.backend {
        case .dxmt:
            // DXMT v0.80 Direct3D 10/11 -> Apple Metal (best for 3D games)
            env["DXMT_ENABLE_NVEXT"] = "1"
            env["MTL_SHADER_CACHE_DIR"] = paths.bottleShaderCacheDir(id: bottle.id).path
            env["WINEDLLPATH"] = "\(paths.dxmtDir.path):\(paths.wineLibDir.path)"
        case .wined3d:
            // Stock WineD3D / MoltenVK -> Apple Metal (full Direct2D + SwapDeviceContextState support for Desktop Apps)
            env["WINEDLLOVERRIDES"] = "mscoree,mshtml=;winemetal=d"
        case .d3dmetal:
            if runtime.isD3DMetalInstalled {
                env["D3DMETAL_PATH"] = paths.d3dMetalDir.path
                env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(paths.d3dMetalDir.path):/usr/lib"
                env["ROSETTA_ADVERTISE_AVX"] = "1"
            }
        }

        if bottle.graphics.metalHUD {
            env["MTL_HUD_ENABLED"] = "1"
        }

        // Advertise AVX where supported by Rosetta 2 on Apple Silicon for modern games
        env["ROSETTA_ADVERTISE_AVX"] = "1"

        return env
    }

    private func resolveExecutableURL(_ executable: String, prefixDir: URL) -> URL? {
        let fm = FileManager.default
        // 1. Direct host path
        let direct = URL(fileURLWithPath: executable)
        if fm.fileExists(atPath: direct.path) {
            return direct.standardizedFileURL
        }
        // 2. Relative inside drive_c
        let inDriveC = prefixDir.appendingPathComponent("drive_c").appendingPathComponent(executable)
        if fm.fileExists(atPath: inDriveC.path) {
            return inDriveC.standardizedFileURL
        }
        // 3. Builtin Wine command like `cmd`, `notepad`, `winecfg` -> let Wine resolve it internally
        return nil
    }
}
