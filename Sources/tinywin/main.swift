import Foundation
import TinyWinCore

struct WrapperLaunchConfig: Codable {
    let bottle: String
    let executable: String
    let arguments: [String]
    let tinywinHome: String
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

func printUsage() {
    print("""
    TinyWin — Ultra-lightweight, sandboxed Windows app & game runner for macOS

    USAGE:
      tinywin doctor                               Check macOS, Rosetta 2, Metal, Sandbox & Runtime
      tinywin setup [--force]                      Install shared Wine 11 + DXMT Metal runtime
      tinywin create <name> [options]              Create a bloat-stripped, isolated bottle (APFS CoW)
          --preset <app|game>                      Default: app
          --win <win10|win11|win7>                 Default: win10
          --offline                                Block all IP networking inside this bottle
          --no-sandbox                             Disable macOS Seatbelt sandbox
          --shared <folder>                        Expose one host folder as S:\\
      tinywin list                                 List all bottles, security, disk & RAM usage
      tinywin run <bottle> <exe|cmd> [args...]     Run a Windows .exe, .msi, or builtin (cmd, notepad, winecfg)
      tinywin import <bottle> <folder>             Import a multi-file portable app/game folder into C:\\Apps (APFS CoW)
      tinywin wrap <bottle> <exe> [options]        Create a native macOS .app launcher for a Windows .exe
          --name <AppName>                         Custom macOS .app name
          --out <dir>                              Output directory (default: ~/Applications/TinyWin Apps)
      tinywin inspect <exe>                        Inspect a Windows PE executable (arch, subsystem, icon)
      tinywin scale <bottle> <dpi> [--retina on|off]  Adjust window DPI scale (96=100%, 144=150%, 192=200% Retina)
      tinywin import-d3dmetal <dir>                Import Apple D3DMetal libraries for DirectX 12
      tinywin kill <bottle>                        Stop all running processes in a bottle
      tinywin delete <bottle>                      Delete a bottle permanently
    """)
}

func main() -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        printUsage()
        return 0
    }

    let paths = TinyWinPaths()
    let runtime = RuntimeManager(paths: paths)
    let bottles = BottleManager(paths: paths)
    let runner = ProcessRunner(paths: paths)

    do {
        switch command {
        case "help", "-h", "--help":
            printUsage()
            return 0

        case "doctor":
            let sys = SystemCheck.run()
            print("TinyWin System Diagnostics")
            print("──────────────────────────")
            print("macOS:            \(sys.macOSVersion)")
            print("CPU:              \(sys.cpuBrand) (\(sys.architecture))")
            print("Rosetta 2:        \(sys.rosettaInstalled ? "OK (Installed)" : "MISSING — run: softwareupdate --install-rosetta")")
            print("Metal GPU:        \(sys.metalDeviceName ?? "Unavailable")\(sys.supportsMetal3 ? " (Metal 3)" : "")")
            print("Seatbelt Sandbox: \(sys.sandboxExecAvailable ? "OK (/usr/bin/sandbox-exec)" : "Unavailable")")
            print("Memory / Disk:    \(String(format: "%.0f GB RAM", sys.totalMemoryGB)) / \(String(format: "%.1f GB free", sys.freeDiskGB))")
            print("TinyWin Home:     \(paths.rootDir.path)")
            if let manifest = runtime.loadManifest(), runtime.isInstalled {
                print("Wine Runtime:     OK (Wine \(manifest.wineVersion) WoW64, \(formatBytes(runtime.runtimeDiskUsageBytes())))")
                print("DXMT (DX10/11):   \(runtime.isDXMTInstalled ? "OK (DXMT \(manifest.dxmtVersion) → Metal)" : "Missing")")
                print("D3DMetal (DX12):  \(runtime.isD3DMetalInstalled ? "OK (Imported)" : "Not imported (optional)")")
            } else {
                print("Wine Runtime:     Not installed — run `tinywin setup`")
            }
            return sys.isReadyForWindowsApps ? 0 : 1

        case "setup":
            let force = args.contains("--force")
            print("Setting up TinyWin lean runtime (Wine \(RuntimeManager.defaultWineVersion) + DXMT \(RuntimeManager.defaultDXMTVersion))...")
            try runtime.installRuntime(force: force) { progress in
                let pct = Int(progress.fraction * 100)
                print("[\(String(format: "%3d", pct))%] \(progress.stage): \(progress.detail)")
                fflush(stdout)
            }
            print("Preparing minimal bloat-stripped template bottle...")
            try bottles.ensureTemplatePrefix()
            print("Done! Runtime size: \(formatBytes(runtime.runtimeDiskUsageBytes()))")
            return 0

        case "create":
            guard args.count >= 2 else {
                fputs("Error: Missing bottle name.\n", stderr)
                return 2
            }
            let name = args[1]
            var preset: BottlePreset = .app
            var winVer: WindowsVersion = .win10
            var security = BottleSecurityConfig()

            var i = 2
            while i < args.count {
                switch args[i] {
                case "--preset":
                    i += 1
                    if i < args.count, let p = BottlePreset(rawValue: args[i].lowercased()) { preset = p }
                case "--win":
                    i += 1
                    if i < args.count, let v = WindowsVersion(rawValue: args[i].lowercased()) { winVer = v }
                case "--offline":
                    security.offlineMode = true
                case "--no-sandbox":
                    security.enableSandbox = false
                case "--shared":
                    i += 1
                    if i < args.count { security.sharedFolderPath = args[i] }
                default:
                    break
                }
                i += 1
            }

            let t0 = Date()
            let bottle = try bottles.createBottle(
                name: name,
                preset: preset,
                windowsVersion: winVer,
                security: security
            )
            let dt = Date().timeIntervalSince(t0)
            let st = bottles.stats(for: bottle)
            print("Created bottle '\(bottle.name)' (id: \(bottle.id)) in \(String(format: "%.2fs", dt))")
            print("  Preset:   \(bottle.preset.displayName)")
            print("  Graphics: \(bottle.graphics.backend.displayName) | Retina: \(bottle.graphics.retinaMode ? "ON" : "OFF")")
            print("  Security: Sandbox=\(bottle.security.enableSandbox ? "ON" : "OFF"), No-Z:=\(bottle.security.disableHostRootDrive ? "ON" : "OFF"), Offline=\(bottle.security.offlineMode ? "ON" : "OFF")")
            print("  Disk:     \(formatBytes(st.diskUsageBytes)) (APFS copy-on-write cloned)")
            return 0

        case "list":
            let list = try bottles.listBottles()
            if list.isEmpty {
                print("No bottles yet. Create one with: tinywin create Main")
                return 0
            }
            for b in list {
                let st = bottles.stats(for: b)
                let status = st.isRunning
                    ? "RUNNING (\(st.runningProcessCount) procs, \(formatBytes(st.totalRSSBytes)) RAM)"
                    : "Idle (0% CPU, 0 B RAM)"
                let sec = [
                    b.security.enableSandbox ? "Sandboxed" : "Unsandboxed",
                    b.security.disableHostRootDrive ? "No-Z:" : "Host-Z:",
                    b.security.offlineMode ? "Offline" : "Online"
                ].joined(separator: ", ")
                print("• \(b.name) [\(b.id)] — \(b.preset.rawValue) | \(b.graphics.backend.rawValue.uppercased()) | \(sec) | \(formatBytes(st.diskUsageBytes)) | \(status)")
            }
            return 0

        case "run":
            guard args.count >= 3 else {
                fputs("Error: Usage: tinywin run <bottle> <exe|cmd> [args...]\n", stderr)
                return 2
            }
            let bottle = try bottles.loadBottle(idOrName: args[1])
            let exe = args[2]
            let exeArgs = Array(args.dropFirst(3))
            let result = try runner.run(
                bottle: bottle,
                executable: exe,
                arguments: exeArgs,
                captureOutput: false,
                validatePE: true,
                waitForExit: true
            )
            return result.exitCode

        case "run-wrapper":
            guard args.count >= 2 else { return 2 }
            let configURL = URL(fileURLWithPath: args[1])
            let data = try Data(contentsOf: configURL)
            let cfg = try JSONDecoder().decode(WrapperLaunchConfig.self, from: data)
            let customPaths = TinyWinPaths(rootDir: URL(fileURLWithPath: cfg.tinywinHome, isDirectory: true))
            let customBottles = BottleManager(paths: customPaths)
            let customRunner = ProcessRunner(paths: customPaths)
            let bottle = try customBottles.loadBottle(idOrName: cfg.bottle)
            let extraArgs = Array(args.dropFirst(2))
            let result = try customRunner.run(
                bottle: bottle,
                executable: cfg.executable,
                arguments: cfg.arguments + extraArgs,
                captureOutput: false,
                validatePE: false,
                waitForExit: true
            )
            return result.exitCode

        case "import":
            guard args.count >= 3 else {
                fputs("Error: Usage: tinywin import <bottle> <folder>\n", stderr)
                return 2
            }
            let bottle = try bottles.loadBottle(idOrName: args[1])
            let folder = URL(fileURLWithPath: args[2], isDirectory: true)
            let dest = try bottles.importFolder(folder, into: bottle)
            let exes = bottles.discoverExecutables(in: dest)
            print("Imported folder into bottle '\(bottle.name)' at: \(dest.path)")
            if let primary = exes.first {
                let appName = primary.deletingPathExtension().lastPathComponent
                _ = try? bottles.pinApp(bottleID: bottle.id, name: appName, executablePath: primary.path)
                print("Pinned primary executable: \(primary.lastPathComponent)")
            }
            if exes.count > 1 {
                print("Other executables found: \(exes.dropFirst().map(\.lastPathComponent).joined(separator: ", "))")
            }
            return 0

        case "wrap":
            guard args.count >= 3 else {
                fputs("Error: Usage: tinywin wrap <bottle> <exe> [--name AppName] [--out dir]\n", stderr)
                return 2
            }
            let bottle = try bottles.loadBottle(idOrName: args[1])
            let exePath = args[2]
            var appName = URL(fileURLWithPath: exePath).deletingPathExtension().lastPathComponent
            var outDir: URL? = nil
            var i = 3
            while i < args.count {
                if args[i] == "--name", i + 1 < args.count {
                    appName = args[i + 1]; i += 2
                } else if args[i] == "--out", i + 1 < args.count {
                    outDir = URL(fileURLWithPath: args[i + 1], isDirectory: true); i += 2
                } else {
                    i += 1
                }
            }
            let cliPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
            let builder = AppBundleBuilder(paths: paths)
            let bundle = try builder.buildNativeAppWrapper(
                appName: appName,
                bottle: bottle,
                executablePath: exePath,
                tinywinCLIPath: cliPath,
                destinationDir: outDir
            )
            _ = try? bottles.pinApp(
                bottleID: bottle.id,
                name: appName,
                executablePath: exePath,
                nativeBundlePath: bundle.path
            )
            print("Created native macOS app wrapper: \(bundle.path)")
            return 0

        case "inspect":
            guard args.count >= 2 else {
                fputs("Error: Usage: tinywin inspect <path-to-exe>\n", stderr)
                return 2
            }
            let url = URL(fileURLWithPath: args[1])
            let info = try PEInspector.inspect(url: url)
            let hasIcon = PEInspector.extractIconICO(from: url) != nil
            print("File:         \(info.path)")
            print("Type:         \(info.isMSI ? "MSI Installer" : (info.isDLL ? "DLL Library" : "Windows Executable (.exe)"))")
            print("Architecture: \(info.architecture.rawValue)")
            print("Subsystem:    \(info.subsystem.rawValue)")
            print("Size:         \(formatBytes(info.fileSizeBytes))")
            print("Icon:         \(hasIcon ? "Embedded icon detected" : "None")")
            return 0

        case "scale":
            guard args.count >= 3, let dpi = Int(args[2]) else {
                fputs("Error: Usage: tinywin scale <bottle> <dpi> [--retina on|off]\n", stderr)
                return 2
            }
            var bottle = try bottles.loadBottle(idOrName: args[1])
            bottle.graphics.dpi = max(96, min(384, dpi))
            if let idx = args.firstIndex(of: "--retina"), idx + 1 < args.count {
                bottle.graphics.retinaMode = (args[idx + 1].lowercased() == "on" || args[idx + 1].lowercased() == "true")
            }
            try bottles.updateBottle(bottle)
            print("Updated '\(bottle.name)': Window Scale = \(bottle.graphics.dpi) DPI (\(Int(round(Double(bottle.graphics.dpi) / 96.0 * 100)))%), Retina = \(bottle.graphics.retinaMode ? "ON" : "OFF")")
            return 0

        case "import-d3dmetal":
            guard args.count >= 2 else {
                fputs("Error: Usage: tinywin import-d3dmetal <path-to-gptk-lib-external>\n", stderr)
                return 2
            }
            try runtime.importD3DMetal(from: URL(fileURLWithPath: args[1], isDirectory: true))
            print("Successfully imported Apple D3DMetal for DirectX 12 support.")
            return 0

        case "kill":
            guard args.count >= 2 else { return 2 }
            let bottle = try bottles.loadBottle(idOrName: args[1])
            try runner.killBottleProcesses(bottle: bottle)
            print("Stopped all Windows processes in bottle '\(bottle.name)'.")
            return 0

        case "delete":
            guard args.count >= 2 else { return 2 }
            try bottles.deleteBottle(id: args[1])
            print("Deleted bottle '\(args[1])'.")
            return 0

        default:
            fputs("Unknown command: \(command)\n", stderr)
            printUsage()
            return 2
        }
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

exit(main())
