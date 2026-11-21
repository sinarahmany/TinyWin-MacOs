import Foundation
import Observation
import AppKit
import TinyWinCore

@MainActor
@Observable
final class AppState {
    let paths = TinyWinPaths()
    let runtime: RuntimeManager
    let bottleManager: BottleManager
    let runner: ProcessRunner
    let bundleBuilder: AppBundleBuilder

    var diagnostics: SystemDiagnostics
    var runtimeInstalled: Bool = false
    var dxmtInstalled: Bool = false
    var d3dMetalInstalled: Bool = false
    var runtimeManifest: RuntimeManifest?
    var runtimeSizeBytes: Int64 = 0

    var bottles: [BottleConfig] = []
    var bottleStats: [String: BottleStats] = [:]
    var selectedBottleID: String?

    var isInstallingRuntime: Bool = false
    var installStage: String = ""
    var installDetail: String = ""
    var installProgress: Double = 0.0

    var isBusy: Bool = false
    var statusMessage: String?
    var errorMessage: String?

    var showCreateBottleSheet: Bool = false
    var showDiagnosticsSheet: Bool = false

    init() {
        self.runtime = RuntimeManager(paths: paths)
        self.bottleManager = BottleManager(paths: paths)
        self.runner = ProcessRunner(paths: paths)
        self.bundleBuilder = AppBundleBuilder(paths: paths)
        self.diagnostics = SystemCheck.run()
        refreshAll()
    }

    var selectedBottle: BottleConfig? {
        bottles.first { $0.id == selectedBottleID }
    }

    func refreshAll() {
        diagnostics = SystemCheck.run()
        runtimeInstalled = runtime.isInstalled
        dxmtInstalled = runtime.isDXMTInstalled
        d3dMetalInstalled = runtime.isD3DMetalInstalled
        runtimeManifest = runtime.loadManifest()
        runtimeSizeBytes = runtimeInstalled ? runtime.runtimeDiskUsageBytes() : 0

        do {
            bottles = try bottleManager.listBottles()
            if selectedBottleID == nil || !bottles.contains(where: { $0.id == selectedBottleID }) {
                selectedBottleID = bottles.first?.id
            }
            refreshStats()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshStats() {
        var next: [String: BottleStats] = [:]
        for b in bottles {
            next[b.id] = bottleManager.stats(for: b)
        }
        bottleStats = next
    }

    func installRuntime(force: Bool = false) {
        guard !isInstallingRuntime else { return }
        isInstallingRuntime = true
        installStage = "Starting..."
        installDetail = "Preparing Wine + DXMT download"
        installProgress = 0.02
        errorMessage = nil

        let rt = self.runtime
        let bm = self.bottleManager

        Task.detached(priority: .userInitiated) {
            do {
                try rt.installRuntime(force: force) { prog in
                    Task { @MainActor [weak self] in
                        self?.installStage = prog.stage
                        self?.installDetail = prog.detail
                        self?.installProgress = prog.fraction
                    }
                }
                await MainActor.run { [weak self] in
                    self?.installStage = "Initializing minimal template"
                    self?.installDetail = "Stripping bloat & configuring APFS CoW template..."
                    self?.installProgress = 0.96
                }
                try bm.ensureTemplatePrefix()
                await MainActor.run { [weak self] in
                    self?.isInstallingRuntime = false
                    self?.installProgress = 1.0
                    self?.statusMessage = "TinyWin Runtime (Wine + DXMT Metal) installed and ready."
                    self?.refreshAll()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isInstallingRuntime = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func createBottle(
        name: String,
        preset: BottlePreset,
        windowsVersion: WindowsVersion,
        security: BottleSecurityConfig
    ) {
        isBusy = true
        errorMessage = nil
        let bm = self.bottleManager

        Task.detached(priority: .userInitiated) {
            do {
                let bottle = try bm.createBottle(
                    name: name,
                    preset: preset,
                    windowsVersion: windowsVersion,
                    security: security
                )
                await MainActor.run { [weak self] in
                    self?.isBusy = false
                    self?.showCreateBottleSheet = false
                    self?.refreshAll()
                    self?.selectedBottleID = bottle.id
                    self?.statusMessage = "Created '\(bottle.name)' using instant APFS cloning."
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isBusy = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func updateBottle(_ bottle: BottleConfig) {
        let bm = self.bottleManager
        do {
            try bm.updateBottle(bottle)
            refreshAll()
            statusMessage = "Updated settings for '\(bottle.name)'."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteBottle(_ bottle: BottleConfig) {
        do {
            try bottleManager.deleteBottle(id: bottle.id)
            refreshAll()
            statusMessage = "Deleted bottle '\(bottle.name)'."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func launchExecutable(in bottle: BottleConfig, path: String, arguments: [String] = [], pinIfFile: Bool = false) {
        errorMessage = nil
        statusMessage = "Launching \(URL(fileURLWithPath: path).lastPathComponent)..."

        if pinIfFile && FileManager.default.fileExists(atPath: path) {
            let appName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            _ = try? bottleManager.pinApp(bottleID: bottle.id, name: appName, executablePath: path, arguments: arguments)
            refreshAll()
        }

        let r = self.runner
        Task.detached(priority: .userInitiated) {
            do {
                _ = try r.run(
                    bottle: bottle,
                    executable: path,
                    arguments: arguments,
                    captureOutput: false,
                    validatePE: FileManager.default.fileExists(atPath: path),
                    waitForExit: false
                )
                try? await Task.sleep(for: .milliseconds(600))
                await MainActor.run { [weak self] in
                    self?.refreshStats()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func exportNativeApp(bottle: BottleConfig, app: PinnedWindowsApp) {
        do {
            let cliPath = locateTinyWinCLI()
            let bundleURL = try bundleBuilder.buildNativeAppWrapper(
                appName: app.name,
                bottle: bottle,
                executablePath: app.executablePath,
                arguments: app.arguments,
                tinywinCLIPath: cliPath
            )
            _ = try bottleManager.pinApp(
                bottleID: bottle.id,
                name: app.name,
                executablePath: app.executablePath,
                arguments: app.arguments,
                nativeBundlePath: bundleURL.path
            )
            refreshAll()
            statusMessage = "Created native Mac app at \(bundleURL.path)"
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func killProcesses(in bottle: BottleConfig) {
        do {
            try runner.killBottleProcesses(bottle: bottle)
            refreshStats()
            statusMessage = "Stopped all processes in '\(bottle.name)' (0% CPU, 0 B RAM)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openDriveC(for bottle: BottleConfig) {
        let driveC = paths.bottlePrefixDir(id: bottle.id).appendingPathComponent("drive_c")
        NSWorkspace.shared.open(driveC)
    }

    func removePinnedApp(bottle: BottleConfig, app: PinnedWindowsApp) {
        do {
            _ = try bottleManager.removePinnedApp(bottleID: bottle.id, appID: app.id)
            refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func locateTinyWinCLI() -> String {
        // 1. Inside TinyWin.app/Contents/MacOS/tinywin-cli (when bundled)
        if let execURL = Bundle.main.executableURL {
            let sibling = execURL.deletingLastPathComponent().appendingPathComponent("tinywin-cli")
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                return sibling.path
            }
        }
        // 2. Standard Homebrew / local bin install
        for candidate in ["/usr/local/bin/tinywin", "/opt/homebrew/bin/tinywin"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "tinywin"
    }
}

func formatByteCount(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: bytes)
}
