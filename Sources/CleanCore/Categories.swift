import Foundation

public enum CategoryGroup: String, CaseIterable, Codable, Hashable, Sendable {
    case developer = "Developer"
    case apps = "Apps & Messaging"
    case system = "System & Caches"
    case files = "Your Files"

    public var symbol: String {
        switch self {
        case .developer: return "hammer"
        case .apps: return "message"
        case .system: return "gearshape.2"
        case .files: return "folder"
        }
    }
}

/// How a category is populated.
public enum ScanKind: Hashable, Sendable {
    /// Every immediate child of each listed folder becomes a row (e.g. each DerivedData project).
    case children(paths: [String])
    /// Each listed folder becomes a single row.
    case whole(paths: [String])
    /// Children of each folder, but grouped one level deeper (e.g. CoreSimulator/Devices/<udid>).
    case childrenNamed(paths: [String], namer: NamingRule)
    case downloads
    case largeFiles
    case staleFiles
    case duplicates
    case devArtifacts
    case leftovers
    case trash
    case simulators
    case deviceSupport(paths: [String])
    /// Children of the folders whose names look like macOS screenshots / screen recordings.
    case screenshots(paths: [String])
}

/// Tiny helpers for prettier row names/notes.
public enum NamingRule: Hashable, Sendable {
    case none
    /// "Foo-abcdef123" DerivedData folders → "Foo"
    case derivedData
    /// Date folders in Archives → "2026-03-15"
    case archives
}

/// A one-click action the app can offer for a category (implemented in the app layer).
public enum SpecialAction: String, Hashable, Sendable {
    case deleteUnavailableSimulators
    case emptyTrash
    case brewCleanup
}

public struct CleanCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let group: CategoryGroup
    public let risk: RiskLevel
    public let kind: ScanKind
    public let symbol: String
    /// One or two sentences shown in the detail header: what it is and what happens if you delete it.
    public let explanation: String
    public let specialAction: SpecialAction?
    /// Only show this category if any of these paths exist (so users without Xcode don't see 8 Xcode rows).
    public let requiresAnyPath: [String]

    public init(id: String, title: String, subtitle: String, group: CategoryGroup, risk: RiskLevel,
                kind: ScanKind, symbol: String, explanation: String,
                specialAction: SpecialAction? = nil, requiresAnyPath: [String] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.group = group
        self.risk = risk
        self.kind = kind
        self.symbol = symbol
        self.explanation = explanation
        self.specialAction = specialAction
        self.requiresAnyPath = requiresAnyPath
    }

    /// Paths this category reads (expanded). Empty for computed scans.
    public var paths: [String] {
        switch kind {
        case .children(let p), .whole(let p), .deviceSupport(let p), .screenshots(let p): return p.map(PathUtils.expand)
        case .childrenNamed(let p, _): return p.map(PathUtils.expand)
        default: return []
        }
    }

    /// Whether this category is relevant on this Mac right now.
    public var isAvailable: Bool {
        if requiresAnyPath.isEmpty { return true }
        return requiresAnyPath.contains { PathUtils.exists($0) }
    }
}

// MARK: - Catalog

public enum Catalog {
    public static let all: [CleanCategory] = developer + apps + system + files

    public static func category(_ id: String) -> CleanCategory? { all.first { $0.id == id } }

    public static func available() -> [CleanCategory] { all.filter { $0.isAvailable } }

    // MARK: Developer

    static let xcodeRoot = "~/Library/Developer/Xcode"
    public static let developer: [CleanCategory] = [
        CleanCategory(
            id: "xcode.deriveddata", title: "Xcode DerivedData",
            subtitle: "Build products, indexes & logs",
            group: .developer, risk: .safe,
            kind: .childrenNamed(paths: ["\(xcodeRoot)/DerivedData"], namer: .derivedData),
            symbol: "hammer.fill",
            explanation: "Intermediate build output for every project you've opened. Xcode rebuilds it on the next build, so this is always safe. Delete projects you haven't touched in a while first.",
            requiresAnyPath: ["\(xcodeRoot)/DerivedData"]),
        CleanCategory(
            id: "xcode.archives", title: "Xcode Archives",
            subtitle: ".xcarchive bundles from Product → Archive",
            group: .developer, risk: .review,
            kind: .children(paths: ["\(xcodeRoot)/Archives"]),
            symbol: "archivebox",
            explanation: "Each archive holds a built app plus its dSYM debug symbols. Keep archives for builds that are live on the App Store or TestFlight unless you're sure the dSYMs were uploaded. Old experiments are safe to remove.",
            requiresAnyPath: ["\(xcodeRoot)/Archives"]),
        CleanCategory(
            id: "xcode.devicesupport", title: "Device Support Symbols",
            subtitle: "iOS / watchOS / tvOS / visionOS DeviceSupport",
            group: .developer, risk: .safe,
            kind: .deviceSupport(paths: ["\(xcodeRoot)/iOS DeviceSupport", "\(xcodeRoot)/watchOS DeviceSupport",
                                         "\(xcodeRoot)/tvOS DeviceSupport", "\(xcodeRoot)/visionOS DeviceSupport"]),
            symbol: "iphone.gen3",
            explanation: "Debug symbols Xcode copies from every physical device you plug in, one folder (5–8 GB) per OS version. Xcode re-downloads them the next time you debug on a device running that version. Keep the version your current devices run.",
            requiresAnyPath: ["\(xcodeRoot)/iOS DeviceSupport", "\(xcodeRoot)/watchOS DeviceSupport"]),
        CleanCategory(
            id: "xcode.simulators", title: "Simulator Devices",
            subtitle: "CoreSimulator device data & caches",
            group: .developer, risk: .careful,
            kind: .simulators,
            symbol: "ipad.and.iphone",
            explanation: "Each simulator device has its own sandbox with installed apps and data. Deleting a device folder wipes that simulator (Xcode recreates a fresh one). The safest first step is the “Delete unavailable simulators” button, which removes devices whose runtime is no longer installed.",
            specialAction: .deleteUnavailableSimulators,
            requiresAnyPath: ["~/Library/Developer/CoreSimulator"]),
        CleanCategory(
            id: "xcode.caches", title: "Xcode Caches & Previews",
            subtitle: "Documentation cache, SwiftUI previews, module cache",
            group: .developer, risk: .safe,
            kind: .whole(paths: ["~/Library/Caches/com.apple.dt.Xcode", "\(xcodeRoot)/DocumentationCache",
                                 "~/Library/Developer/Xcode/UserData/Previews", "~/Library/Developer/Shared/Documentation",
                                 "~/Library/Developer/CoreSimulator/Caches", "~/Library/Caches/org.swift.swiftpm",
                                 "~/Library/org.swift.swiftpm", "~/Library/Developer/Xcode/Products",
                                 "~/Library/Developer/XCTestDevices", "~/Library/Developer/XCPGDevices"]),
            symbol: "internaldrive",
            explanation: "Regenerable caches that Xcode and Swift Package Manager rebuild on demand. Clearing the SwiftPM cache only means packages get re-downloaded on the next resolve.",
            requiresAnyPath: ["~/Library/Caches/com.apple.dt.Xcode", "~/Library/Caches/org.swift.swiftpm", "~/Library/Developer"]),
        CleanCategory(
            id: "dev.artifacts", title: "Project Build Folders",
            subtitle: "node_modules, .build, target, .venv, .pio, Pods…",
            group: .developer, risk: .safe,
            kind: .devArtifacts,
            symbol: "shippingbox",
            explanation: "Dependency and build folders inside your project directories. They are recreated by npm install, swift build, cargo build, pip install, pio run and friends — you only lose the time to rebuild. Scans the project roots configured in Settings.",
            requiresAnyPath: []),
        CleanCategory(
            id: "dev.pkgcaches", title: "Package Manager Caches",
            subtitle: "Homebrew, npm, pnpm, yarn, pip, uv, Cargo, Gradle, CocoaPods, Go",
            group: .developer, risk: .safe,
            kind: .whole(paths: ["~/Library/Caches/Homebrew", "~/.npm/_cacache", "~/.npm/_npx", "~/Library/pnpm/store",
                                 "~/Library/Caches/pnpm", "~/.cache/pnpm", "~/Library/Caches/Yarn", "~/.yarn/berry/cache",
                                 "~/.bun/install/cache", "~/Library/Caches/pip", "~/.cache/pip", "~/Library/Caches/uv",
                                 "~/.cache/uv", "~/.cargo/registry", "~/.cargo/git", "~/.gradle/caches", "~/.gradle/wrapper/dists",
                                 "~/.m2/repository", "~/Library/Caches/CocoaPods", "~/.cocoapods/repos",
                                 "~/Library/Caches/go-build", "~/go/pkg/mod/cache", "~/.cache/huggingface",
                                 "~/Library/Caches/ms-playwright", "~/.cache/puppeteer", "~/Library/Caches/Cypress",
                                 "~/.rustup/toolchains", "~/.nvm/.cache", "~/Library/Caches/deno", "~/.cache/typescript",
                                 "~/Library/Caches/electron", "~/Library/Caches/node-gyp", "~/.cache/pre-commit",
                                 "~/.cache/pypoetry", "~/Library/Caches/pypoetry", "~/.conda/pkgs", "~/miniconda3/pkgs",
                                 "~/Library/Caches/Carthage", "~/Library/Caches/com.tuist.tuist"]),
            symbol: "cube.box",
            explanation: "Download caches kept by package managers so re-installs are faster. Everything here is re-fetched from the network when needed. (Homebrew users: “brew cleanup” does the same thing for Homebrew.)",
            specialAction: .brewCleanup,
            requiresAnyPath: []),
        CleanCategory(
            id: "dev.embedded", title: "Embedded & Maker Tools",
            subtitle: "Arduino, PlatformIO, ESP-IDF, KiCad, Bambu Studio caches",
            group: .developer, risk: .safe,
            kind: .whole(paths: ["~/Library/Arduino15/staging", "~/Library/Arduino15/tmp", "~/Library/Caches/arduino",
                                 "~/Library/Caches/arduino-ide", "~/.platformio/.cache", "~/.platformio/packages/.cache",
                                 "~/.espressif/dist", "~/.espressif/idf-tools-cache",
                                 "~/Library/Caches/kicad", "~/Library/Caches/org.kicad.kicad",
                                 "~/Library/Caches/com.bambulab.bambu-studio", "~/Library/Application Support/BambuStudio/cache",
                                 "~/Library/Application Support/BambuStudio/log", "~/Library/Caches/PrusaSlicer",
                                 "~/Library/Application Support/OrcaSlicer/cache", "~/Library/Application Support/OrcaSlicer/log",
                                 "~/Library/Caches/com.raspberrypi.imager", "~/Library/Caches/Raspberry Pi/Imager",
                                 "~/Library/Caches/qmk", "~/qmk_firmware/.build", "~/Library/Caches/org.zmk"]),
            symbol: "cpu",
            explanation: "Downloaded board packages, toolchain archives, slicer logs and thumbnails. Arduino's staging folder is just the zip files it already extracted; PlatformIO and ESP-IDF re-download anything they need.",
            requiresAnyPath: []),
        CleanCategory(
            id: "dev.docker", title: "Docker & VMs",
            subtitle: "Docker Desktop disk image, Colima, UTM, Parallels",
            group: .developer, risk: .careful,
            kind: .whole(paths: ["~/Library/Containers/com.docker.docker/Data/vms", "~/.docker/desktop/vms",
                                 "~/.colima", "~/.lima", "~/Library/Containers/com.utmapp.UTM/Data/Documents",
                                 "~/Parallels", "~/Virtual Machines.localized", "~/.orbstack/data",
                                 "~/Library/Application Support/rancher-desktop/lima"]),
            symbol: "server.rack",
            explanation: "Virtual-machine disk images. Docker's image grows and never shrinks on its own; use “docker system prune” inside Docker first, or delete the VM here to start completely fresh (you lose all containers, images and volumes).",
            requiresAnyPath: []),
    ]

    // MARK: Apps & messaging

    public static let apps: [CleanCategory] = [
        CleanCategory(
            id: "apps.whatsapp", title: "WhatsApp Media",
            subtitle: "Photos, videos & voice notes received on this Mac",
            group: .apps, risk: .review,
            kind: .children(paths: ["~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media",
                                    "~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Media",
                                    "~/Library/Application Support/WhatsApp/Cache",
                                    "~/Library/Application Support/WhatsApp/Code Cache"]),
            symbol: "phone.bubble",
            explanation: "Every photo, video, sticker and voice note received in a chat is saved here, one folder per chat. Deleting media here removes it from this Mac only — your phone still has its own copy, and WhatsApp re-downloads media when you open a chat if the sender's copy is still available.",
            requiresAnyPath: ["~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared", "~/Library/Application Support/WhatsApp"]),
        CleanCategory(
            id: "apps.telegram", title: "Telegram Cache",
            subtitle: "Downloaded media & cached files",
            group: .apps, risk: .safe,
            kind: .whole(paths: ["~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/appstore",
                                 "~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable",
                                 "~/Library/Caches/ru.keepcoder.Telegram",
                                 "~/Library/Application Support/Telegram Desktop/tdata/user_data"]),
            symbol: "paperplane",
            explanation: "Telegram keeps a copy of everything you have viewed. Because all media lives in the cloud, the cache is re-downloaded on demand.",
            requiresAnyPath: ["~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram", "~/Library/Application Support/Telegram Desktop"]),
        CleanCategory(
            id: "apps.chatcaches", title: "Slack, Discord, Teams & Zoom",
            subtitle: "Chat app caches",
            group: .apps, risk: .safe,
            kind: .whole(paths: ["~/Library/Application Support/Slack/Cache", "~/Library/Application Support/Slack/Service Worker/CacheStorage",
                                 "~/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack/Cache",
                                 "~/Library/Application Support/discord/Cache", "~/Library/Application Support/discord/Code Cache",
                                 "~/Library/Application Support/discord/GPUCache",
                                 "~/Library/Containers/com.microsoft.teams2/Data/Library/Caches",
                                 "~/Library/Application Support/Microsoft/Teams/Cache",
                                 "~/Library/Application Support/zoom.us/data", "~/Library/Caches/us.zoom.xos",
                                 "~/Documents/Zoom"]),
            symbol: "bubble.left.and.bubble.right",
            explanation: "Electron-style web caches for chat apps. Safe to clear; the apps rebuild them as you use them. Zoom's Documents/Zoom folder holds local meeting recordings — check those before deleting.",
            requiresAnyPath: []),
        CleanCategory(
            id: "apps.media", title: "Spotify, Music & Streaming Caches",
            subtitle: "Offline caches for streaming apps",
            group: .apps, risk: .safe,
            kind: .whole(paths: ["~/Library/Caches/com.spotify.client", "~/Library/Application Support/Spotify/PersistentCache",
                                 "~/Library/Caches/com.apple.Music", "~/Library/Caches/com.apple.TV",
                                 "~/Library/Application Support/Steam/steamapps/shadercache",
                                 "~/Library/Application Support/Steam/appcache",
                                 "~/Library/Caches/com.google.Chrome", "~/Library/Caches/Google/Chrome",
                                 "~/Library/Caches/com.brave.Browser", "~/Library/Caches/Firefox/Profiles",
                                 "~/Library/Caches/com.microsoft.edgemac", "~/Library/Caches/company.thebrowser.Browser",
                                 "~/Library/Caches/ai.perplexity.comet", "~/Library/Caches/com.operasoftware.Opera"]),
            symbol: "play.rectangle",
            explanation: "Streaming caches and browser caches. Deleting them just means content re-buffers and pages reload slightly slower the first time.",
            requiresAnyPath: []),
        CleanCategory(
            id: "apps.mail", title: "Mail & Messages Attachments",
            subtitle: "Mail Downloads and iMessage attachments",
            group: .apps, risk: .review,
            kind: .whole(paths: ["~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
                                 "~/Library/Mail Downloads", "~/Library/Messages/Attachments",
                                 "~/Library/Containers/com.apple.mail/Data/Library/Caches"]),
            symbol: "envelope",
            explanation: "Mail Downloads are copies of attachments you have opened (the originals stay in the mail). Messages/Attachments is every photo and file ever sent in iMessage on this Mac — with Messages in iCloud they re-download, otherwise deleting is permanent. Needs Full Disk Access.",
            requiresAnyPath: []),
        CleanCategory(
            id: "apps.leftovers", title: "Leftovers From Deleted Apps",
            subtitle: "Support files for apps that are no longer installed",
            group: .apps, risk: .review,
            kind: .leftovers,
            symbol: "trash.slash",
            explanation: "Folders in Application Support, Caches, Containers and Saved Application State whose app can't be found anywhere on this Mac. Double-check anything you recognise — some command-line tools and helpers store data under a reverse-DNS name without having a .app.",
            requiresAnyPath: []),
    ]

    // MARK: System

    public static let system: [CleanCategory] = [
        CleanCategory(
            id: "sys.caches", title: "User Caches",
            subtitle: "~/Library/Caches, per app",
            group: .system, risk: .safe,
            kind: .children(paths: ["~/Library/Caches"]),
            symbol: "memorychip",
            explanation: "Every app keeps a cache folder here. Quit heavy apps first, then clear the biggest ones; apps rebuild caches as needed. A handful of folders (CloudKit, com.apple.bird) can be locked by macOS and will simply refuse.",
            requiresAnyPath: []),
        CleanCategory(
            id: "sys.logs", title: "Logs & Crash Reports",
            subtitle: "~/Library/Logs and diagnostic reports",
            group: .system, risk: .safe,
            kind: .children(paths: ["~/Library/Logs", "~/Library/Logs/DiagnosticReports"]),
            symbol: "doc.text.magnifyingglass",
            explanation: "Plain-text logs written by apps and crash reporters. Useful only if you're actively debugging something.",
            requiresAnyPath: []),
        CleanCategory(
            id: "sys.iosbackups", title: "iPhone & iPad Backups",
            subtitle: "Finder/iTunes device backups",
            group: .system, risk: .careful,
            kind: .children(paths: ["~/Library/Application Support/MobileSync/Backup"]),
            symbol: "externaldrive.badge.icloud",
            explanation: "Full local backups of iOS devices, often tens of GB each and frequently for phones you no longer own. If you back up to iCloud you may not need these at all. Deleting is permanent. Needs Full Disk Access.",
            requiresAnyPath: []),
        CleanCategory(
            id: "sys.iosupdates", title: "iOS Software Updates",
            subtitle: ".ipsw files downloaded by Finder",
            group: .system, risk: .safe,
            kind: .children(paths: ["~/Library/iTunes/iPhone Software Updates", "~/Library/iTunes/iPad Software Updates",
                                    "~/Library/iTunes/Apple Watch Software Updates"]),
            symbol: "arrow.down.circle",
            explanation: "Multi-GB firmware images that Finder downloaded to update a device. Once the update is applied they are never used again.",
            requiresAnyPath: []),
        CleanCategory(
            id: "sys.trash", title: "Trash",
            subtitle: "Items waiting in the Trash",
            group: .system, risk: .safe,
            kind: .trash,
            symbol: "trash",
            explanation: "Files you have already deleted. Emptying the Trash is what actually frees the space.",
            specialAction: .emptyTrash,
            requiresAnyPath: []),
        CleanCategory(
            id: "sys.misc", title: "Other System Junk",
            subtitle: "QuickLook thumbnails, Spotlight suggestions, saved app state",
            group: .system, risk: .safe,
            kind: .whole(paths: ["~/Library/Saved Application State", "~/Library/Caches/com.apple.QuickLook.thumbnailcache",
                                 "~/Library/Containers/com.apple.QuickLook.thumbnailcache", "~/Library/Application Support/CrashReporter",
                                 "~/Library/Caches/com.apple.helpd", "~/Library/Application Support/Code/Cache",
                                 "~/Library/Application Support/Code/CachedData", "~/Library/Application Support/Code/CachedExtensionVSIXs",
                                 "~/Library/Application Support/Code/User/workspaceStorage", "~/Library/Application Support/Cursor/Cache",
                                 "~/Library/Application Support/Cursor/CachedData", "~/Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage",
                                 "~/Library/Caches/JetBrains", "~/Library/Logs/JetBrains", "~/Library/Application Support/Adobe/Common/Media Cache Files",
                                 "~/Library/Caches/Adobe", "~/Library/Application Support/Figma/DesktopProfile",
                                 "~/Library/Caches/com.figma.Desktop", "~/Library/Caches/notion.id"]),
            symbol: "sparkles",
            explanation: "Assorted regenerable state: window-restoration snapshots, thumbnail caches, editor caches (VS Code, Cursor, JetBrains), Adobe media cache. Nothing here holds documents.",
            requiresAnyPath: []),
    ]

    // MARK: Files

    public static let files: [CleanCategory] = [
        CleanCategory(
            id: "files.downloads", title: "Downloads",
            subtitle: "Everything in ~/Downloads, biggest first",
            group: .files, risk: .review,
            kind: .downloads,
            symbol: "arrow.down.to.line",
            explanation: "Your Downloads folder, sorted by size, with the last time each item was opened. Installers (.dmg, .pkg, .zip) you've already used are flagged — they're the usual culprits.",
            requiresAnyPath: []),
        CleanCategory(
            id: "files.large", title: "Large Files",
            subtitle: "Big files anywhere in your home folder",
            group: .files, risk: .review,
            kind: .largeFiles,
            symbol: "doc.zipper",
            explanation: "Files bigger than the threshold set in Settings (default 200 MB), found anywhere under your home folder except ~/Library. Each one shows when it was last opened, so forgotten disk images and screen recordings are easy to spot.",
            requiresAnyPath: []),
        CleanCategory(
            id: "files.stale", title: "Not Opened in a Long Time",
            subtitle: "Desktop, Documents & Downloads files you haven't touched",
            group: .files, risk: .review,
            kind: .staleFiles,
            symbol: "clock.arrow.circlepath",
            explanation: "Files over 1 MB in Desktop, Documents and Downloads that haven't been opened for the number of days set in Settings (default 180). Note that macOS updates “last opened” lazily, so use this as a hint and check the modified date too.",
            requiresAnyPath: []),
        CleanCategory(
            id: "files.duplicates", title: "Duplicate Files",
            subtitle: "Identical copies in Desktop, Documents & Downloads",
            group: .files, risk: .review,
            kind: .duplicates,
            symbol: "doc.on.doc",
            explanation: "Files with byte-identical content (compared by size, then a content hash). The oldest copy in each set is kept unselected as the original; the others are proposed for removal.",
            requiresAnyPath: []),
        CleanCategory(
            id: "files.screenshots", title: "Screenshots & Screen Recordings",
            subtitle: "Screenshot*.png / Screen Recording*.mov on Desktop and Downloads",
            group: .files, risk: .review,
            kind: .screenshots(paths: ["~/Desktop", "~/Downloads", "~/Pictures/Screenshots", "~/Documents"]),
            symbol: "camera.viewfinder",
            explanation: "macOS names screenshots “Screenshot 2026-01-01 at 10.00.00.png” and recordings “Screen Recording …mov”. Recordings in particular can be hundreds of MB each.",
            requiresAnyPath: []),
    ]
}
