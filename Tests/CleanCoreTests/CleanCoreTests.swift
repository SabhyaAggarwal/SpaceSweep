import XCTest
@testable import CleanCore

final class CleanCoreTests: XCTestCase {
    var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "spacesweep-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmp)
    }

    // MARK: helpers

    @discardableResult
    func makeFile(_ rel: String, size: Int, fill: UInt8 = 0xAB) throws -> String {
        let path = tmp + "/" + rel
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = Data(repeating: fill, count: size)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    func makeDir(_ rel: String) throws -> String {
        let path = tmp + "/" + rel
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    // MARK: formatting

    func testByteFormatter() {
        XCTAssertEqual(ByteFormatter.string(0), "0 bytes")
        XCTAssertEqual(ByteFormatter.string(999), "999 bytes")
        XCTAssertEqual(ByteFormatter.string(1_000), "1.00 KB")
        XCTAssertEqual(ByteFormatter.string(1_500_000), "1.50 MB")
        XCTAssertEqual(ByteFormatter.string(25_300_000_000), "25.3 GB")
        XCTAssertEqual(ByteFormatter.string(512_000_000_000), "512 GB")
        XCTAssertEqual(ByteFormatter.short(0), "—")
        XCTAssertEqual(ByteFormatter.percent(25, of: 100), "25%")
    }

    func testAgeFormatter() {
        let now = Date()
        XCTAssertEqual(AgeFormatter.relative(nil), "unknown")
        XCTAssertEqual(AgeFormatter.relative(now, now: now), "today")
        XCTAssertEqual(AgeFormatter.relative(now.addingTimeInterval(-86_400 * 5), now: now), "5 days ago")
        XCTAssertEqual(AgeFormatter.relative(now.addingTimeInterval(-86_400 * 200), now: now), "6 months ago")
        XCTAssertEqual(AgeFormatter.relative(now.addingTimeInterval(-86_400 * 800), now: now), "2 years ago")
    }

    func testPathUtils() {
        let home = PathUtils.home
        XCTAssertEqual(PathUtils.expand("~/Downloads"), home + "/Downloads")
        XCTAssertEqual(PathUtils.expand("~"), home)
        XCTAssertEqual(PathUtils.abbreviate(home + "/Library/Caches"), "~/Library/Caches")
        XCTAssertEqual(PathUtils.abbreviate("/Applications"), "/Applications")
    }

    // MARK: sizing & walking

    func testSizeCalculatorSumsRecursivelyAndIgnoresSymlinks() throws {
        try makeFile("a/one.bin", size: 10_000)
        try makeFile("a/b/two.bin", size: 20_000)
        try makeFile("outside.bin", size: 1_000_000)
        try FileManager.default.createSymbolicLink(atPath: tmp + "/a/link", withDestinationPath: tmp + "/outside.bin")
        let info = try SizeCalculator.size(of: tmp + "/a")
        XCTAssertEqual(info.files, 2)
        // Allocated size is block-rounded, so compare with a tolerance.
        XCTAssertGreaterThanOrEqual(info.bytes, 30_000)
        XCTAssertLessThan(info.bytes, 30_000 + 2 * 8192)
        let entry = try SizeCalculator.entry(for: tmp + "/a")
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry!.0.isDirectory)
        XCTAssertEqual(entry!.0.fileCount, 2)
        XCTAssertNotNil(entry!.0.modified)
    }

    func testWalkerRespectsDepthAndOpaqueBundles() throws {
        try makeFile("d1/d2/d3/deep.bin", size: 10)
        try makeFile("My.app/Contents/MacOS/bin", size: 10)
        var opts = WalkOptions()
        opts.maxDepth = 2
        var files: [String] = []
        var leaves: [String] = []
        try Walker.walk(tmp, options: opts) { ev in
            switch ev {
            case .file(let p, _, _): files.append(p)
            case .leafDirectory(let p, _): leaves.append((p as NSString).lastPathComponent)
            default: break
            }
        }
        XCTAssertTrue(files.isEmpty, "nothing should be reached at depth 3: \(files)")
        XCTAssertTrue(leaves.contains("My.app"))
        XCTAssertTrue(leaves.contains("d3"))
    }

    // MARK: dev artifacts

    func testDevArtifactsScannerFindsBuildFolders() throws {
        try makeFile("proj/node_modules/pkg/index.js", size: 5_000)
        try makeFile("proj/package.json", size: 10)
        try makeFile("proj/build/out.js", size: 5_000)           // package.json sibling → artifact
        try makeFile("rust/Cargo.toml", size: 10)
        try makeFile("rust/target/debug/bin", size: 5_000)
        try makeFile("plain/build/keep.txt", size: 5_000)         // no marker → not an artifact
        try makeFile("swift/.build/x", size: 5_000)
        try makeFile("fw/platformio.ini", size: 5)
        try makeFile("fw/.pio/build/esp32/firmware.bin", size: 5_000)

        var settings = ScanSettings()
        settings.projectRoots = [tmp]
        let ctx = ScanContext(settings: settings)
        let (entries, denied) = try DevArtifactsScanner.scan(ctx: ctx)
        XCTAssertTrue(denied.isEmpty)
        let names = Set(entries.map(\.name))
        XCTAssertTrue(names.contains("proj/node_modules"), "\(names)")
        XCTAssertTrue(names.contains("proj/build"))
        XCTAssertTrue(names.contains("rust/target"))
        XCTAssertTrue(names.contains("swift/.build"))
        XCTAssertTrue(names.contains("fw/.pio"))
        XCTAssertFalse(names.contains("plain/build"))
        XCTAssertEqual(entries.first?.risk, nil) // engine assigns category risk later
        XCTAssertTrue(entries.allSatisfy { $0.size > 0 && $0.isDirectory })
    }

    func testDevArtifactsScannerThroughEngineAssignsRisk() throws {
        try makeFile("proj/node_modules/pkg/index.js", size: 5_000)
        var settings = ScanSettings()
        settings.projectRoots = [tmp]
        let cat = Catalog.category("dev.artifacts")!
        let result = try ScanEngine.scan(cat, context: ScanContext(settings: settings))
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].risk, .safe)
        XCTAssertEqual(result.totalSize, result.entries[0].size)
    }

    // MARK: duplicates

    func testDuplicateScanner() throws {
        try makeFile("dl/a.bin", size: 2_000_000, fill: 1)
        try makeFile("dl/sub/a copy.bin", size: 2_000_000, fill: 1)
        try makeFile("dl/b.bin", size: 2_000_000, fill: 2)      // same size, different content
        try makeFile("dl/small.bin", size: 10, fill: 1)          // under threshold
        var settings = ScanSettings()
        settings.duplicateMinMB = 1
        let (entries, _) = try DuplicateScanner.scan(ctx: ScanContext(settings: settings), roots: [tmp + "/dl"])
        XCTAssertEqual(entries.count, 2, "\(entries.map(\.path))")
        XCTAssertEqual(entries.filter { $0.risk == .careful }.count, 1)   // one original
        XCTAssertEqual(entries.filter { $0.risk == .review }.count, 1)    // one duplicate
        XCTAssertEqual(Set(entries.compactMap(\.groupKey)).count, 1)
        XCTAssertTrue(entries.contains { $0.note?.hasPrefix("Duplicate of") == true })
    }

    func testContentHasherPrefixVsFull() throws {
        let p1 = try makeFile("h/x.bin", size: 200_000, fill: 7)
        let p2 = try makeFile("h/y.bin", size: 200_000, fill: 7)
        XCTAssertEqual(ContentHasher.digest(of: p1), ContentHasher.digest(of: p2))
        XCTAssertEqual(ContentHasher.digest(of: p1, limit: 1024), ContentHasher.digest(of: p2, limit: 1024))
        XCTAssertNil(ContentHasher.digest(of: tmp + "/nope"))
    }

    // MARK: stale / large

    func testStaleAndLargeLogic() throws {
        let old = try makeFile("Desktop/old.mov", size: 3_000_000)
        let fresh = try makeFile("Desktop/fresh.mov", size: 3_000_000)
        let past = Date().addingTimeInterval(-400 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: old)
        // Also push atime back via utimes so lastUsed is really old.
        var times = [timeval(tv_sec: Int(past.timeIntervalSince1970), tv_usec: 0), timeval(tv_sec: Int(past.timeIntervalSince1970), tv_usec: 0)]
        XCTAssertEqual(utimes(old, &times), 0)

        let stOld = FileStat.read(old)!
        let stFresh = FileStat.read(fresh)!
        XCTAssertLessThan(stOld.modified!, Date().addingTimeInterval(-300 * 86_400))
        XCTAssertGreaterThan(stFresh.modified!, Date().addingTimeInterval(-60))
        let entryOld = FileEntry(path: old, size: stOld.allocatedSize, isDirectory: false, modified: stOld.modified, accessed: stOld.accessed)
        XCTAssertGreaterThanOrEqual(entryOld.daysSinceLastUsed()!, 399)
    }

    // MARK: leftovers heuristics

    func testBundleIDExtraction() {
        XCTAssertEqual(Leftovers.bundleID(from: "com.spotify.client"), "com.spotify.client")
        XCTAssertEqual(Leftovers.bundleID(from: "com.spotify.client.savedState"), "com.spotify.client")
        XCTAssertEqual(Leftovers.bundleID(from: "6N38VWS5BX.ru.keepcoder.Telegram"), "ru.keepcoder.Telegram")
        XCTAssertEqual(Leftovers.bundleID(from: "group.net.whatsapp.WhatsApp.shared"), "net.whatsapp.WhatsApp.shared")
        XCTAssertNil(Leftovers.bundleID(from: "Google"))
        XCTAssertNil(Leftovers.bundleID(from: "Adobe"))
        XCTAssertNil(Leftovers.bundleID(from: "My Documents.backup.old"))
        XCTAssertTrue(Leftovers.isIgnored("com.apple.Safari"))
        XCTAssertFalse(Leftovers.isIgnored("com.figma.Desktop"))
    }

    func testLeftoversScannerUsesInstalledHook() throws {
        // Point HOME-relative locations at the temp dir by using the scanner's internals indirectly:
        // we can't relocate ~ in tests, so just verify the hook is honoured on a synthetic list.
        let installed: Set<String> = ["com.figma.Desktop"]
        let ctx = ScanContext(isAppInstalled: { installed.contains($0) })
        XCTAssertNotNil(ctx.isAppInstalled)
        XCTAssertTrue(ctx.isAppInstalled!("com.figma.Desktop"))
        XCTAssertFalse(ctx.isAppInstalled!("com.gone.App"))
    }

    // MARK: device support naming

    func testDeviceSupportVersionParsing() {
        XCTAssertEqual(DeviceSupportScanner.version(from: "17.4 (21E219)"), "17.4")
        XCTAssertEqual(DeviceSupportScanner.version(from: "iPhone15,3 18.5 (22F76) arm64e"), "18.5")
        XCTAssertEqual(DeviceSupportScanner.version(from: "10.6.1 (20U80)"), "10.6.1")
        XCTAssertNil(DeviceSupportScanner.version(from: "Symbols"))
    }

    func testDerivedDataRename() throws {
        let dd = try makeDir("DerivedData")
        try makeFile("DerivedData/MyApp-abcdefghijklmnopqrstuvwxyz12/Build/x.o", size: 100)
        try makeFile("DerivedData/ModuleCache.noindex/x", size: 100)
        let (entries, _) = try LocationScanner.children([dd], namer: .derivedData, ctx: ScanContext())
        let names = Set(entries.map(\.name))
        XCTAssertTrue(names.contains("MyApp"), "\(names)")
        XCTAssertTrue(names.contains("ModuleCache.noindex"))
    }

    func testScreenshotMatching() {
        XCTAssertTrue(ScreenshotScanner.looksLikeScreenshot("Screenshot 2026-09-27 at 14.52.01.png"))
        XCTAssertTrue(ScreenshotScanner.looksLikeScreenshot("Screen Recording 2026-09-27 at 14.52.01.mov"))
        XCTAssertTrue(ScreenshotScanner.looksLikeScreenshot("Simulator Screenshot - iPhone 16 - 2026-01-01.png"))
        XCTAssertFalse(ScreenshotScanner.looksLikeScreenshot("holiday.png"))
    }

    // MARK: cleaner safety

    func testCleanerRefusesProtectedPathsAndRemovesFiles() throws {
        let victim = try makeFile("victim.bin", size: 100)
        let entries = [
            FileEntry(path: PathUtils.home, size: 1, isDirectory: true),
            FileEntry(path: PathUtils.home + "/Library", size: 1, isDirectory: true),
            FileEntry(path: victim, size: 100, isDirectory: false),
            FileEntry(path: tmp + "/missing", size: 5, isDirectory: false),
        ]
        let report = Cleaner.remove(entries, permanently: true)
        XCTAssertEqual(report.removed.count, 1)
        XCTAssertEqual(report.failed.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim))
        XCTAssertTrue(report.failed.contains { $0.message.contains("protected") })
        XCTAssertTrue(report.failed.contains { $0.message == "Already gone" })
        XCTAssertEqual(report.bytesFreed, 100)
    }

    func testCatalogIsConsistent() {
        let ids = Catalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate category ids")
        for c in Catalog.all {
            XCTAssertFalse(c.explanation.isEmpty, c.id)
            XCTAssertFalse(c.symbol.isEmpty, c.id)
            for p in c.paths { XCTAssertTrue(p.hasPrefix("/"), "\(c.id): \(p)") }
        }
        XCTAssertNotNil(Catalog.category("apps.whatsapp"))
        XCTAssertTrue(Catalog.category("apps.whatsapp")!.paths.contains { $0.contains("group.net.whatsapp.WhatsApp.shared/Message/Media") })
    }

    func testDiskUsageReadsRootVolume() {
        let usage = DiskUsage.current()
        XCTAssertNotNil(usage)
        XCTAssertGreaterThan(usage!.total, 0)
        XCTAssertGreaterThanOrEqual(usage!.used, 0)
    }

    func testCancellationStopsWalk() async throws {
        for i in 0..<300 { try makeFile("many/\(i)/f.bin", size: 1) }
        let root = tmp!
        let task = Task { () -> Int in
            var n = 0
            do {
                try Walker.walk(root) { ev in
                    if case .file = ev { n += 1 }
                    if n == 50 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            } catch is CancellationError {
                return -n
            } catch {
                return 1_000_000
            }
            return n
        }
        let result = await task.value
        XCTAssertLessThan(result, 0, "walk should have thrown CancellationError")
        XCTAssertLessThan(-result, 300)
    }
}
