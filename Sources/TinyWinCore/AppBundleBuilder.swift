import Foundation

/// Creates tiny (~40 KB) native macOS `.app` launcher bundles for any Windows `.exe`,
/// complete with its extracted Windows icon converted to `.icns`, so Windows apps & games
/// appear in Spotlight, Launchpad, Dock, and Finder like native macOS applications.
public final class AppBundleBuilder: Sendable {
    public let paths: TinyWinPaths

    public init(paths: TinyWinPaths = TinyWinPaths()) {
        self.paths = paths
    }

    public func buildNativeAppWrapper(
        appName: String,
        bottle: BottleConfig,
        executablePath: String,
        arguments: [String] = [],
        tinywinCLIPath: String,
        destinationDir: URL? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let cleanName = sanitizeAppName(appName)
        guard !cleanName.isEmpty else {
            throw TinyWinError.invalidBottleName(appName)
        }

        let outDir = destinationDir ?? paths.defaultAppsExportDir
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        let bundleURL = outDir.appendingPathComponent("\(cleanName).app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)

        if fm.fileExists(atPath: bundleURL.path) {
            try fm.removeItem(at: bundleURL)
        }
        try fm.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        // 1. Try to extract icon from the Windows .exe and convert to macOS .icns
        var hasCustomIcon = false
        let exeURL = URL(fileURLWithPath: executablePath)
        if fm.fileExists(atPath: exeURL.path),
           let icoData = PEInspector.extractIconICO(from: exeURL) {
            let icnsURL = resourcesURL.appendingPathComponent("AppIcon.icns")
            if convertICOToICNS(icoData: icoData, outputICNS: icnsURL) {
                hasCustomIcon = true
            }
        }

        // 2. Write Info.plist
        let bundleID = "dev.tinywin.app.\(bottle.id).\(cleanName.lowercased().replacingOccurrences(of: " ", with: "-"))"
        let iconPlistEntry = hasCustomIcon ? "<key>CFBundleIconFile</key>\n    <string>AppIcon</string>" : ""
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>en</string>
            <key>CFBundleExecutable</key>
            <string>launcher</string>
            <key>CFBundleIdentifier</key>
            <string>\(xmlEscape(bundleID))</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>\(xmlEscape(cleanName))</string>
            <key>CFBundleDisplayName</key>
            <string>\(xmlEscape(cleanName))</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>LSMinimumSystemVersion</key>
            <string>14.0</string>
            <key>NSHighResolutionCapable</key>
            <true/>
            \(iconPlistEntry)
        </dict>
        </plist>
        """
        try infoPlist.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        // 3. Write tiny safe launcher configuration JSON (avoids shell escaping injection completely!)
        struct WrapperConfig: Codable {
            let bottle: String
            let executable: String
            let arguments: [String]
            let tinywinHome: String
        }
        let cfg = WrapperConfig(
            bottle: bottle.id,
            executable: executablePath,
            arguments: arguments,
            tinywinHome: paths.rootDir.path
        )
        let cfgData = try JSONEncoder().encode(cfg)
        try cfgData.write(to: resourcesURL.appendingPathComponent("launch.json"), options: .atomic)

        // 4. Write tiny launcher executable script that invokes `tinywin run-wrapper <launch.json>`
        let launcherScript = """
        #!/bin/zsh
        set -euo pipefail
        DIR="$(cd "$(dirname "$0")/.." && pwd)"
        CONFIG="$DIR/Resources/launch.json"
        CLI='\(shellSingleQuoteEscape(tinywinCLIPath))'
        if [[ ! -x "$CLI" ]]; then
            CLI="$(command -v tinywin || true)"
        fi
        if [[ -z "$CLI" || ! -x "$CLI" ]]; then
            osascript -e 'display alert "TinyWin Runtime Not Found" message "Could not locate the tinywin engine. Please rebuild or reinstall TinyWin."'
            exit 1
        fi
        exec "$CLI" run-wrapper "$CONFIG" "$@"
        """
        let launcherURL = macOSURL.appendingPathComponent("launcher")
        try launcherScript.write(to: launcherURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)

        return bundleURL
    }

    private func convertICOToICNS(icoData: Data, outputICNS: URL) -> Bool {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("tinywin-icon-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempDir) }
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let icoFile = tempDir.appendingPathComponent("icon.ico")
            let pngFile = tempDir.appendingPathComponent("icon.png")
            let iconsetDir = tempDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
            try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
            try icoData.write(to: icoFile)

            // Convert ICO -> base PNG using macOS built-in `sips`
            guard runTool("/usr/bin/sips", ["-s", "format", "png", icoFile.path, "--out", pngFile.path]) else {
                return false
            }

            // Generate standard macOS iconset resolutions
            let sizes: [(String, Int)] = [
                ("icon_16x16.png", 16),
                ("icon_32x32.png", 32),
                ("icon_128x128.png", 128),
                ("icon_256x256.png", 256),
                ("icon_512x512.png", 512)
            ]
            for (name, px) in sizes {
                let out = iconsetDir.appendingPathComponent(name)
                _ = runTool("/usr/bin/sips", ["-z", "\(px)", "\(px)", pngFile.path, "--out", out.path])
            }

            return runTool("/usr/bin/iconutil", ["-c", "icns", iconsetDir.path, "-o", outputICNS.path])
        } catch {
            return false
        }
    }

    private func runTool(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func sanitizeAppName(_ raw: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\*?\"<>|")
        return raw.components(separatedBy: bad).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func shellSingleQuoteEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }
}
