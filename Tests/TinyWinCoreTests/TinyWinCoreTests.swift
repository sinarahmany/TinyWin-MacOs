import XCTest
@testable import TinyWinCore

final class TinyWinCoreTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinywin-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeMinimalPEBytes(machine: UInt16, subsystem: UInt16, isDLL: Bool = false) -> Data {
        var data = Data(count: 512)
        // DOS header 'MZ'
        data[0] = 0x4D
        data[1] = 0x5A
        // e_lfanew = 0x80
        data[0x3C] = 0x80
        // PE\0\0 at 0x80
        data[0x80] = 0x50
        data[0x81] = 0x45
        data[0x82] = 0x00
        data[0x83] = 0x00
        // Machine at 0x84
        data[0x84] = UInt8(machine & 0xFF)
        data[0x85] = UInt8((machine >> 8) & 0xFF)
        // Characteristics at 0x80 + 22
        let chars: UInt16 = isDLL ? 0x2002 : 0x0002
        data[0x80 + 22] = UInt8(chars & 0xFF)
        data[0x80 + 23] = UInt8((chars >> 8) & 0xFF)
        // Optional header magic at 0x80 + 24 (0x20B for PE32+, 0x10B for PE32)
        let optMagic: UInt16 = (machine == 0x8664) ? 0x020B : 0x010B
        data[0x80 + 24] = UInt8(optMagic & 0xFF)
        data[0x80 + 25] = UInt8((optMagic >> 8) & 0xFF)
        // Subsystem at OptionalHeader + 68
        data[0x80 + 24 + 68] = UInt8(subsystem & 0xFF)
        data[0x80 + 24 + 69] = UInt8((subsystem >> 8) & 0xFF)
        return data
    }

    func testPEInspectorValidates64BitGUI() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("game64.exe")
        try makeMinimalPEBytes(machine: 0x8664, subsystem: 2).write(to: exe)

        let info = try PEInspector.inspect(url: exe)
        XCTAssertEqual(info.architecture, .x64)
        XCTAssertEqual(info.subsystem, .windowsGUI)
        XCTAssertFalse(info.isDLL)
        XCTAssertFalse(info.isMSI)
    }

    func testPEInspectorValidates32BitConsoleAndDLL() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cli = dir.appendingPathComponent("tool32.exe")
        try makeMinimalPEBytes(machine: 0x014C, subsystem: 3, isDLL: false).write(to: cli)
        let cliInfo = try PEInspector.inspect(url: cli)
        XCTAssertEqual(cliInfo.architecture, .x86)
        XCTAssertEqual(cliInfo.subsystem, .windowsConsole)
        XCTAssertFalse(cliInfo.isDLL)

        let dll = dir.appendingPathComponent("lib.dll")
        try makeMinimalPEBytes(machine: 0x8664, subsystem: 2, isDLL: true).write(to: dll)
        let dllInfo = try PEInspector.inspect(url: dll)
        XCTAssertTrue(dllInfo.isDLL)
    }

    func testPEInspectorRejectsNonPE() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("fake.exe")
        try Data("not a windows executable at all".utf8).write(to: bad)

        XCTAssertThrowsError(try PEInspector.inspect(url: bad))
    }

    func testSandboxProfileBlocksSensitivePathsAndOfflineNetwork() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = TinyWinPaths(rootDir: dir)
        let bottle = BottleConfig(
            id: "secure-box",
            name: "Secure Box",
            security: BottleSecurityConfig(
                enableSandbox: true,
                disableHostRootDrive: true,
                isolateUserFolders: true,
                offlineMode: true
            )
        )

        let profile = SandboxBuilder.generateProfile(bottle: bottle, paths: paths)
        XCTAssertTrue(profile.contains("(deny file-write* (subpath \"/\"))"))
        XCTAssertTrue(profile.contains(".ssh"))
        XCTAssertTrue(profile.contains("Library/Keychains"))
        XCTAssertTrue(profile.contains("(deny network-outbound (remote ip))"))
    }

    func testPrefixIsolationRemovesZDriveAndUnlinksUserFolders() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let dos = dir.appendingPathComponent("dosdevices", isDirectory: true)
        let userDir = dir.appendingPathComponent("drive_c/users/testuser", isDirectory: true)
        try fm.createDirectory(at: dos, withIntermediateDirectories: true)
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)

        // Simulate Wine's unsafe defaults
        let zDrive = dos.appendingPathComponent("z:")
        try fm.createSymbolicLink(atPath: zDrive.path, withDestinationPath: "/")
        let docsLink = userDir.appendingPathComponent("Documents")
        try fm.createSymbolicLink(atPath: docsLink.path, withDestinationPath: "/Users")

        try SandboxBuilder.enforcePrefixIsolation(
            prefixDir: dir,
            security: BottleSecurityConfig(disableHostRootDrive: true, isolateUserFolders: true)
        )

        XCTAssertFalse(fm.fileExists(atPath: zDrive.path))
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: docsLink.path))
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: docsLink.path, isDirectory: &isDir) && isDir.boolValue)
    }

    func testNativeAppBundleBuilderCreatesValidBundle() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = TinyWinPaths(rootDir: dir)
        let bottle = BottleConfig(id: "apps", name: "Apps")
        let builder = AppBundleBuilder(paths: paths)

        let appURL = try builder.buildNativeAppWrapper(
            appName: "My Win Tool",
            bottle: bottle,
            executablePath: "windows/notepad.exe",
            tinywinCLIPath: "/usr/local/bin/tinywin",
            destinationDir: dir
        )

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: appURL.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertTrue(fm.isExecutableFile(atPath: appURL.appendingPathComponent("Contents/MacOS/launcher").path))
        XCTAssertTrue(fm.fileExists(atPath: appURL.appendingPathComponent("Contents/Resources/launch.json").path))
    }

    func testBottleIDSanitization() {
        let bm = BottleManager()
        XCTAssertEqual(bm.sanitizeBottleID("Steam Games 2026!"), "steam-games-2026")
        XCTAssertEqual(bm.sanitizeBottleID("  Work_Apps  "), "work_apps")
    }

    func testBottlePresetGraphicsDefaults() {
        let appBottle = BottleConfig(id: "apps", name: "Apps", preset: .app)
        XCTAssertEqual(appBottle.graphics.backend, .wined3d)
        XCTAssertTrue(appBottle.graphics.retinaMode)
        XCTAssertEqual(appBottle.graphics.dpi, 192)

        let gameBottle = BottleConfig(id: "games", name: "Games", preset: .game)
        XCTAssertEqual(gameBottle.graphics.backend, .dxmt)
        XCTAssertFalse(gameBottle.graphics.retinaMode)
        XCTAssertEqual(gameBottle.graphics.dpi, 96)
    }

    func testFolderDiscoveryAndPortableImport() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let paths = TinyWinPaths(rootDir: dir.appendingPathComponent("tinywin_home", isDirectory: true))
        let bm = BottleManager(paths: paths)

        // Create a mock multi-file app/installer folder
        let pkg = dir.appendingPathComponent("OpenGame", isDirectory: true)
        let sub = pkg.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try makeMinimalPEBytes(machine: 0x8664, subsystem: 2).write(to: pkg.appendingPathComponent("unins000.exe"))
        try makeMinimalPEBytes(machine: 0x8664, subsystem: 2).write(to: pkg.appendingPathComponent("setup.exe"))
        try makeMinimalPEBytes(machine: 0x8664, subsystem: 2).write(to: sub.appendingPathComponent("helper.exe"))
        try Data("assets".utf8).write(to: pkg.appendingPathComponent("data1.bin"))

        let exes = bm.discoverExecutables(in: pkg)
        XCTAssertEqual(exes.first?.lastPathComponent, "setup.exe")
        XCTAssertEqual(exes.last?.lastPathComponent, "unins000.exe")

        // Create a mock bottle dir and import the whole folder
        let bottle = BottleConfig(id: "testb", name: "TestB")
        try FileManager.default.createDirectory(
            at: paths.bottlePrefixDir(id: bottle.id).appendingPathComponent("drive_c"),
            withIntermediateDirectories: true
        )
        let imported = try bm.importFolder(pkg, into: bottle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.appendingPathComponent("data1.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.appendingPathComponent("bin/helper.exe").path))
    }
}
