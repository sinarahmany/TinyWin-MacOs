import SwiftUI
import AppKit
import TinyWinCore

@main
struct TinyWinApp: App {
    @State private var state = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("TinyWin") {
            MainContentView(state: state)
                .frame(minWidth: 820, minHeight: 540)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bottle...") {
                    state.showCreateBottleSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!state.runtimeInstalled)
            }
        }
    }
}

struct MainContentView: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 220, ideal: 245, max: 300)
        } detail: {
            if !state.runtimeInstalled {
                RuntimeOnboardingView(state: state)
            } else if let bottle = state.selectedBottle {
                BottleDetailView(state: state, bottle: bottle)
            } else {
                EmptyBottleView(state: state)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    state.showDiagnosticsSheet = true
                } label: {
                    Label("System Status", systemImage: "cpu")
                }
                .help("System, Rosetta 2, Metal & Sandbox Diagnostics")

                Button {
                    state.refreshAll()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh bottles and memory usage")

                Button {
                    state.showCreateBottleSheet = true
                } label: {
                    Label("New Bottle", systemImage: "plus")
                }
                .disabled(!state.runtimeInstalled)
                .help("Create a minimal APFS-cloned Windows bottle")
            }
        }
        .sheet(isPresented: $state.showCreateBottleSheet) {
            CreateBottleSheet(state: state)
        }
        .sheet(isPresented: $state.showDiagnosticsSheet) {
            DiagnosticsSheet(state: state)
        }
        .overlay(alignment: .bottom) {
            if let err = state.errorMessage {
                BannerView(text: err, isError: true) {
                    state.errorMessage = nil
                }
                .padding()
            } else if let msg = state.statusMessage {
                BannerView(text: msg, isError: false) {
                    state.statusMessage = nil
                }
                .padding()
            }
        }
    }
}

struct SidebarView: View {
    @Bindable var state: AppState

    var body: some View {
        List(selection: $state.selectedBottleID) {
            Section("Bottles") {
                ForEach(state.bottles) { bottle in
                    let st = state.bottleStats[bottle.id]
                    HStack(spacing: 10) {
                        Image(systemName: bottle.preset == .game ? "gamecontroller.fill" : "macwindow")
                            .foregroundStyle(bottle.preset == .game ? .purple : .blue)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bottle.name)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if st?.isRunning == true {
                                    Circle()
                                        .fill(.green)
                                        .frame(width: 6, height: 6)
                                    Text(formatByteCount(st?.totalRSSBytes ?? 0))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(bottle.graphics.backend.rawValue.uppercased())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if bottle.security.enableSandbox {
                                    Image(systemName: "lock.shield.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                                if bottle.security.offlineMode {
                                    Image(systemName: "wifi.slash")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(bottle.id)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack(spacing: 8) {
                    Circle()
                        .fill(state.runtimeInstalled ? .green : .orange)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.runtimeInstalled ? "Engine Ready" : "Engine Not Installed")
                            .font(.caption.weight(.semibold))
                        if let m = state.runtimeManifest, state.runtimeInstalled {
                            Text("Wine \(m.wineVersion) · DXMT \(m.dxmtVersion)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Wine 11 + DXMT Metal")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .background(.ultraThinMaterial)
        }
    }
}

struct RuntimeOnboardingView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("TinyWin Engine Setup")
                    .font(.title2.weight(.semibold))
                Text("Downloads a single shared Wine 11 WoW64 + DXMT Metal runtime (~235 MB).\nNo Windows OS VM, no background daemons, and zero bloat.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 16) {
                FeaturePill(icon: "cpu", title: "Rosetta 2 + Metal", detail: state.diagnostics.metalDeviceName ?? "Metal GPU")
                FeaturePill(icon: "lock.shield", title: "Seatbelt Sandbox", detail: "No Z:\\ host access")
                FeaturePill(icon: "bolt", title: "0% Idle Usage", detail: "APFS CoW bottles")
            }

            if state.isInstallingRuntime {
                VStack(spacing: 8) {
                    ProgressView(value: state.installProgress)
                        .frame(width: 340)
                    Text("\(state.installStage) — \(state.installDetail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    state.installRuntime()
                } label: {
                    Label("Install Lean Runtime (~235 MB)", systemImage: "arrow.down.circle.fill")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!state.diagnostics.isReadyForWindowsApps)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyBottleView: View {
    @Bindable var state: AppState

    var body: some View {
        ContentUnavailableView {
            Label("No Bottles Yet", systemImage: "macwindow.badge.plus")
        } description: {
            Text("Create a tiny, isolated Windows bottle to run apps and games natively on macOS.")
        } actions: {
            Button("Create First Bottle") {
                state.showCreateBottleSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct FeaturePill: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 145)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct BannerView: View {
    let text: String
    let isError: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(text)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isError ? Color.red.opacity(0.4) : Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .shadow(radius: 6, y: 2)
        .frame(maxWidth: 560)
    }
}
