import SwiftUI
import TinyWinCore

struct CreateBottleSheet: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var preset: BottlePreset = .app
    @State private var windowsVersion: WindowsVersion = .win10
    @State private var enableSandbox: Bool = true
    @State private var disableHostRoot: Bool = true
    @State private var offlineMode: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Minimal Bottle")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Bottle Name", text: $name, prompt: Text("e.g. Productivity or Steam Games"))

                Picker("Optimization Preset", selection: $preset) {
                    ForEach(BottlePreset.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }

                Picker("Windows Version", selection: $windowsVersion) {
                    ForEach(WindowsVersion.allCases, id: \.self) { v in
                        Text(v.displayName).tag(v)
                    }
                }

                Section("Security") {
                    Toggle("Enforce macOS Seatbelt Sandbox", isOn: $enableSandbox)
                    Toggle("Block Z:\\ Host Filesystem Access", isOn: $disableHostRoot)
                    Toggle("Offline Mode (Block IP Network)", isOn: $offlineMode)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("Cloned via APFS copy-on-write (~0 MB extra disk space)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(state.isBusy ? "Creating..." : "Create") {
                    let sec = BottleSecurityConfig(
                        enableSandbox: enableSandbox,
                        disableHostRootDrive: disableHostRoot,
                        isolateUserFolders: true,
                        offlineMode: offlineMode
                    )
                    state.createBottle(
                        name: name,
                        preset: preset,
                        windowsVersion: windowsVersion,
                        security: sec
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || state.isBusy)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct DiagnosticsSheet: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("System Diagnostics", systemImage: "cpu")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            let d = state.diagnostics
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                DiagRow(label: "macOS", value: d.macOSVersion, ok: true)
                DiagRow(label: "Processor", value: "\(d.cpuBrand) (\(d.architecture))", ok: true)
                DiagRow(label: "Rosetta 2", value: d.rosettaInstalled ? "Installed & Active" : "Not Installed", ok: d.rosettaInstalled)
                DiagRow(label: "Metal GPU", value: "\(d.metalDeviceName ?? "None")\(d.supportsMetal3 ? " (Metal 3)" : "")", ok: d.metalDeviceName != nil)
                DiagRow(label: "Seatbelt Sandbox", value: d.sandboxExecAvailable ? "Available" : "Unavailable", ok: d.sandboxExecAvailable)
                DiagRow(label: "Shared Runtime", value: state.runtimeInstalled ? "Wine \(state.runtimeManifest?.wineVersion ?? "") (\(formatByteCount(state.runtimeSizeBytes)))" : "Not Installed", ok: state.runtimeInstalled)
                DiagRow(label: "DXMT (DX10/11)", value: state.dxmtInstalled ? "Installed (\(state.runtimeManifest?.dxmtVersion ?? "")) → Metal" : "Missing", ok: state.dxmtInstalled)
                DiagRow(label: "D3DMetal (DX12)", value: state.d3dMetalInstalled ? "Imported" : "Optional (Not Imported)", ok: true)
            }
            .padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct FolderImportSheet: View {
    @Bindable var state: AppState
    let pending: AppState.PendingFolderImport
    @Environment(\.dismiss) private var dismiss

    @State private var selectedExe: URL
    @State private var copyIntoBottle: Bool

    init(state: AppState, pending: AppState.PendingFolderImport) {
        self.state = state
        self.pending = pending
        let first = pending.executables.first ?? pending.folderURL
        _selectedExe = State(initialValue: first)
        let name = first.deletingPathExtension().lastPathComponent.lowercased()
        let looksLikeInstaller = name.contains("setup") || name.contains("install") || first.pathExtension.lowercased() == "msi"
        // Default to read-only I:\ mount for installers, and APFS copy into C:\Apps for portable apps/games
        _copyIntoBottle = State(initialValue: !looksLikeInstaller)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill.badge.gearshape")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending.folderURL.lastPathComponent)
                        .font(.title3.weight(.semibold))
                    Text("Found \(pending.executables.count) executable\(pending.executables.count == 1 ? "" : "s") in this folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                Picker("Executable to Run", selection: $selectedExe) {
                    ForEach(pending.executables, id: \.self) { url in
                        Text(relativeLabel(for: url)).tag(url)
                    }
                }

                Picker("Install Mode", selection: $copyIntoBottle) {
                    Text("Run Installer from Folder (Read-Only I:\\)").tag(false)
                    Text("Import Portable App/Game into C:\\Apps (Read/Write)").tag(true)
                }
                .pickerStyle(.radioGroup)
            }
            .formStyle(.grouped)

            Text(copyIntoBottle
                 ? "Clones the entire folder into C:\\Apps using APFS copy-on-write (~0 extra disk space) so portable apps & games can save settings/progress inside the sandbox."
                 : "Mounts only this folder read-only as I:\\ so multi-file installers can read sibling .bin/.cab/.dll files and install into C:\\Program Files without touching your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(copyIntoBottle ? "Import & Launch" : "Run Installer") {
                    state.importAndLaunchFolder(
                        bottle: pending.bottle,
                        folderURL: pending.folderURL,
                        selectedExecutable: selectedExe,
                        copyIntoBottle: copyIntoBottle
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func relativeLabel(for url: URL) -> String {
        let base = pending.folderURL.standardizedFileURL.path
        let rel = url.standardizedFileURL.path
            .replacingOccurrences(of: base, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rel.isEmpty ? url.lastPathComponent : rel
    }
}

private struct DiagRow: View {
    let label: String
    let value: String
    let ok: Bool

    var body: some View {
        GridRow {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                Text(value)
                    .font(.callout.monospacedDigit())
            }
        }
    }
}
