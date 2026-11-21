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
