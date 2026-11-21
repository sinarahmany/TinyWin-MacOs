import Foundation

/// Builds macOS Seatbelt (sandbox-exec) security profiles and enforces
/// Wine prefix filesystem isolation (removing Z:\ host-root access and
/// unlinking macOS Desktop/Documents/Downloads symlinks).
public enum SandboxBuilder {
    /// Generates a hardened macOS Seatbelt (.sb) profile for a bottle.
    /// In Seatbelt SBPL, the LAST matching rule wins:
    ///   1. Start with `(allow default)` so Rosetta 2, Metal, WindowServer, and CoreAudio work reliably.
    ///   2. Deny ALL writes across `/` except the bottle directory, shader/temp caches, and explicit shared folder.
    ///   3. Deny reading `$HOME` except Wine runtime, this bottle, system fonts/prefs, the launched exe's folder (if external), and explicit shared folder.
    ///   4. Optionally deny all IP network access in offline mode while keeping local Unix sockets for `wineserver`.
    public static func generateProfile(
        bottle: BottleConfig,
        paths: TinyWinPaths,
        extraReadOnlyPaths: [URL] = []
    ) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let bottlePath = paths.bottleDir(id: bottle.id).standardizedFileURL.path
        let runtimePath = paths.runtimeDir.standardizedFileURL.path
        let cachePath = paths.cacheDir.standardizedFileURL.path
        let logsPath = paths.logsDir.standardizedFileURL.path

        var lines: [String] = [
            "(version 1)",
            "; TinyWin Hardened macOS Seatbelt Profile for bottle: \(escapeSBPL(bottle.id))",
            "(allow default)",
            "",
            "; 1. Deny all filesystem writes by default",
            "(deny file-write* (subpath \"/\"))",
            "",
            "; Allow writes ONLY inside this bottle, shader cache, temp/wineserver sockets, and null/tty devices",
            "(allow file-write* (subpath \"\(escapeSBPL(bottlePath))\"))",
            "(allow file-write* (subpath \"\(escapeSBPL(cachePath))\"))",
            "(allow file-write* (subpath \"\(escapeSBPL(logsPath))\"))",
            "(allow file-write* (subpath \"/private/tmp\"))",
            "(allow file-write* (subpath \"/tmp\"))",
            "(allow file-write* (subpath \"/private/var/folders\"))",
            "(allow file-write* (subpath \"/var/folders\"))",
            "(allow file-write* (literal \"/dev/null\"))",
            "(allow file-write* (literal \"/dev/zero\"))",
            "(allow file-write* (literal \"/dev/tty\"))",
            "(allow file-write* (literal \"/dev/dtracehelper\"))",
            "(allow file-write* (regex #\"^/dev/ttys[0-9]+$\"))",
            "(allow file-write* (subpath \"\(escapeSBPL(home))/Library/Caches/com.apple.metal\"))",
            "(allow file-write* (subpath \"\(escapeSBPL(home))/Library/Caches/org.winehq.wine\"))"
        ]

        if let shared = bottle.security.sharedFolderPath, !shared.isEmpty {
            let normShared = URL(fileURLWithPath: shared).standardizedFileURL.path
            lines.append("(allow file-write* (subpath \"\(escapeSBPL(normShared))\"))")
        }

        lines.append(contentsOf: [
            "",
            "; 2. Protect user's personal files in $HOME from unauthorized reads",
            "(deny file-read-data (subpath \"\(escapeSBPL(home))\"))",
            "(allow file-read-data (literal \"\(escapeSBPL(home))\"))",
            "(allow file-read-data (literal \"\(escapeSBPL(home))/Library\"))",
            "(allow file-read-data (literal \"\(escapeSBPL(home))/Library/Application Support\"))",
            "(allow file-read-data (subpath \"\(escapeSBPL(runtimePath))\"))",
            "(allow file-read-data (subpath \"\(escapeSBPL(bottlePath))\"))",
            "(allow file-read-data (subpath \"\(escapeSBPL(cachePath))\"))",
            "(allow file-read-data (subpath \"\(escapeSBPL(home))/Library/Fonts\"))",
            "(allow file-read-data (subpath \"\(escapeSBPL(home))/Library/Preferences\"))",
            "(allow file-read-data (subpath \"\(escapeSBPL(home))/Library/Caches/com.apple.metal\"))",
            "(allow file-read-data (subpath \"\(escapeSBPL(home))/Library/Caches/org.winehq.wine\"))"
        ])

        if let shared = bottle.security.sharedFolderPath, !shared.isEmpty {
            let normShared = URL(fileURLWithPath: shared).standardizedFileURL.path
            lines.append("(allow file-read-data (subpath \"\(escapeSBPL(normShared))\"))")
        }

        for extra in extraReadOnlyPaths {
            let p = extra.standardizedFileURL.path
            // Never allow widening read access to all of $HOME or `/`
            if p != "/" && p != home && !p.isEmpty {
                lines.append("(allow file-read-data (subpath \"\(escapeSBPL(p))\"))")
            }
        }

        // Explicitly re-deny ultra-sensitive directories even if someone passes a broad path
        let alwaysProtected = [
            "\(home)/.ssh",
            "\(home)/.aws",
            "\(home)/.gnupg",
            "\(home)/Library/Keychains",
            "\(home)/Library/Cookies",
            "\(home)/Library/Safari",
            "\(home)/Library/Messages",
            "\(home)/Library/Mail"
        ]
        lines.append("")
        lines.append("; 3. Hard-block sensitive credential stores unconditionally")
        for secret in alwaysProtected {
            lines.append("(deny file-read* file-write* (subpath \"\(escapeSBPL(secret))\"))")
        }

        if bottle.security.offlineMode {
            lines.append(contentsOf: [
                "",
                "; 4. Offline Mode: Block all IP networking while keeping local Unix sockets for wineserver/Cocoa",
                "(deny network-outbound (remote ip))",
                "(deny network-inbound (local ip))",
                "(deny network-bind (local ip))"
            ])
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the Seatbelt profile to disk atomically and returns its URL.
    public static func writeProfile(
        bottle: BottleConfig,
        paths: TinyWinPaths,
        extraReadOnlyPaths: [URL] = []
    ) throws -> URL {
        let profile = generateProfile(bottle: bottle, paths: paths, extraReadOnlyPaths: extraReadOnlyPaths)
        let url = paths.bottleSandboxProfileURL(id: bottle.id)
        try profile.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Enforces Wine-level filesystem isolation inside a prefix:
    /// - Removes `dosdevices/z:` (host root `/` drive) when `disableHostRootDrive == true`
    /// - Configures `dosdevices/s:` when `sharedFolderPath` is set
    /// - Replaces symlinks in `drive_c/users/<user>/{Desktop,Documents,Downloads,Pictures,Music,Videos}` with isolated directories
    public static func enforcePrefixIsolation(prefixDir: URL, security: BottleSecurityConfig) throws {
        let fm = FileManager.default
        let dosdevices = prefixDir.appendingPathComponent("dosdevices", isDirectory: true)
        try fm.createDirectory(at: dosdevices, withIntermediateDirectories: true)

        // 1. Handle Z:\ (host root mapping)
        let zDrive = dosdevices.appendingPathComponent("z:")
        if security.disableHostRootDrive {
            if fm.fileExists(atPath: zDrive.path) || (try? fm.destinationOfSymbolicLink(atPath: zDrive.path)) != nil {
                try? fm.removeItem(at: zDrive)
            }
        } else {
            if (try? fm.destinationOfSymbolicLink(atPath: zDrive.path)) == nil {
                try? fm.createSymbolicLink(atPath: zDrive.path, withDestinationPath: "/")
            }
        }

        // 2. Handle S:\ (optional explicit shared folder)
        let sDrive = dosdevices.appendingPathComponent("s:")
        if fm.fileExists(atPath: sDrive.path) || (try? fm.destinationOfSymbolicLink(atPath: sDrive.path)) != nil {
            try? fm.removeItem(at: sDrive)
        }
        if let shared = security.sharedFolderPath, !shared.isEmpty, fm.fileExists(atPath: shared) {
            try? fm.createSymbolicLink(atPath: sDrive.path, withDestinationPath: shared)
        }

        // 2b. Remove any stale temporary external-folder mount (I:\) before launch sets a fresh one if needed
        let iDrive = dosdevices.appendingPathComponent("i:")
        if fm.fileExists(atPath: iDrive.path) || (try? fm.destinationOfSymbolicLink(atPath: iDrive.path)) != nil {
            try? fm.removeItem(at: iDrive)
        }

        // 3. Replace user-folder symlinks with isolated directories inside the bottle
        if security.isolateUserFolders {
            let usersDir = prefixDir.appendingPathComponent("drive_c/users", isDirectory: true)
            if let userDirs = try? fm.contentsOfDirectory(at: usersDir, includingPropertiesForKeys: nil) {
                let foldersToIsolate = [
                    "Desktop", "Documents", "My Documents", "Downloads",
                    "Music", "My Music", "Pictures", "My Pictures",
                    "Videos", "My Videos", "Templates"
                ]
                for userDir in userDirs {
                    for folder in foldersToIsolate {
                        let target = userDir.appendingPathComponent(folder)
                        if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                            try? fm.removeItem(at: target)
                            try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                        }
                    }
                }
            }
        }
    }

    private static func escapeSBPL(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
