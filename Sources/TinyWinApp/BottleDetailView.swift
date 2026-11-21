import SwiftUI
import UniformTypeIdentifiers
import TinyWinCore

struct BottleDetailView: View {
    @Bindable var state: AppState
    let bottle: BottleConfig

    @State private var isDropTargeted = false
    @State private var showFileImporter = false
    @State private var showFolderImporter = false
    @State private var confirmDelete = false

    private var stats: BottleStats? {
        state.bottleStats[bottle.id]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                dropLaunchSection
                pinnedAppsSection
                settingsGridSection
                toolsSection
            }
            .padding(24)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "exe") ?? .data,
                UTType(filenameExtension: "msi") ?? .data
            ],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.handleDroppedOrSelectedURL(url, in: bottle)
            }
        }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.handleDroppedOrSelectedURL(url, in: bottle)
            }
        }
        .confirmationDialog(
            "Delete bottle '\(bottle.name)'?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                state.deleteBottle(bottle)
            }
        } message: {
            Text("This removes the bottle's isolated C:\\ drive and configuration. Your macOS files are untouched.")
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(bottle.name)
                        .font(.largeTitle.weight(.semibold))
                    Text(bottle.windowsVersion.displayName)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                HStack(spacing: 14) {
                    Label(
                        stats?.isRunning == true
                            ? "Running (\(formatByteCount(stats?.totalRSSBytes ?? 0)) RAM)"
                            : "Idle · 0% CPU · 0 B RAM",
                        systemImage: stats?.isRunning == true ? "bolt.circle.fill" : "moon.zzz"
                    )
                    .foregroundStyle(stats?.isRunning == true ? .green : .secondary)

                    Label(
                        "Disk: \(formatByteCount(stats?.diskUsageBytes ?? 0))",
                        systemImage: "internaldrive"
                    )
                    .foregroundStyle(.secondary)
                }
                .font(.callout.monospacedDigit())
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Run .exe / .msi", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showFolderImporter = true
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .help("Install from a multi-file folder or import a portable Windows app/game folder")

                if stats?.isRunning == true {
                    Button(role: .destructive) {
                        state.killProcesses(in: bottle)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var dropLaunchSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.title2)
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
            Text("Drop any Windows .exe, .msi, or entire app/installer folder here")
                .font(.callout.weight(.medium))
            Text("Multi-file installers mount read-only as I:\\ · Portable folders clone cleanly into C:\\Apps")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6])
                )
                .background(
                    (isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    state.handleDroppedOrSelectedURL(url, in: bottle)
                }
            }
            return true
        }
    }

    private var pinnedAppsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pinned Apps & Games")
                .font(.headline)

            if bottle.pinnedApps.isEmpty {
                Text("No pinned apps yet. Run or drop an .exe to pin it here, then export it as a standalone native macOS .app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 8) {
                    ForEach(bottle.pinnedApps) { app in
                        HStack(spacing: 12) {
                            Image(systemName: "app.fill")
                                .font(.title2)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.body.weight(.medium))
                                Text(app.executablePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("Make Mac .app") {
                                state.exportNativeApp(bottle: bottle, app: app)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Launch") {
                                state.launchExecutable(in: bottle, path: app.executablePath, arguments: app.arguments)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button {
                                state.removePinnedApp(bottle: bottle, app: app)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private var settingsGridSection: some View {
        HStack(alignment: .top, spacing: 16) {
            // Security Card
            VStack(alignment: .leading, spacing: 12) {
                Label("Security & Isolation", systemImage: "lock.shield.fill")
                    .font(.headline)
                    .foregroundStyle(.green)

                Toggle("macOS Seatbelt Sandbox", isOn: binding(\.security.enableSandbox))
                Toggle("Block Host Root Drive (No Z:\\)", isOn: binding(\.security.disableHostRootDrive))
                Toggle("Isolate Desktop & Documents", isOn: binding(\.security.isolateUserFolders))
                Toggle("Offline Mode (Block IP Network)", isOn: binding(\.security.offlineMode))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            // Graphics & Performance Card
            VStack(alignment: .leading, spacing: 12) {
                Label("Graphics & Optimization", systemImage: "bolt.fill")
                    .font(.headline)
                    .foregroundStyle(.purple)

                Picker("Backend", selection: binding(\.graphics.backend)) {
                    ForEach(GraphicsBackend.allCases, id: \.self) { backend in
                        Text(backend.displayName)
                            .tag(backend)
                    }
                }
                .labelsHidden()

                Toggle("Retina HiDPI Mode", isOn: retinaBinding)
                Picker("Window Scale", selection: binding(\.graphics.dpi)) {
                    Text("100% (96 DPI)").tag(96)
                    Text("125% (120 DPI)").tag(120)
                    Text("150% (144 DPI)").tag(144)
                    Text("200% Retina (192 DPI)").tag(192)
                    Text("250% Large (240 DPI)").tag(240)
                }
                Toggle("Fast Sync (ESync / MSync)", isOn: binding(\.graphics.fastSync))
                Toggle("Apple Metal Performance HUD", isOn: binding(\.graphics.metalHUD))
                Toggle("Auto-Stop Server on Exit", isOn: binding(\.autoReapServer))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var toolsSection: some View {
        HStack(spacing: 10) {
            Button {
                state.openDriveC(for: bottle)
            } label: {
                Label("Open C:\\ in Finder", systemImage: "folder")
            }

            Button {
                state.launchExecutable(in: bottle, path: "winecfg")
            } label: {
                Label("Wine Config", systemImage: "slider.horizontal.3")
            }

            Button {
                state.launchExecutable(in: bottle, path: "cmd")
            } label: {
                Label("Windows CMD", systemImage: "terminal")
            }

            Button {
                state.openLastLog(for: bottle)
            } label: {
                Label("Last Log", systemImage: "doc.text")
            }

            Spacer()

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete Bottle", systemImage: "trash")
            }
        }
        .buttonStyle(.bordered)
    }

    private var retinaBinding: Binding<Bool> {
        Binding(
            get: { bottle.graphics.retinaMode },
            set: { newValue in
                var copy = bottle
                copy.graphics.retinaMode = newValue
                // Pair RetinaMode with proper DPI so windows never shrink to half-size
                if newValue && copy.graphics.dpi < 144 {
                    copy.graphics.dpi = 192
                } else if !newValue && copy.graphics.dpi >= 192 {
                    copy.graphics.dpi = 96
                }
                state.updateBottle(copy)
            }
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<BottleConfig, Value>) -> Binding<Value> {
        Binding(
            get: { bottle[keyPath: keyPath] },
            set: { newValue in
                var copy = bottle
                copy[keyPath: keyPath] = newValue
                state.updateBottle(copy)
            }
        )
    }
}
