#!/usr/bin/env swift
//
// cleaner.swift — macOS cleanup CLI
//
// Derived from Pearcleaner (https://github.com/alienator88/Pearcleaner)
// by alienator88, licensed under Apache 2.0 with Commons Clause.
// This work is distributed under the same license.
// See LICENSE and NOTICE for full attribution.
//
// 9 commands across 5 modules:
//   app     :  app-list      app-uninstall <name>
//   pkg     :  pkg-list      pkg-uninstall <pkg-id>
//   plugin  :  plugin-list   plugin-uninstall <name>
//   devenv  :  devenv-list   devenv-uninstall <path>
//   orphan  :  orphan        (cross-module — residuals not claimed by any installed app)
//
// File layout, in order:
//   PART 1   Foundation        (string/url utils, file ops, output helpers, interactive selector)
//   PART 2   App Domain        (AppInfo, shared by every module that needs installed-app data)
//   PART 3   Module: app
//   PART 4   Module: pkg
//   PART 5   Module: plugin
//   PART 6   Module: devenv
//   PART 7   Module: orphan    (ReversePathFinder + cmdOrphan)
//   PART 8   CLI dispatch      (Command registry)
//

import Foundation
import Security

// ═══════════════════════════════════════════════════════════════════════════
// PART 1 — FOUNDATION
// ═══════════════════════════════════════════════════════════════════════════

// MARK: - Globals

let home = FileManager.default.homeDirectoryForCurrentUser.path

// MARK: - String / URL utilities

extension String {
    func normalized() -> String {
        var result = ""
        result.reserveCapacity(self.count)
        for scalar in self.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        result = result.lowercased()
        return result.isEmpty ? self : result
    }
}

// MARK: - File / process

func totalSizeOnDisk(for url: URL) -> Int64 {
    var size: Int64 = 0
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let s = attrs[.size] as? Int64 {
            return s
        }
        return 0
    }
    let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
    guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: nil) else { return 0 }
    for case let f as URL in en {
        let vals = try? f.resourceValues(forKeys: keys)
        if let s = vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize {
            size += Int64(s)
        }
    }
    return size
}

func runCmd(_ launch: String, _ args: [String]) -> String? {
    let task = Process()
    task.launchPath = launch
    task.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe
    do { try task.run() } catch { return nil }
    var outData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.wait()
    task.waitUntilExit()
    return String(data: outData, encoding: .utf8)
}

// MARK: - Output / interaction

func formatBytes(_ n: Int64) -> String {
    return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

func visualWidth(_ s: String) -> Int {
    var w = 0
    for scalar in s.unicodeScalars {
        let v = scalar.value
        if (0x1100...0x115F).contains(v) || (0x2E80...0x9FFF).contains(v) ||
           (0xA000...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v) ||
           (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) ||
           (0xFF00...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v) ||
           (0x20000...0x2FFFD).contains(v) || (0x30000...0x3FFFD).contains(v) {
            w += 2
        } else {
            w += 1
        }
    }
    return w
}

func padCol(_ s: String, _ width: Int) -> String {
    let cur = visualWidth(s)
    if cur >= width { return s + " " }
    return s + String(repeating: " ", count: width - cur)
}

func printDivider(_ width: Int = 110) {
    print(String(repeating: "-", count: width))
}

func progress(_ i: Int, _ total: Int, _ label: String) {
    FileHandle.standardError.write(Data("\r[\(i)/\(total)] \(label)\u{1B}[K".utf8))
}

func clearProgress() {
    FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
}

func printSizeTable(_ header: String, _ rows: [(name: String, size: Int64)], unitLabel: String) {
    print(padCol("#", 5) + padCol(header, 60) + "SIZE")
    printDivider(85)
    var total: Int64 = 0
    for (i, r) in rows.enumerated() {
        total += r.size
        print(padCol("\(i + 1)", 5) + padCol(r.name, 60) + formatBytes(r.size))
    }
    printDivider(85)
    print("Total: \(rows.count) \(unitLabel), \(formatBytes(total))")
}

// MARK: - Interactive checkbox selector

struct SelectableRow {
    let label: String
    let url: URL
    let size: Int64
    var defaultSelected: Bool = true
    var sectionHeader: String? = nil
}

private enum InputKey { case up, down, left, right, enter, quit, other }

private func readInputKey() -> InputKey {
    var b: UInt8 = 0
    guard read(STDIN_FILENO, &b, 1) == 1 else { return .quit }
    switch b {
    case 0x0a, 0x0d: return .enter
    case 0x03, 0x71: return .quit          // Ctrl-C / q
    case 0x77, 0x6b: return .up            // w / k
    case 0x73, 0x6a: return .down          // s / j
    case 0x61, 0x68: return .left          // a / h
    case 0x64, 0x6c: return .right         // d / l
    case 0x1b:                              // ESC [ A/B/C/D
        var s1: UInt8 = 0
        var s2: UInt8 = 0
        guard read(STDIN_FILENO, &s1, 1) == 1, s1 == 0x5b else { return .quit }
        guard read(STDIN_FILENO, &s2, 1) == 1 else { return .other }
        switch s2 {
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        default:   return .other
        }
    default: return .other
    }
}

func selectAndTrash(rows: [SelectableRow]) {
    if rows.isEmpty { print("Nothing to delete."); return }

    let out = FileHandle.standardOutput

    // Non-TTY fallback (pipes, redirects, CI): print + simple confirm
    var orig = termios()
    guard isatty(STDIN_FILENO) == 1, tcgetattr(STDIN_FILENO, &orig) == 0 else {
        for r in rows { print(padCol(r.label, 80) + formatBytes(r.size)) }
        print("Confirm to delete \(rows.count) items?", terminator: " [y/N] ")
        guard let line = readLine(),
              line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("y")
        else { print("Aborted."); return }
        reportTrashResult(trashAll(rows.map { $0.url }))
        return
    }
    var raw = orig
    raw.c_lflag &= ~tcflag_t(ECHO | ICANON)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    // Alt screen + hide cursor — bytes go through write(2), bypassing Swift's stdio buffer
    out.write(Data("\u{1B}[?1049h\u{1B}[?25l".utf8))

    func restore() {
        var o = orig
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &o)
        out.write(Data("\u{1B}[?25h\u{1B}[?1049l".utf8))
    }

    var selected = rows.map { $0.defaultSelected }
    var cursor = 0
    let totalSize = rows.reduce(Int64(0)) { $0 + $1.size }

    while true {
        var buf = "\u{1B}[H\u{1B}[2J"   // home + clear screen
        buf += padCol("#", 5) + padCol("NAME", 60) + "SIZE\n"
        buf += String(repeating: "-", count: 85) + "\n"
        for (i, row) in rows.enumerated() {
            if let sh = row.sectionHeader {
                if i > 0 { buf += "\n" }
                buf += "\u{1B}[1m" + sh + "\u{1B}[0m\n"   // bold, default color
            }
            let dot = selected[i] ? "●" : "○"
            let line = padCol(dot, 5) + padCol(row.label, 60) + formatBytes(row.size)
            if i == cursor {
                buf += "\u{1B}[7m" + line + "\u{1B}[K\u{1B}[0m\n"   // inverse video; [K extends bg to row end
            } else {
                buf += line + "\n"
            }
        }
        buf += String(repeating: "-", count: 85) + "\n"
        let selSize = zip(selected, rows).reduce(Int64(0)) { $1.0 ? $0 + $1.1.size : $0 }
        let selCount = selected.filter { $0 }.count
        buf += "Selected: \(selCount) / \(rows.count)   Size: \(formatBytes(selSize)) / \(formatBytes(totalSize))\n"
        buf += "[↑↓] move   [←/→] toggle   [enter] confirm to delete   [q] cancel"
        out.write(Data(buf.utf8))

        switch readInputKey() {
        case .up:    cursor = (cursor - 1 + rows.count) % rows.count
        case .down:  cursor = (cursor + 1) % rows.count
        case .left, .right: selected[cursor].toggle()
        case .enter:
            restore()
            let chosen = zip(selected, rows).compactMap { $0 ? $1.url : nil }
            if chosen.isEmpty { print("Nothing selected. Aborted."); return }
            reportTrashResult(trashAll(chosen))
            return
        case .quit:
            restore()
            print("Aborted.")
            return
        case .other:
            continue
        }
    }
}

struct TrashResult {
    var trashed: [URL] = []
    var permissionDenied: [URL] = []
    var failed: [(URL, Error)] = []
}

func trashAll(_ urls: [URL]) -> TrashResult {
    var result = TrashResult()
    for u in urls {
        guard FileManager.default.fileExists(atPath: u.path) else { continue }
        do {
            try FileManager.default.trashItem(at: u, resultingItemURL: nil)
            result.trashed.append(u)
        } catch let err as NSError {
            if err.domain == NSCocoaErrorDomain &&
               (err.code == NSFileWriteNoPermissionError || err.code == 513 || err.code == 257) {
                result.permissionDenied.append(u)
            } else if err.domain == NSPOSIXErrorDomain && err.code == 1 /* EPERM */ {
                result.permissionDenied.append(u)
            } else {
                result.failed.append((u, err))
            }
        }
    }
    return result
}

func reportTrashResult(_ result: TrashResult) {
    print("Trashed: \(result.trashed.count)")
    if !result.permissionDenied.isEmpty {
        print("\nNeeded sudo (\(result.permissionDenied.count)):")
        for u in result.permissionDenied { print("  \(u.path)") }
        let quoted = result.permissionDenied.map { "\"\($0.path)\"" }.joined(separator: " ")
        print("\nManual:  sudo rm -rf \(quoted)")
    }
    if !result.failed.isEmpty {
        print("\nFailed (\(result.failed.count)):")
        for (u, e) in result.failed { print("  \(u.path)  -- \(e.localizedDescription)") }
    }
}

// MARK: - CLI arg helpers (used by every cmd*)

func positionalArgs(_ args: [String]) -> [String] {
    var out: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let valueFlags: Set<String> = ["--sort", "--filter", "--category"]
            if valueFlags.contains(a) { i += 2 } else { i += 1 }
        } else {
            out.append(a)
            i += 1
        }
    }
    return out
}

func reportError(_ msg: String, exitCode: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("\(msg)\n".utf8))
    exit(exitCode)
}

// ═══════════════════════════════════════════════════════════════════════════
// PART 2 — APP DOMAIN (shared by app + plugin + orphan)
// ═══════════════════════════════════════════════════════════════════════════

struct AppInfo {
    let path: URL
    let bundleIdentifier: String
    let appName: String
    let entitlements: [String]?
    let teamIdentifier: String?
    let webApp: Bool
    let steam: Bool
}

func readInfoPlist(at appPath: URL) -> [String: Any]? {
    let plistURL = appPath.appendingPathComponent("Contents/Info.plist")
    guard FileManager.default.fileExists(atPath: plistURL.path) else { return nil }
    guard let data = try? Data(contentsOf: plistURL) else { return nil }
    return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
}

func isWebApp(at appPath: URL) -> Bool {
    guard let info = readInfoPlist(at: appPath) else { return false }
    if let category = info["LSApplicationCategoryType"] as? String,
       category.lowercased().contains("webbrowser") || info["CrAppModeUserBrowserShortcutId"] != nil {
        return true
    }
    if info["CrAppModeUserBrowserShortcutId"] != nil { return true }
    return false
}

func isSteam(at appPath: URL) -> Bool {
    return FileManager.default.fileExists(atPath: appPath.appendingPathComponent("Contents/MacOS/run.sh").path)
}

private func getEntitlements(for appPath: String) -> [String]? {
    return autoreleasepool { () -> [String]? in
        let appURL = URL(fileURLWithPath: appPath) as CFURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: 1 << 2), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }

        var results: [String] = []
        if let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            if let g = entitlements["com.apple.security.application-groups"] as? [String] { results.append(contentsOf: g) }
            if let g = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] { results.append(contentsOf: g) }
        }

        let excluded = ["crashhandler", "crash handler", "electron"]
        let macosPath = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/MacOS")
        if let files = try? FileManager.default.contentsOfDirectory(atPath: macosPath.path) {
            for f in files where !f.hasPrefix(".") {
                if !results.contains(f) && f.count >= 5 && !excluded.contains(f.lowercased()) {
                    results.append(f)
                }
            }
        }

        let contentsPath = URL(fileURLWithPath: appPath).appendingPathComponent("Contents")
        if let subdirs = try? FileManager.default.contentsOfDirectory(at: contentsPath, includingPropertiesForKeys: nil) {
            for sub in subdirs where sub.hasDirectoryPath {
                if let bundles = try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) {
                    for b in bundles where b.pathExtension == "app" {
                        let name = b.deletingPathExtension().lastPathComponent
                        if !results.contains(name) && name.count >= 5 && !excluded.contains(name.lowercased()) {
                            results.append(name)
                        }
                        let macos = b.appendingPathComponent("Contents/MacOS")
                        if let bins = try? FileManager.default.contentsOfDirectory(atPath: macos.path) {
                            for bin in bins where !bin.hasPrefix(".") && bin.count >= 5 {
                                if !results.contains(bin) && !excluded.contains(bin.lowercased()) {
                                    results.append(bin)
                                }
                            }
                        }
                    }
                }
            }
        }
        return results.isEmpty ? nil : results
    }
}

private func getTeamIdentifier(for appPath: String) -> String? {
    return autoreleasepool {
        let appURL = URL(fileURLWithPath: appPath) as CFURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict["teamid"] as? String
    }
}

func loadAppInfo(at appPath: URL) -> AppInfo? {
    guard let info = readInfoPlist(at: appPath) else { return nil }
    let bundleId = (info["CFBundleIdentifier"] as? String) ?? ""
    let displayName = (info["CFBundleDisplayName"] as? String) ?? ""
    let fallbackName = (info["CFBundleName"] as? String) ?? appPath.deletingPathExtension().lastPathComponent
    let appName = !displayName.isEmpty ? displayName : fallbackName
    guard !bundleId.isEmpty, !appName.isEmpty else { return nil }
    return AppInfo(
        path: appPath,
        bundleIdentifier: bundleId,
        appName: appName,
        entitlements: getEntitlements(for: appPath.path),
        teamIdentifier: getTeamIdentifier(for: appPath.path),
        webApp: isWebApp(at: appPath),
        steam: isSteam(at: appPath)
    )
}

private var _cachedInstalledApps: [AppInfo]?

func enumerateInstalledApps() -> [AppInfo] {
    if let cached = _cachedInstalledApps { return cached }
    let task = Process()
    task.launchPath = "/usr/bin/mdfind"
    task.arguments = ["kMDItemContentType == \"com.apple.application-bundle\""]
    let pipe = Pipe()
    task.standardOutput = pipe
    do { try task.run() } catch { _cachedInstalledApps = []; return [] }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let out = String(data: data, encoding: .utf8) ?? ""
    var seen: Set<String> = []
    var apps: [AppInfo] = []
    for line in out.split(separator: "\n") {
        let p = String(line)
        if p.contains(".app/Contents/") { continue }
        if seen.contains(p) { continue }
        seen.insert(p)
        if let info = loadAppInfo(at: URL(fileURLWithPath: p)) { apps.append(info) }
    }
    _cachedInstalledApps = apps
    return apps
}

// ═══════════════════════════════════════════════════════════════════════════
// PART 3 — MODULE: app
// ═══════════════════════════════════════════════════════════════════════════

// MARK: - app / local helpers

extension String {
    func strippingTrailingDigits() -> String {
        return self.replacingOccurrences(
            of: #"\s+\d+(\.\d+)*\s*$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
    }
}

func darwinCT() -> (String, String) {
    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments = ["-c", "echo $(getconf DARWIN_USER_CACHE_DIR) $(getconf DARWIN_USER_TEMP_DIR)"]
    let pipe = Pipe()
    task.standardOutput = pipe
    do { try task.run() } catch { return ("", "") }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return ("", "") }
    let parts = out.split(separator: " ").map(String.init)
    return parts.count >= 2 ? (parts[0], parts[1]) : ("", "")
}

let (cacheDir, tempDir) = darwinCT()

// MARK: - app / data: locations

func listAppSupportDirectories() -> [String] {
    let appSupport = "\(home)/Library/Application Support"
    let exclusions: Set<String> = [
        "MobileSync", ".DS_Store", "Xcode", "SyncServices", "networkserviceproxy", "DiskImages",
        "CallHistoryTransactions", "App Store", "CloudDocs", "icdd", "iCloud", "Instruments",
        "AddressBook", "FaceTime", "AskPermission", "CallHistoryDB"
    ]
    let comAppleRe = try! NSRegularExpression(pattern: "\\bcom\\.apple\\b", options: [])
    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: appSupport) else { return [] }
    return contents.compactMap { name in
        let full = "\(appSupport)/\(name)"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { return nil }
        let range = NSRange(location: 0, length: name.utf16.count)
        if comAppleRe.firstMatch(in: name, options: [], range: range) != nil { return nil }
        if exclusions.contains(name) { return nil }
        return name
    }
}

func buildAppsLocations() -> [String] {
    var paths: [String] = [
        "\(home)",
        "\(home)/.config",
        "\(home)/Documents",
        "\(home)/Desktop",
        "\(home)/Applications",
        "\(home)/Library",
        "\(home)/Library/Application Scripts",
        "\(home)/Library/Application Support",
        "\(home)/Library/Application Support/CrashReporter",
        "\(home)/Library/Application Support/Steam/steamapps",
        "\(home)/Library/Application Support/Steam/steamapps/common",
        "\(home)/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments",
        "\(home)/Library/Containers",
        "\(home)/Library/Caches",
        "\(home)/Library/Caches/com.apple.helpd/Generated",
        "\(home)/Library/Caches/com.crashlytics",
        "\(home)/Library/Caches/com.google.SoftwareUpdate",
        "\(home)/Library/Caches/com.google.Keystone",
        "\(home)/Library/Caches/org.sparkle-project.Sparkle",
        "\(home)/Library/Caches/com.segment.analytics",
        "\(home)/Library/Caches/SentryCrash",
        "\(home)/Library/Caches/Rollbar",
        "\(home)/Library/Caches/Amplitude",
        "\(home)/Library/Caches/Realm",
        "\(home)/Library/Caches/Parse",
        "\(home)/Library/Group Containers",
        "\(home)/Library/HTTPStorages",
        "\(home)/Library/Internet Plug-Ins",
        "\(home)/Library/LaunchAgents",
        "\(home)/Library/Logs",
        "\(home)/Library/Logs/DiagnosticReports",
        "\(home)/Library/Preferences",
        "\(home)/Library/PreferencePanes",
        "\(home)/Library/Preferences/ByHost",
        "\(home)/Library/Saved Application State",
        "\(home)/Library/Services",
        "\(home)/Library/WebKit",
        "/Applications",
        "/Users/Shared",
        "/Users/Library",
        "/Users/Shared/Library/Application Support",
        "/Library",
        "/Library/Application Support",
        "/Library/Application Support/CrashReporter",
        "/Library/Caches",
        "/Library/Extensions",
        "/Library/Internet Plug-Ins",
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons",
        "/Library/Logs",
        "/Library/Logs/DiagnosticReports",
        "/Library/Preferences",
        "/Library/PrivilegedHelperTools",
        "/private/var/db/receipts",
        "/private/tmp",
        "/usr/local/bin",
        "/usr/local/etc",
        "/usr/local/opt",
        "/usr/local/sbin",
        "/usr/local/share",
        "/usr/local/var",
        cacheDir,
        tempDir
    ]
    for folder in listAppSupportDirectories() {
        paths.append("\(home)/Library/Application Support/\(folder)")
    }
    return paths
}

let appsLocations: [String] = buildAppsLocations()

let reverseLocations: [String] = [
    "\(home)/Library/Application Scripts",
    "\(home)/Library/Application Support",
    "\(home)/Library/Application Support/Caches",
    "\(home)/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments",
    "\(home)/Library/Containers",
    "\(home)/Library/Caches",
    "\(home)/Library/HTTPStorages",
    "\(home)/Library/Internet Plug-Ins",
    "\(home)/Library/LaunchAgents",
    "\(home)/Library/Logs",
    "\(home)/Library/Preferences",
    "\(home)/Library/PreferencePanes",
    "\(home)/Library/Preferences/ByHost",
    "\(home)/Library/Saved Application State",
    "\(home)/Library/WebKit",
    "/Users/Shared/Library/Application Support",
    "/Library/Application Support",
    "/Library/Application Support/CrashReporter",
    "/Library/Internet Plug-Ins",
    "/Library/LaunchAgents",
    "/Library/LaunchDaemons",
    "/Library/PrivilegedHelperTools"
]

let standardLibrarySubdirectories: Set<String> = [
    "Application Scripts", "Application Support", "Caches", "Containers", "Group Containers",
    "HTTPStorages", "Internet Plug-Ins", "LaunchAgents", "LaunchDaemons", "Logs",
    "Preferences", "PreferencePanes", "PrivilegedHelperTools", "Saved Application State",
    "Services", "WebKit", "Extensions", "Frameworks"
]

// MARK: - app / data: conditions + blacklists

struct Condition {
    let bundleId: String
    let include: [String]
    let exclude: [String]
    let includeForce: [URL]
    let excludeForce: [URL]

    init(bundleId: String, include: [String], exclude: [String],
         includeForce: [String] = [], excludeForce: [String] = []) {
        self.bundleId = bundleId.normalized()
        self.include = include.map { $0.normalized() }
        self.exclude = exclude.map { $0.normalized() }
        self.includeForce = includeForce.compactMap { p -> URL? in
            let u = URL(fileURLWithPath: p)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        self.excludeForce = excludeForce.compactMap { p -> URL? in
            let u = URL(fileURLWithPath: p)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
    }
}

struct SkipCondition {
    let skipPrefix: [String]
    let allowPrefixes: [String]
    let skipPaths: [String]
}

let conditions: [Condition] = [
    Condition(bundleId: "com.apple.dt.xcode",
        include: ["com.apple.dt", "xcode", "simulator"],
        exclude: ["com.robotsandpencils.xcodesapp", "com.xcodesorg.xcodesapp", "com.oneminutegames.xcodecleaner", "io.hyperapp.xcodecleaner", "available-xcodes", "xcodes", "cleaner for xcode"],
        includeForce: ["\(home)/Library/Containers/com.apple.iphonesimulator.ShareExtension"]),
    Condition(bundleId: "com.robotsandpencils.xcodesapp",
        include: [],
        exclude: ["com.apple.dt.xcode", "com.oneminutegames.xcodecleaner", "io.hyperapp.xcodecleaner"]),
    Condition(bundleId: "com.xcodesorg.xcodesapp",
        include: [],
        exclude: ["com.apple.dt.xcode", "com.oneminutegames.xcodecleaner", "io.hyperapp.xcodecleaner"]),
    Condition(bundleId: "io.hyperapp.xcodecleaner",
        include: [],
        exclude: ["com.robotsandpencils.xcodesapp", "com.oneminutegames.xcodecleaner", "com.apple.dt.xcode", "xcodes.json"]),
    Condition(bundleId: "us.zoom.xos", include: ["zoom"], exclude: []),
    Condition(bundleId: "com.brave.browser", include: ["brave"], exclude: []),
    Condition(bundleId: "com.okta.mobile", include: ["okta"], exclude: []),
    Condition(bundleId: "com.google.chrome",
        include: ["google", "chrome"],
        exclude: ["iterm", "chromefeaturestate", "monochrome"]),
    Condition(bundleId: "com.microsoft.edgemac",
        include: [],
        exclude: ["vscode", "rdc", "appcenter", "office", "oneauth"]),
    Condition(bundleId: "com.microsoft.teams2", include: [], exclude: ["office"]),
    Condition(bundleId: "org.mozilla.firefox", include: ["firefox"], exclude: ["thunderbird"]),
    Condition(bundleId: "org.mozilla.thunderbird", include: [], exclude: ["firefox"]),
    Condition(bundleId: "org.mozilla.firefox.nightly", include: ["mozilla", "firefox"], exclude: ["thunderbird"]),
    Condition(bundleId: "com.logi.optionsplus",
        include: ["logi", "logipluginservice"],
        exclude: ["login", "logic"]),
    Condition(bundleId: "com.microsoft.VSCode",
        include: ["vscode"],
        exclude: ["vscodeinsiders", "insiders"],
        includeForce: ["\(home)/Library/Application Support/Code/"]),
    Condition(bundleId: "com.microsoft.VSCodeInsiders",
        include: ["vscodeinsiders", "insiders"],
        exclude: [],
        includeForce: ["\(home)/Library/Application Support/Code - Insiders/"]),
    Condition(bundleId: "com.facebook.archon.developerid", include: ["archon.loginhelper"], exclude: []),
    Condition(bundleId: "eu.exelban.stats", include: [], exclude: ["video"]),
    Condition(bundleId: "me.mhaeuser.BatteryToolkit", include: ["memhaeuser"], exclude: []),
    Condition(bundleId: "jetbrains",
        include: ["jcef"],
        exclude: [],
        includeForce: ["\(home)/Library/Application Support/JetBrains/", "\(home)/Library/Caches/JetBrains/", "\(home)/Library/Logs/JetBrains/"]),
    Condition(bundleId: "company.thebrowser.Browser",
        include: ["firestore"],
        exclude: [],
        includeForce: ["\(home)/Library/Application Support/Arc/", "\(home)/Library/Caches/Arc/"]),
    Condition(bundleId: "com.1password.1password", include: ["waveboxapp", "sidekick"], exclude: []),
    Condition(bundleId: "com.now.gg.BlueStacks", include: ["bst_boost_interprocess"], exclude: []),
    Condition(bundleId: "com.electron.sdm", include: ["strongdm"], exclude: []),
    Condition(bundleId: "com.github.githubclient", include: ["comgithubelectron"], exclude: []),
    Condition(bundleId: "com.native-instruments.nativeaccess", include: ["comnative", "nativeinstruments"], exclude: [])
]

let skipConditions: [SkipCondition] = [
    SkipCondition(
        skipPrefix: ["mobiledocuments", "reminders", "dsstore", "comapplepasswordmanager"],
        allowPrefixes: ["comappleconfigurator", "comappledt", "comappleiwork", "comapplesfsymbols", "comappletestflight", "comapplesharedfilelist", "comapplelssharedfilelist"],
        skipPaths: [
            "\(home)/.Trash",
            "/Library/SystemExtensions",
            "/System/Volumes/Preboot/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper",
            "\(home)/Library/Application Support/Chromium/NativeMessagingHosts/com.apple.passwordmanager.json",
            "\(home)/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.apple.passwordmanager.json"
        ]
    )
]

let skipDeepSearch: Set<String> = [
    "Apple", "Audio", "Bluetooth", "ColorSync", "Components", "CoreAnalytics",
    "CoreMediaIO", "DirectoryServices", "Filesystems", "GPUBundles", "Graphics",
    "KernelCollections", "OSAnalytics", "OpenDirectory", "Sandbox", "Security",
    "SystemExtensions", "SystemMigration", "SystemProfiler", "StagedDriverExtensions",
    "StagedExtensions", "StartupItems",
    "Accessibility", "Accounts", "AppleMediaServices", "Assistant", "Assistants",
    "Autosave Information", "Biome", "Calendars", "CallServices", "CloudStorage",
    "Contacts", "Cookies", "DataAccess", "DataDeliveryServices", "DoNotDisturb",
    "DuetExpertCenter", "Finance", "FinanceBackup", "FrontBoard", "GameKit",
    "GroupContainersAlias", "HomeKit", "IdentityServices", "IntelligencePlatform",
    "Intents", "KeyboardServices", "LanguageModeling", "LockdownMode", "Mail",
    "MediaAnalysis", "Messages", "Metadata", "Mobile Documents", "MobileDevice",
    "News", "Passes", "PersonalizationPortrait", "Photos", "PrivateCloudCompute",
    "Reminders", "ResponseKit", "Safari", "SafariSafeBrowsing", "SafariSandboxBroker",
    "ScreenRecordings", "StatusKit", "Suggestions", "SyncedPreferences", "Translation",
    "UnifiedAssetFramework", "Weather", "homeenergyd", "studentd",
    "Developer", "Perl", "Ruby", "Java", "Python", "Catacomb", "InstallerSandboxes",
    "Trial", "Updates", "Staging", "ContainerManager", "Daemon Containers",
    "ColorPickers", "Colors", "Compositions", "Contextual Menu Items", "Documentation",
    "DriverExtensions", "Favorites", "FontCollections", "Fonts", "Image Capture",
    "Input Methods", "Jupyter", "Keyboard", "Keyboard Layouts", "Keychains",
    "Managed Preferences", "PDF Services", "Printers", "QuickLook", "Receipts",
    "Screen Savers", "ScriptingAdditions", "Scripts", "Sharing", "Shortcuts",
    "Sounds", "Speech", "Spelling", "Spotlight", "User Pictures", "User Template",
    "Video", "WebServer", "Workflows",
    "com.apple.AppleMediaServices", "com.apple.WatchListKit", "com.apple.aiml.instrumentation",
    "com.apple.appleaccountd", "com.apple.bluetooth.services.cloud", "com.apple.bluetoothuser",
    "com.apple.familycircled", "com.apple.iTunesCloud", "com.apple.internal.ck"
]

let skipReverse: [String] = [
    "apple", "temporary", "btserver", "proapps", "scripteditor", "ilife", "livefsd", "siritoday",
    "addressbook", "animoji", "appstore", "askpermission", "callhistory", "clouddocs", "diskimages",
    "dock", "facetime", "fileprovider", "instruments", "knowledge", "mobilesync", "syncservices",
    "homeenergyd", "icloud", "icdd", "networkserviceproxy", "familycircle", "geoservices",
    "installation", "passkit", "sharedimagecache", "desktop", "mbuseragent", "swiftpm", "baseband",
    "coresimulator", "photoslegacyupgrade", "photosupgrade", "siritts", "ipod", "globalpreferences",
    "apmanalytics", "apmexperiment", "avatarcache", "byhost", "contextstoreagent", "mobilemeaccounts",
    "mobiledocuments", "mobile", "intentbuilderc", "loginwindow", "momc", "replayd",
    "sharedfilelistd", "clang", "audiocomponent", "csexattrcryptoservice", "livetranscriptionagent",
    "sandboxhelper", "statuskitagent", "betaenrollmentd", "contentlinkingd",
    "diagnosticextensionsd", "gamed", "heard", "homed", "itunescloudd", "lldb", "mds",
    "mediaanalysisd", "metrickitd", "mobiletimerd", "proactived", "ptpcamerad", "studentd",
    "talagent", "watchlistd", "apptranslocation", "xcrun", "ds_store", "caches", "crashreporter",
    "trash", "amsdatamigratortool", "arfilecache", "assistant", "chromium",
    "cloudkit", "webkit", "databases", "diagnostic", "cache", "gamekit", "homebrew", "logi",
    "microsoft", "mozilla", "sync", "google", "sentinel", "hexnode", "sentry", "tvappservices",
    "reminders", "pbs", "notarytool", "differentialprivacy", "storeassetd", "webpush",
    "storedownloadd", "fsck", "crash", "python", "discrecording", "photossearch", "pylint", "jamf",
    "scopedbookmarkagent", "anonymous", "identifier", "isolated", "nobackup",
    "privacypreservingmeasurement", "symbols", "stickersd", "privatecloudcomputed", "tipsd",
    "controlcenter", "contactsd", "staticcheck", "index", "segment", "sparkle", "summaryevents",
    "launchdarkly", "identityservicesd", "embeddedbinaryvalidationutility", "comalienator88",
    "aaprofilepicture", "minilauncher", "jna", "automator", "locationaccessstored", "spotlight", "cef"
]

private let supportedExtensions: Set<String> = [
    "", "plist", "json", "log", "db", "sqlite", "sqlite-shm", "sqlite-wal", "sqlite3",
    "dat", "cache", "lock", "txt", "yaml", "yml", "xml", "ini", "conf", "cfg", "pid",
    "tmp", "bak", "old", "swp", "data", "binarycookies", "storedata", "lockfile",
    "wal", "shm", "appex", "saver", "kext", "framework", "bundle", "plugin",
    "qlgenerator", "mdimporter", "prefpane", "wdgt", "definition", "abplugin",
    "service", "action", "workflow", "scptd", "scpt", "sh", "py", "js"
]

func isSupportedFileType(at path: String) -> Bool {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return true }
    let ext = (path as NSString).pathExtension.lowercased()
    if supportedExtensions.contains(ext) { return true }
    return ext.isEmpty
}

// MARK: - app / scanners

enum Sensitivity { case strict, enhanced, deep }

class AppPathFinder {
    let appInfo: AppInfo
    let sensitivity: Sensitivity
    private var collection: Set<URL> = []

    private let formattedBundleId: String
    private let bundleLastTwoComponents: String
    private let formattedAppName: String
    private let formattedAppNameStripped: String?
    private let appNameLettersOnly: String
    private let pathComponentName: String
    private let useBundleIdentifier: Bool
    private let formattedCompanyName: String?
    private let formattedEntitlements: [String]
    private let formattedTeamIdentifier: String?
    private let formattedBaseBundleId: String?

    init(appInfo: AppInfo, sensitivity: Sensitivity = .strict) {
        self.appInfo = appInfo
        self.sensitivity = sensitivity

        self.formattedBundleId = appInfo.bundleIdentifier.normalized()
        let rawComponents = appInfo.bundleIdentifier.components(separatedBy: ".")
        let bundleComponents = rawComponents.compactMap { $0 != "-" ? $0.lowercased() : nil }
        self.bundleLastTwoComponents = bundleComponents.suffix(2).joined()
        self.formattedAppName = appInfo.appName.normalized()
        self.appNameLettersOnly = self.formattedAppName.filter { $0.isLetter }
        self.pathComponentName = appInfo.path.lastPathComponent.replacingOccurrences(of: ".app", with: "")
        self.useBundleIdentifier = AppPathFinder.isValidBundleIdentifier(appInfo.bundleIdentifier)

        if rawComponents.count == 3 {
            self.formattedCompanyName = rawComponents[1].normalized()
        } else {
            self.formattedCompanyName = nil
        }

        self.formattedEntitlements = appInfo.entitlements?.compactMap {
            let f = $0.normalized()
            return f.isEmpty ? nil : f
        } ?? []

        self.formattedTeamIdentifier = appInfo.teamIdentifier?.normalized()

        let commonSuffixes: Set<String> = ["helper", "agent", "daemon", "service", "xpc", "launcher", "updater", "installer", "uninstaller", "login", "extension", "plugin"]
        if rawComponents.count >= 4, let last = rawComponents.last?.lowercased(), commonSuffixes.contains(last) {
            self.formattedBaseBundleId = rawComponents.dropLast().joined(separator: ".").normalized()
        } else {
            self.formattedBaseBundleId = nil
        }

        let stripped = appInfo.appName.strippingTrailingDigits().normalized()
        self.formattedAppNameStripped = (stripped != self.formattedAppName && !stripped.isEmpty) ? stripped : nil
    }

    private static func isValidBundleIdentifier(_ id: String) -> Bool {
        let parts = id.components(separatedBy: ".")
        if parts.count == 1 { return id.count >= 5 }
        return true
    }

    private func specificCondition(normalizedItemName: String, scannedItemURL: URL) -> Bool {
        if scannedItemURL.path.contains("/Desktop/") && scannedItemURL.pathExtension == "app" {
            let desktopAppName = scannedItemURL.deletingPathExtension().lastPathComponent.normalized()
            if desktopAppName == formattedAppName || desktopAppName == appNameLettersOnly { return true }
        }
        if appInfo.steam && scannedItemURL.path.contains("/Library/Application Support/Steam/steamapps/common/") {
            let folderName = scannedItemURL.lastPathComponent.normalized()
            if folderName == formattedAppName || folderName == appNameLettersOnly { return true }
        }
        if appInfo.steam && scannedItemURL.path.contains("/Library/Application Support/Steam/steamapps/") &&
           scannedItemURL.lastPathComponent.hasPrefix("appmanifest_") && scannedItemURL.pathExtension == "acf" {
            let filename = scannedItemURL.lastPathComponent
            if let idFromFile = extractGameId(from: filename),
               let idFromLauncher = getSteamGameId(from: appInfo.path) {
                return idFromFile == idFromLauncher
            }
        }

        for ef in formattedEntitlements {
            let isMatch = sensitivity == .strict ? normalizedItemName == ef : normalizedItemName.contains(ef)
            if isMatch { return true }
        }

        for cond in conditions {
            if useBundleIdentifier && formattedBundleId.contains(cond.bundleId) {
                if cond.exclude.contains(where: { normalizedItemName.contains($0) }) { return false }
                if cond.include.contains(where: { normalizedItemName.contains($0) }) { return true }
            }
        }

        if appInfo.webApp { return normalizedItemName.contains(formattedBundleId) }

        let fullBundleMatch = normalizedItemName.contains(formattedBundleId)
        let strict = sensitivity == .strict

        let appNameMatch = !formattedAppName.isEmpty && (strict ? normalizedItemName == formattedAppName : normalizedItemName.contains(formattedAppName))
        let pathNameMatch = !pathComponentName.isEmpty && (strict ? normalizedItemName == pathComponentName : normalizedItemName.contains(pathComponentName))
        let appNameLettersMatch = !appNameLettersOnly.isEmpty && (strict ? normalizedItemName == appNameLettersOnly : normalizedItemName.contains(appNameLettersOnly))

        let twoComponentMatch = sensitivity != .strict ? normalizedItemName.contains(bundleLastTwoComponents) : false
        let companyMatch: Bool = {
            if sensitivity == .deep, let c = formattedCompanyName, !c.isEmpty { return normalizedItemName.contains(c) }
            return false
        }()
        let teamIdMatch: Bool = {
            if sensitivity == .deep, let t = formattedTeamIdentifier, !t.isEmpty { return normalizedItemName.contains(t) }
            return false
        }()
        let baseBundleIdMatch: Bool = {
            if let b = formattedBaseBundleId, !b.isEmpty { return normalizedItemName.contains(b) }
            return false
        }()
        let strippedNameMatch: Bool = {
            if sensitivity != .strict, let s = formattedAppNameStripped, !s.isEmpty { return normalizedItemName.contains(s) }
            return false
        }()

        return (useBundleIdentifier && fullBundleMatch) ||
            appNameMatch || pathNameMatch || appNameLettersMatch ||
            twoComponentMatch || companyMatch || teamIdMatch ||
            baseBundleIdMatch || strippedNameMatch
    }

    private func extractGameId(from filename: String) -> String? {
        let parts = filename.components(separatedBy: "_")
        guard parts.count >= 2 else { return nil }
        return parts[1].components(separatedBy: ".").first
    }

    private func getSteamGameId(from appPath: URL) -> String? {
        let runSh = appPath.appendingPathComponent("Contents/MacOS/run.sh")
        guard FileManager.default.fileExists(atPath: runSh.path) else { return nil }
        guard let content = try? String(contentsOf: runSh, encoding: .utf8) else { return nil }
        if let r = content.range(of: "steam://run/") {
            let after = String(content[r.upperBound...])
            let id = after.components(separatedBy: CharacterSet.decimalDigits.inverted).first
            return (id?.isEmpty == false) ? id : nil
        }
        return nil
    }

    private func shouldSkipItem(_ normalizedItemName: String, at scannedItemURL: URL) -> Bool {
        if collection.contains(scannedItemURL) { return true }
        for sc in skipConditions {
            for sp in sc.skipPaths where scannedItemURL.path.hasPrefix(sp) { return true }
            if sc.skipPrefix.contains(where: normalizedItemName.hasPrefix) {
                let allowed = sc.allowPrefixes.contains(where: normalizedItemName.hasPrefix)
                if !allowed { return true }
            }
        }
        return false
    }

    private func processLocation(_ location: String, currentDepth: Int = 0, maxDepth: Int = 1, isLibraryRootSearch: Bool = false) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: location) else { return }
        var subdirs: [URL] = []
        for name in contents {
            let url = URL(fileURLWithPath: location).appendingPathComponent(name)
            let normalized: String
            if url.hasDirectoryPath || url.pathExtension.isEmpty {
                normalized = name.normalized()
            } else {
                normalized = (name as NSString).deletingPathExtension.normalized()
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if shouldSkipItem(normalized, at: url) { continue }

            if specificCondition(normalizedItemName: normalized, scannedItemURL: url) {
                let toAdd: URL
                if isLibraryRootSearch && currentDepth == 2 {
                    let parent = url.deletingLastPathComponent()
                    let parentName = parent.lastPathComponent
                    toAdd = standardLibrarySubdirectories.contains(parentName) ? url : parent
                } else {
                    toAdd = url
                }
                collection.insert(toAdd)
            }

            if isDir.boolValue && currentDepth < maxDepth {
                if isLibraryRootSearch && currentDepth == 0 {
                    if !skipDeepSearch.contains(url.lastPathComponent) { subdirs.append(url) }
                } else {
                    subdirs.append(url)
                }
            }
        }
        if currentDepth < maxDepth {
            for s in subdirs {
                processLocation(s.path, currentDepth: currentDepth + 1, maxDepth: maxDepth, isLibraryRootSearch: isLibraryRootSearch)
            }
        }
    }

    private func isLibraryRoot(_ location: String) -> Bool {
        return location == "\(home)/Library" || location == "/Library"
    }

    private func getAllContainers() -> [URL] {
        var out: [URL] = []
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appInfo.bundleIdentifier),
           FileManager.default.fileExists(atPath: groupURL.path) {
            out.append(groupURL)
        }
        let containersDir = URL(fileURLWithPath: "\(home)/Library/Containers")
        if let dirs = try? FileManager.default.contentsOfDirectory(at: containersDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for d in dirs {
                let name = d.lastPathComponent
                let range = NSRange(location: 0, length: name.utf16.count)
                guard uuidContainerRegex.firstMatch(in: name, options: [], range: range) != nil else { continue }
                let metaURL = d.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
                if let dict = NSDictionary(contentsOf: metaURL),
                   let bid = dict["MCMMetadataIdentifier"] as? String,
                   bid == appInfo.bundleIdentifier {
                    out.append(d)
                }
            }
        }
        return out
    }

    private func handleOutliers(include: Bool) -> [URL] {
        let bidFormatted = appInfo.bundleIdentifier.normalized()
        var out: [URL] = []
        for c in conditions where bidFormatted.contains(c.bundleId) {
            out.append(contentsOf: include ? c.includeForce : c.excludeForce)
        }
        return out
    }

    func findPaths() -> [URL] {
        if !appInfo.path.path.contains(".Trash") { collection.insert(appInfo.path) }
        for c in getAllContainers() { collection.insert(c) }

        if !appInfo.webApp {
            for loc in appsLocations {
                let isLib = isLibraryRoot(loc)
                let maxDepth = isLib ? 2 : 1
                processLocation(loc, currentDepth: 0, maxDepth: maxDepth, isLibraryRootSearch: isLib)
            }
        }

        let outliersInclude = handleOutliers(include: true)
        let outliersExclude = handleOutliers(include: false)
        for o in outliersInclude { collection.insert(o) }
        let excludePaths = Set(outliersExclude.map { $0.path })
        let temp = Array(collection).filter { !excludePaths.contains($0.path) }
        let sorted = temp.map { $0.standardizedFileURL }.sorted { $0.path < $1.path }
        var finalList: [URL] = []
        var prev: URL?
        for u in sorted {
            if let p = prev, u.path.hasPrefix(p.path + "/") { continue }
            finalList.append(u)
            prev = u
        }
        return finalList
    }
}

// MARK: - app / commands

func cmdAppList(_ args: [String]) {
    let apps = enumerateInstalledApps().filter {
        ($0.path.path.hasPrefix("/Applications/") || $0.path.path.hasPrefix("\(home)/Applications/"))
        && !$0.bundleIdentifier.hasPrefix("com.apple.")
    }
    var rows: [(name: String, size: Int64)] = []
    for (i, app) in apps.enumerated() {
        progress(i + 1, apps.count, app.appName)
        let paths = AppPathFinder(appInfo: app).findPaths()
        let size = paths.reduce(Int64(0)) { $0 + totalSizeOnDisk(for: $1) }
        rows.append((app.appName, size))
    }
    clearProgress()
    rows.sort { $0.size > $1.size }
    printSizeTable("NAME", rows, unitLabel: "apps")
}

func resolveAppArg(_ input: String) -> URL {
    let stripped = input.hasSuffix(".app") ? String(input.dropLast(4)) : input
    let installed = enumerateInstalledApps().filter {
        $0.path.path.hasPrefix("/Applications/") || $0.path.path.hasPrefix("\(home)/Applications/")
    }
    let matches = installed.filter { $0.appName.lowercased() == stripped.lowercased() }
    if matches.count == 1 { return matches[0].path }
    if matches.count > 1 {
        let paths = matches.map { $0.path.path }.joined(separator: "\n  ")
        reportError("Multiple apps named '\(input)':\n  \(paths)")
    }
    reportError("No app named '\(input)' found.\nRun `app-list` to see available names.")
}

func cmdAppUninstall(_ args: [String]) {
    guard let target = positionalArgs(args).first else {
        reportError("Usage: cleaner app-uninstall <name>")
    }
    let url = resolveAppArg(target)
    guard let info = loadAppInfo(at: url) else { reportError("Error: could not read Info.plist at \(url.path)") }

    let strictPaths = AppPathFinder(appInfo: info, sensitivity: .strict).findPaths()
    let enhancedPaths = AppPathFinder(appInfo: info, sensitivity: .enhanced).findPaths()
    let deepPaths = AppPathFinder(appInfo: info, sensitivity: .deep).findPaths()
    let strictSet = Set(strictPaths.map { $0.path })
    let enhancedSet = Set(enhancedPaths.map { $0.path })
    let enhancedNew = enhancedPaths.filter { !strictSet.contains($0.path) }
    let deepNew = deepPaths.filter { !enhancedSet.contains($0.path) }

    func makeRow(_ url: URL, header: String?, defaultOn: Bool) -> SelectableRow {
        SelectableRow(
            label: tildeCollapse(url.path),
            url: url,
            size: totalSizeOnDisk(for: url),
            defaultSelected: defaultOn,
            sectionHeader: header
        )
    }
    var rows: [SelectableRow] = []
    for (i, u) in strictPaths.enumerated()   { rows.append(makeRow(u, header: i == 0 ? "STRICT"   : nil, defaultOn: true))  }
    for (i, u) in enhancedNew.enumerated()   { rows.append(makeRow(u, header: i == 0 ? "ENHANCED" : nil, defaultOn: false)) }
    for (i, u) in deepNew.enumerated()       { rows.append(makeRow(u, header: i == 0 ? "DEEP"     : nil, defaultOn: false)) }
    selectAndTrash(rows: rows)
}

// ═══════════════════════════════════════════════════════════════════════════
// PART 4 — MODULE: pkg
// ═══════════════════════════════════════════════════════════════════════════

struct PkgInfo {
    let id: String
    let version: String
    let installLocation: String
    let installDate: String
}

func listPkgs() -> [String] {
    guard let out = runCmd("/usr/sbin/pkgutil", ["--pkgs"]) else { return [] }
    return out.split(separator: "\n").map(String.init).sorted()
}

func pkgInfo(_ pkgId: String) -> PkgInfo? {
    guard let out = runCmd("/usr/sbin/pkgutil", ["--pkg-info", pkgId]) else { return nil }
    var d: [String: String] = [:]
    for line in out.split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 { d[parts[0]] = parts[1] }
    }
    return PkgInfo(
        id: d["package-id"] ?? pkgId,
        version: d["version"] ?? "",
        installLocation: d["location"] ?? "/",
        installDate: d["install-time"] ?? ""
    )
}

func pkgFiles(_ pkgId: String) -> [String] {
    guard let info = pkgInfo(pkgId),
          let out = runCmd("/usr/sbin/pkgutil", ["--only-files", "--files", pkgId]) else { return [] }
    var prefix = info.installLocation
    if !prefix.hasPrefix("/") { prefix = "/" + prefix }
    if prefix.isEmpty { prefix = "/" }
    return out.split(separator: "\n").map { line -> String in
        let p = String(line).trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("/") { return p }
        return prefix == "/" ? "/\(p)" : "\(prefix)/\(p)"
    }
}

private let bundleExtensions: Set<String> = [
    "app", "bundle", "framework", "kext", "jdk", "plugin", "prefpane",
    "qlgenerator", "saver", "mdimporter", "appex", "wdgt"
]

func pkgInstallRoot(of path: String) -> String {
    let parts = path.split(separator: "/").map(String.init)
    var acc = ""
    for part in parts {
        acc += "/" + part
        let ext = (part as NSString).pathExtension.lowercased()
        if bundleExtensions.contains(ext) { return acc }
    }
    return path
}

func pkgReceiptPaths(_ pkgId: String) -> [String] {
    return [
        "/var/db/receipts/\(pkgId).plist",
        "/var/db/receipts/\(pkgId).bom",
        "/private/var/db/receipts/\(pkgId).plist",
        "/private/var/db/receipts/\(pkgId).bom"
    ].filter { FileManager.default.fileExists(atPath: $0) }
}

// MARK: - pkg / commands

func pkgSizeAndFiles(_ pkgId: String) -> (size: Int64, files: Int) {
    let bomPath = pkgReceiptPaths(pkgId).first { $0.hasSuffix(".bom") }
    guard let bom = bomPath,
          let out = runCmd("/usr/bin/lsbom", ["-p", "sf", bom]) else { return (0, 0) }
    var total: Int64 = 0
    var count = 0
    for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count >= 1 else { continue }
        let sizeStr = String(parts[0]).trimmingCharacters(in: .whitespaces)
        if sizeStr.isEmpty { continue }
        guard let s = Int64(sizeStr) else { continue }
        total += s
        count += 1
    }
    return (total, count)
}

func pkgInstallDate(_ pkgId: String) -> String {
    guard let info = pkgInfo(pkgId), !info.installDate.isEmpty,
          let ts = Double(info.installDate) else { return "?" }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date(timeIntervalSince1970: ts))
}

func cmdPkgList(_ args: [String]) {
    let pkgs = listPkgs().filter { !$0.hasPrefix("com.apple.") }
    var rows: [(name: String, size: Int64)] = []
    for (i, id) in pkgs.enumerated() {
        progress(i + 1, pkgs.count, id)
        let (sz, _) = pkgSizeAndFiles(id)
        rows.append((id, sz))
    }
    clearProgress()
    rows.sort { $0.size > $1.size }
    printSizeTable("NAME", rows, unitLabel: "pkgs")
}

func pkgEntries(_ pkgId: String) -> [(path: String, isFile: Bool)] {
    let bomPath = pkgReceiptPaths(pkgId).first { $0.hasSuffix(".bom") }
    guard let bom = bomPath,
          let out = runCmd("/usr/bin/lsbom", ["-p", "sf", bom]),
          let info = pkgInfo(pkgId) else { return [] }
    var prefix = info.installLocation
    if !prefix.hasPrefix("/") { prefix = "/" + prefix }
    if prefix.isEmpty { prefix = "/" }

    var entries: [(String, Bool)] = []
    for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { continue }
        let sizeStr = String(parts[0]).trimmingCharacters(in: .whitespaces)
        var rel = String(parts[1]).trimmingCharacters(in: .whitespaces)
        if rel.isEmpty || rel == "." { continue }
        if rel.hasPrefix("./") { rel = String(rel.dropFirst(2)) }
        let abs = rel.hasPrefix("/") ? rel : (prefix == "/" ? "/\(rel)" : "\(prefix)/\(rel)")
        entries.append((abs, !sizeStr.isEmpty))
    }
    return entries
}

func pkgInstallTargets(_ pkgId: String) -> [URL] {
    guard let info = pkgInfo(pkgId),
          let bom = pkgReceiptPaths(pkgId).first(where: { $0.hasSuffix(".bom") })
    else { return [] }
    var prefix = info.installLocation
    if !prefix.hasPrefix("/") { prefix = "/" + prefix }
    if prefix.isEmpty { prefix = "/" }
    if prefix.hasSuffix("/") && prefix != "/" { prefix = String(prefix.dropLast()) }

    let bashScript = #"""
    set -u
    BOM="$1"
    PREFIX="$2"
    TMP=$(mktemp -d -t cleaner.XXXXXX)
    trap 'rm -rf "$TMP"' EXIT

    # pass A: parent dirs with ≥10 file children, prefixed to absolute
    lsbom -p sf "$BOM" 2>/dev/null | awk -F'\t' -v p="$PREFIX" '
        $1 != "" {
            x = $2
            sub(/^\.\
            sub(/\/[^\/]+$/, "", x)
            if (substr(x, 1, 1) != "/") {
                if (p == "/" || p == "") x = "/" x
                else x = p "/" x
            }
            c[x]++
        }
        END { for (d in c) if (c[d] >= 10) print d }
    ' | sort > "$TMP/cand"

    # pass B: dedup nested (lex-sorted, skip rows under previous-kept)
    awk '
        { if (length(last) > 0 && substr($0, 1, length(last)+1) == last "/") next
          print; last = $0 }
    ' "$TMP/cand" > "$TMP/wholesale"

    echo "===WHOLESALE==="
    cat "$TMP/wholesale"

    # pass C: files NOT under any wholesale dir
    echo "===FILES==="
    lsbom -p sf "$BOM" 2>/dev/null | awk -F'\t' -v p="$PREFIX" -v wf="$TMP/wholesale" '
        BEGIN {
            while ((getline ln < wf) > 0) w[ln] = 1
            close(wf)
        }
        $1 != "" {
            x = $2
            sub(/^\.\
            if (substr(x, 1, 1) != "/") {
                if (p == "/" || p == "") x = "/" x
                else x = p "/" x
            }
            anc = x
            sub(/\/[^\/]+$/, "", anc)
            while (length(anc) > 0 && anc != "/") {
                if (anc in w) next
                sub(/\/[^\/]+$/, "", anc)
            }
            print x
        }
    '
    """#
    guard let out = runCmd("/bin/bash", ["-c", bashScript, "bash", bom, prefix]) else { return [] }

    var wholesale: [String] = []
    var loneFiles: [String] = []
    var section = ""
    for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
        let l = String(line)
        if l == "===WHOLESALE===" { section = "w"; continue }
        if l == "===FILES===" { section = "f"; continue }
        if l.isEmpty { continue }
        if section == "w" { wholesale.append(l) }
        else if section == "f" { loneFiles.append(l) }
    }

    var targets: Set<String> = []
    for w in wholesale {
        targets.insert(URL(fileURLWithPath: w).resolvingSymlinksInPath().path)
    }
    for f in loneFiles {
        let root = pkgInstallRoot(of: f)
        targets.insert(URL(fileURLWithPath: root).resolvingSymlinksInPath().path)
    }
    let existing = targets.filter { FileManager.default.fileExists(atPath: $0) }
    return existing.sorted().map { URL(fileURLWithPath: $0) }
}

func cmdPkgUninstall(_ args: [String]) {
    guard let pkgId = positionalArgs(args).first else {
        reportError("Usage: cleaner pkg-uninstall <pkg-id>")
    }
    guard pkgInfo(pkgId) != nil else { reportError("Error: package \(pkgId) not found") }
    var allTargets = pkgInstallTargets(pkgId)

    let receipts = Set(pkgReceiptPaths(pkgId)
        .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
    for r in receipts { allTargets.append(URL(fileURLWithPath: r)) }

    let sorted = allTargets.map { $0.standardizedFileURL.path }.sorted()
    var deduped: [URL] = []
    var prev: String?
    for p in sorted {
        if let pr = prev, p.hasPrefix(pr + "/") { continue }
        deduped.append(URL(fileURLWithPath: p))
        prev = p
    }
    let rows = deduped.map { SelectableRow(label: tildeCollapse($0.path), url: $0, size: totalSizeOnDisk(for: $0)) }
    selectAndTrash(rows: rows)
}

// ═══════════════════════════════════════════════════════════════════════════
// PART 5 — MODULE: plugin
// ═══════════════════════════════════════════════════════════════════════════

// MARK: - plugin / local helpers

let genericIdSegments: Set<String> = [
    "com", "org", "net", "io", "app", "co", "info", "dev", "edu", "gov", "mil",
    "helper", "agent", "daemon", "service", "xpc", "launcher", "updater", "installer", "uninstaller",
    "login", "extension", "plugin", "audio", "video", "macos", "mac", "ios", "osx", "package", "framework"
]

func vendorTokens(_ bundleId: String) -> Set<String> {
    return Set(bundleId.split(separator: ".").map(String.init)
        .filter { $0.count >= 4 && !genericIdSegments.contains($0.lowercased()) }
        .map { $0.lowercased() })
}

// MARK: - plugin / types

struct PluginCategory {
    let name: String
    let paths: [String]
}

struct PluginEntry {
    let category: String
    let path: URL
    let size: Int64
    let owner: String?
}

let pluginCategories: [PluginCategory] = [
    PluginCategory(name: "Audio (VST/AU/CLAP)", paths: [
        "\(home)/Library/Audio/Plug-Ins/Components",
        "\(home)/Library/Audio/Plug-Ins/HAL",
        "\(home)/Library/Audio/Plug-Ins/MAS",
        "\(home)/Library/Audio/Plug-Ins/VST",
        "\(home)/Library/Audio/Plug-Ins/VST3",
        "\(home)/Library/Audio/Plug-Ins/CLAP",
        "/Library/Audio/Plug-Ins/HAL",
        "/Library/Audio/Plug-Ins/VST",
        "/Library/Audio/Plug-Ins/VST3",
        "/Library/Audio/Plug-Ins/CLAP",
        "/Library/Audio/Plug-Ins/Components"
    ]),
    PluginCategory(name: "PreferencePanes", paths: ["/Library/PreferencePanes", "\(home)/Library/PreferencePanes"]),
    PluginCategory(name: "QuickLook", paths: ["/Library/QuickLook", "\(home)/Library/QuickLook"]),
    PluginCategory(name: "Screen Savers", paths: ["/Library/Screen Savers", "\(home)/Library/Screen Savers"]),
    PluginCategory(name: "Internet Plug-Ins", paths: ["/Library/Internet Plug-Ins", "\(home)/Library/Internet Plug-Ins"]),
    PluginCategory(name: "Core Image", paths: ["/Library/CoreImage", "\(home)/Library/CoreImage"]),
    PluginCategory(name: "Color Pickers", paths: ["/Library/ColorPickers", "\(home)/Library/ColorPickers"]),
    PluginCategory(name: "Fonts", paths: ["\(home)/Library/Fonts"]),
    PluginCategory(name: "Dictionaries", paths: ["/Library/Dictionaries", "\(home)/Library/Dictionaries"]),
    PluginCategory(name: "Automator", paths: ["/Library/Automator", "\(home)/Library/Automator"]),
    PluginCategory(name: "Safari Extensions", paths: ["/Library/Safari/Extensions", "\(home)/Library/Safari/Extensions"]),
    PluginCategory(name: "Motion Templates", paths: [
        "\(home)/Movies/Motion Templates",
        "/Library/Application Support/Final Cut Pro System Support/Plug-ins"
    ]),
    PluginCategory(name: "Spotlight Importers", paths: ["/Library/Spotlight", "\(home)/Library/Spotlight"]),
    PluginCategory(name: "Services Menu", paths: ["/Library/Services", "\(home)/Library/Services"]),
    PluginCategory(name: "Address Book", paths: ["\(home)/Library/Address Book Plug-Ins"]),
    PluginCategory(name: "Contextual Menu", paths: ["/Library/Contextual Menu Items", "\(home)/Library/Contextual Menu Items"]),
    PluginCategory(name: "Input Methods", paths: ["/Library/Input Methods", "\(home)/Library/Input Methods"]),
    PluginCategory(name: "Widgets", paths: ["/Library/Widgets", "\(home)/Library/Widgets"])
]

func readPluginBundleId(_ pluginURL: URL) -> String? {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: pluginURL.path, isDirectory: &isDir), isDir.boolValue else { return nil }
    let candidates = [
        pluginURL.appendingPathComponent("Contents/Info.plist"),
        pluginURL.appendingPathComponent("Info.plist")
    ]
    for plistURL in candidates where FileManager.default.fileExists(atPath: plistURL.path) {
        guard let data = try? Data(contentsOf: plistURL),
              let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { continue }
        if let bid = dict["CFBundleIdentifier"] as? String, !bid.isEmpty { return bid }
    }
    return nil
}

func tryFindPluginOwner(pluginURL: URL, apps: [AppInfo]) -> String? {
    let filename = pluginURL.lastPathComponent
    let normName = filename.normalized()
    let baseNoExt = (filename as NSString).deletingPathExtension.normalized()

    if let pluginBid = readPluginBundleId(pluginURL) {
        let pluginComponents = pluginBid.split(separator: ".").map(String.init)
        if pluginComponents.count >= 2 {
            let prefix2 = pluginComponents.prefix(2).joined(separator: ".")
            for app in apps {
                if app.bundleIdentifier == pluginBid { return app.appName }
                if app.bundleIdentifier.hasPrefix(prefix2 + ".") { return app.appName }
                if pluginBid.hasPrefix(app.bundleIdentifier + ".") { return app.appName }
            }
        }
        let pluginVendors = vendorTokens(pluginBid)
        if !pluginVendors.isEmpty {
            for app in apps {
                if !pluginVendors.isDisjoint(with: vendorTokens(app.bundleIdentifier)) {
                    return app.appName
                }
            }
        }
    }

    for app in apps {
        let bidF = app.bundleIdentifier.normalized()
        let nameF = app.appName.normalized()
        if bidF.count >= 5 && (normName.contains(bidF) || baseNoExt.contains(bidF)) { return app.appName }
        if nameF.count >= 5 {
            if normName.contains(nameF) || baseNoExt.contains(nameF) { return app.appName }
            if nameF.contains(baseNoExt) || nameF.contains(normName) { return app.appName }
        }
        if let ents = app.entitlements {
            for e in ents where e.count >= 5 {
                let ef = e.normalized()
                if normName.contains(ef) || baseNoExt.contains(ef) { return app.appName }
            }
        }
    }
    return nil
}

func shouldIncludePluginFile(name: String, isDirectory: Bool, category: String) -> Bool {
    let lower = name.lowercased()
    switch category {
    case "Audio (VST/AU/CLAP)": return true
    case "PreferencePanes":     return lower.hasSuffix(".prefpane")
    case "QuickLook":           return lower.hasSuffix(".qlgenerator")
    case "Screen Savers":       return lower.hasSuffix(".saver")
    case "Internet Plug-Ins":   return lower.hasSuffix(".plugin") || lower.hasSuffix(".webplugin")
    case "Core Image":          return lower.hasSuffix(".plugin")
    case "Color Pickers":       return lower.hasSuffix(".colorpicker")
    case "Fonts":               return [".ttf", ".otf", ".dfont", ".ttc"].contains { lower.hasSuffix($0) }
    case "Dictionaries":        return lower.hasSuffix(".dictionary")
    case "Automator":           return lower.hasSuffix(".action") || lower.hasSuffix(".workflow")
    case "Safari Extensions":   return lower.hasSuffix(".safariextz") || lower.hasSuffix(".appex")
    case "Motion Templates":    return isDirectory || lower.contains("template") || lower.hasSuffix(".motn")
    case "Spotlight Importers": return lower.hasSuffix(".mdimporter")
    case "Services Menu":       return lower.hasSuffix(".service")
    case "Address Book":        return isDirectory || lower.hasSuffix(".plugin")
    case "Contextual Menu":     return isDirectory || lower.hasSuffix(".plugin") || lower.hasSuffix(".bundle")
    case "Input Methods":       return isDirectory || lower.hasSuffix(".app") || lower.hasSuffix(".bundle")
    case "Widgets":             return lower.hasSuffix(".wdgt") || lower.hasSuffix(".appex")
    default:                    return true
    }
}

func scanPlugins(apps: [AppInfo]) -> [String: [PluginEntry]] {
    var out: [String: [PluginEntry]] = [:]
    for cat in pluginCategories {
        var entries: [PluginEntry] = []
        for p in cat.paths {
            guard let items = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: p), includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { continue }
            for item in items {
                if item.lastPathComponent == ".DS_Store" { continue }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
                if !shouldIncludePluginFile(name: item.lastPathComponent, isDirectory: isDir.boolValue, category: cat.name) { continue }
                let owner = tryFindPluginOwner(pluginURL: item, apps: apps)
                entries.append(PluginEntry(category: cat.name, path: item, size: totalSizeOnDisk(for: item), owner: owner))
            }
        }
        if !entries.isEmpty {
            out[cat.name] = entries.sorted { $0.path.lastPathComponent < $1.path.lastPathComponent }
        }
    }
    return out
}

// MARK: - plugin / commands

func cmdPluginList(_ args: [String]) {
    let apps = enumerateInstalledApps()
    var scan: [String: [PluginEntry]] = [:]
    for (i, cat) in pluginCategories.enumerated() {
        progress(i + 1, pluginCategories.count, cat.name)
        var entries: [PluginEntry] = []
        for p in cat.paths {
            guard let items = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: p), includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { continue }
            for item in items {
                if item.lastPathComponent == ".DS_Store" { continue }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
                if !shouldIncludePluginFile(name: item.lastPathComponent, isDirectory: isDir.boolValue, category: cat.name) { continue }
                let owner = tryFindPluginOwner(pluginURL: item, apps: apps)
                entries.append(PluginEntry(category: cat.name, path: item, size: totalSizeOnDisk(for: item), owner: owner))
            }
        }
        if !entries.isEmpty { scan[cat.name] = entries }
    }
    clearProgress()

    var all: [PluginEntry] = []
    for (_, list) in scan { all.append(contentsOf: list) }
    let sorted = all.sorted { $0.size > $1.size }
    let rows: [(name: String, size: Int64)] = sorted.map { ($0.path.lastPathComponent, $0.size) }
    printSizeTable("NAME", rows, unitLabel: "plugins")
}

func cmdPluginUninstall(_ args: [String]) {
    guard let target = positionalArgs(args).first else {
        reportError("Usage: cleaner plugin-uninstall <name>")
    }
    let apps = enumerateInstalledApps()
    let scan = scanPlugins(apps: apps)
    var all: [PluginEntry] = []
    for (_, list) in scan { all.append(contentsOf: list) }
    let chosen = all.filter { $0.path.lastPathComponent == target }
    if chosen.isEmpty { reportError("Error: no plugin named '\(target)'.\nRun `plugin-list` to see available names.") }

    let rows = chosen.map { SelectableRow(label: tildeCollapse($0.path.path), url: $0.path, size: $0.size) }
    selectAndTrash(rows: rows)
}

// ═══════════════════════════════════════════════════════════════════════════
// PART 6 — MODULE: devenv (tool-grouped path library)
// ═══════════════════════════════════════════════════════════════════════════

struct DevTool {
    let name: String
    let paths: [String]
}

struct DevToolEntry {
    let tool: DevTool
    let existingPaths: [String]
    let totalSize: Int64
}

func expandGlobPath(_ raw: String) -> [String] {
    let expanded = NSString(string: raw).expandingTildeInPath
    let trimmed = expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
    if !trimmed.contains("*") {
        return FileManager.default.fileExists(atPath: trimmed) ? [trimmed] : []
    }
    let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    var idx: Int? = nil
    for (i, c) in parts.enumerated() where c.contains("*") { idx = i; break }
    guard let wildIdx = idx else { return [trimmed] }
    let parent = parts.prefix(wildIdx).joined(separator: "/")
    let parentDir = parent.isEmpty ? "/" : parent
    let pattern = parts[wildIdx]
    let remainder = parts.dropFirst(wildIdx + 1).joined(separator: "/")
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: parentDir) else { return [] }
    let re = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*") + "$"
    let matched = entries.filter { $0.range(of: re, options: .regularExpression) != nil }
    var out: [String] = []
    for m in matched {
        let base = parentDir + "/" + m
        if remainder.isEmpty {
            if FileManager.default.fileExists(atPath: base) { out.append(base) }
        } else {
            out.append(contentsOf: expandGlobPath(base + "/" + remainder))
        }
    }
    return out
}

let devTools: [DevTool] = [
    DevTool(name: "Android Studio", paths: [
        "~/.android/",
        "~/Library/Application Support/Google/AndroidStudio*/",
        "~/Library/Logs/AndroidStudio/",
        "~/Library/Caches/Google/AndroidStudio*/"
    ]),
    DevTool(name: "Cargo", paths: [
        "~/.cargo/", "~/.cargo/git/", "~/.cargo/registry/"
    ]),
    DevTool(name: "Carthage", paths: [
        "~/Carthage/", "~/Library/Caches/org.carthage.CarthageKit/"
    ]),
    DevTool(name: "CocoaPods", paths: [
        "~/Library/Caches/CocoaPods/", "~/.cocoapods/repos/"
    ]),
    DevTool(name: "Composer", paths: ["~/.composer/cache/"]),
    DevTool(name: "Conda", paths: [
        "~/.conda/", "~/anaconda3/", "~/miniconda3/"
    ]),
    DevTool(name: "Cursor", paths: [
        "~/Library/Application Support/Cursor/",
        "~/Library/Application Support/Cursor/Cache",
        "~/Library/Application Support/Cursor/GPUCache",
        "~/Library/Application Support/Cursor/CachedConfigurations",
        "~/Library/Application Support/Cursor/CachedData",
        "~/Library/Application Support/Cursor/CachedExtensionVSIXs",
        "~/Library/Application Support/Cursor/CachedExtensions",
        "~/Library/Application Support/Cursor/CachedProfilesData",
        "~/Library/Application Support/Cursor/Code Cache",
        "~/Library/Application Support/Cursor/User",
        "~/.cursor/",
        "~/.cursor/extensions/"
    ]),
    DevTool(name: "Deno", paths: ["~/Library/Caches/deno"]),
    DevTool(name: "Go Modules", paths: [
        "~/go/bin/", "~/go/pkg/mod/"
    ]),
    DevTool(name: "Gradle", paths: [
        "~/.gradle/caches/", "~/.gradle/wrapper/"
    ]),
    DevTool(name: "Haskell Stack", paths: [
        "~/.stack/", "~/.stack/global-project/", "~/.stack/snapshots/"
    ]),
    DevTool(name: "IntelliJ IDEA", paths: [
        "~/Library/Application Support/JetBrains/",
        "~/Library/Caches/JetBrains/",
        "~/Library/Logs/JetBrains/"
    ]),
    DevTool(name: "Maven", paths: ["~/.m2/"]),
    DevTool(name: "Nix", paths: ["/nix/store/", "~/.cache/nix/"]),
    DevTool(name: "Npm", paths: [
        "/usr/local/lib/node_modules/",
        "~/.nvm/versions/node/*/",
        "~/.npm/",
        "~/.nvm/",
        "~/Library/pnpm/store",
        "~/.bun/install/cache"
    ]),
    DevTool(name: "Pip", paths: ["~/Library/Caches/pip/"]),
    DevTool(name: "Poetry", paths: [
        "~/Library/Caches/pypoetry/", "~/Library/Application Support/pypoetry/"
    ]),
    DevTool(name: "Pub", paths: [
        "~/.pub-cache/", "~/Library/Caches/flutter_engine/"
    ]),
    DevTool(name: "Pyenv", paths: ["~/.pyenv/", "~/.pyenv/cache/"]),
    DevTool(name: "Ruby Gems", paths: ["~/.gem/", "~/.gem/ruby/*/"]),
    DevTool(name: "Swift", paths: ["~/.swiftpm/"]),
    DevTool(name: "Uv", paths: [
        "~/.cache/uv/", "~/.config/uv/", "~/.local/share/uv/"
    ]),
    DevTool(name: "VS Code", paths: [
        "~/Library/Application Support/Code/",
        "~/Library/Application Support/Code/Cache",
        "~/Library/Application Support/Code/GPUCache",
        "~/Library/Application Support/Code/CachedConfigurations",
        "~/Library/Application Support/Code/CachedData",
        "~/Library/Application Support/Code/CachedExtensionVSIXs",
        "~/Library/Application Support/Code/CachedExtensions",
        "~/Library/Application Support/Code/CachedProfilesData",
        "~/Library/Application Support/Code/Code Cache",
        "~/Library/Application Support/Code/User",
        "~/.vscode/",
        "~/.vscode/extensions/",
        "~/.vscode/cli/"
    ]),
    DevTool(name: "Xcode", paths: [
        "~/Library/Caches/com.apple.dt.xcodebuild/",
        "~/Library/Caches/com.apple.dt.Xcode.sourcecontrol.Git/",
        "~/Library/Developer/CoreSimulator/Devices/",
        "~/Library/Developer/DeveloperDiskImages/",
        "~/Library/Developer/Xcode/Archives/",
        "~/Library/Developer/Xcode/DerivedData/",
        "~/Library/Developer/Xcode/DocumentationCache/",
        "~/Library/Developer/Xcode/iOS DeviceSupport/",
        "~/Library/Developer/Xcode/tvOS DeviceSupport/",
        "~/Library/Developer/Xcode/watchOS DeviceSupport/",
        "~/Library/Developer/Xcode/macOS DeviceSupport/",
        "~/Library/Developer/Xcode/UserData/"
    ]),
    DevTool(name: "Yarn", paths: [
        "~/.cache/yarn/", "~/.yarn-cache/", "~/.yarn/global/"
    ]),
    DevTool(name: "Zed", paths: [
        "~/.config/zed/",
        "~/Library/Caches/Zed/",
        "~/Library/Application Support/Zed/",
        "~/Library/Application Support/Zed/node/cache/"
    ])
]

func scanDevTools() -> [DevToolEntry] {
    var out: [DevToolEntry] = []
    for tool in devTools {
        var collected: [String] = []
        for p in tool.paths {
            for e in expandGlobPath(p) { collected.append(e) }
        }
        let sortedByLen = Array(Set(collected)).sorted { $0.count < $1.count }
        var roots: [String] = []
        for p in sortedByLen {
            let isChild = roots.contains { p.hasPrefix($0 + "/") }
            if !isChild { roots.append(p) }
        }
        let totalSize = roots.reduce(Int64(0)) { $0 + totalSizeOnDisk(for: URL(fileURLWithPath: $1)) }
        if !roots.isEmpty {
            out.append(DevToolEntry(tool: tool, existingPaths: roots, totalSize: totalSize))
        }
    }
    return out.sorted { $0.totalSize > $1.totalSize }
}

// MARK: - devenv / commands

func tildeCollapse(_ path: String) -> String {
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

func cmdDevenvList(_ args: [String]) {
    var raw: [(String, Int64)] = []
    for (i, tool) in devTools.enumerated() {
        progress(i + 1, devTools.count, tool.name)
        for p in tool.paths {
            for expanded in expandGlobPath(p) {
                let sz = totalSizeOnDisk(for: URL(fileURLWithPath: expanded))
                raw.append((tildeCollapse(expanded), sz))
            }
        }
    }
    clearProgress()
    var deduped: [(name: String, size: Int64)] = []
    let sortedByPath = raw.sorted { $0.0.count < $1.0.count }
    var keptRoots: [String] = []
    for (path, sz) in sortedByPath {
        let abs = path.hasPrefix("~/") ? "\(home)/\(path.dropFirst(2))" : path
        let kept = keptRoots.contains { kept in
            let keptAbs = kept.hasPrefix("~/") ? "\(home)/\(kept.dropFirst(2))" : kept
            return abs.hasPrefix(keptAbs + "/")
        }
        if !kept {
            keptRoots.append(path)
            deduped.append((path, sz))
        }
    }
    deduped.sort { $0.size > $1.size }
    printSizeTable("NAME", deduped, unitLabel: "devenvs")
}

func cmdDevenvUninstall(_ args: [String]) {
    guard let arg = positionalArgs(args).first else {
        reportError("Usage: cleaner devenv-uninstall <path>\nRun devenv-list to see available paths.")
    }
    let expanded = NSString(string: arg).expandingTildeInPath
    let validPaths = Set(scanDevTools().flatMap { $0.existingPaths })
    guard validPaths.contains(expanded) else {
        reportError("Error: '\(arg)' is not a recognized devenv path. Run devenv-list to see options.")
    }
    let url = URL(fileURLWithPath: expanded)
    let rows = [SelectableRow(label: tildeCollapse(expanded), url: url, size: totalSizeOnDisk(for: url))]
    selectAndTrash(rows: rows)
}

// ═══════════════════════════════════════════════════════════════════════════
// PART 7 — MODULE: orphan (cross-module: residuals not claimed by any installed app)
// ═══════════════════════════════════════════════════════════════════════════

// MARK: - orphan / local helpers

private let uuidContainerRegex: NSRegularExpression = {
    try! NSRegularExpression(
        pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$",
        options: .caseInsensitive
    )
}()

private let uuidNoDashRegex: NSRegularExpression = {
    try! NSRegularExpression(pattern: "^[0-9a-fA-F]{32}$", options: [])
}()

extension URL {
    func containerNameByUUID() -> String {
        let uuid = self.lastPathComponent
        let range = NSRange(location: 0, length: uuid.utf16.count)
        guard uuidContainerRegex.firstMatch(in: uuid, options: [], range: range) != nil else { return "" }
        let containersPath = URL(fileURLWithPath: "\(home)/Library/Containers")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: containersPath, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return "" }
        for d in dirs where d.lastPathComponent == uuid {
            let plist = d.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            if let dict = NSDictionary(contentsOf: plist),
               let bid = dict["MCMMetadataIdentifier"] as? String {
                return bid
            }
        }
        return ""
    }
}

class ReversePathFinder {
    private let apps: [AppInfo]
    private struct Cached {
        let bid: String
        let name: String
        let entitlements: [String]
    }
    private let cached: [Cached]

    init(apps: [AppInfo]) {
        self.apps = apps
        self.cached = apps.map { app in
            Cached(
                bid: app.bundleIdentifier.normalized(),
                name: app.appName.normalized(),
                entitlements: app.entitlements?.compactMap {
                    let f = $0.normalized()
                    return f.isEmpty ? nil : f
                } ?? []
            )
        }
    }

    private func isUUIDFormatted(_ s: String) -> Bool {
        let range = NSRange(location: 0, length: s.utf16.count)
        return uuidNoDashRegex.firstMatch(in: s, options: [], range: range) != nil
    }

    private func isRelatedToInstalled(at url: URL) -> Bool {
        let pathFormatted = url.path.normalized()
        for c in cached {
            if !c.bid.isEmpty && c.bid.count >= 5 && pathFormatted.contains(c.bid) { return true }
            if !c.name.isEmpty && c.name.count >= 5 && pathFormatted.contains(c.name) { return true }
            for e in c.entitlements where e.count >= 5 && pathFormatted.contains(e) { return true }
            if url.path.contains("/Containers/") {
                let containerName = url.containerNameByUUID().normalized()
                if !c.bid.isEmpty && c.bid.count >= 5 && containerName.contains(c.bid) { return true }
            }
        }
        return false
    }

    private func isExcludedByConditions(_ normalizedItemPath: String) -> Bool {
        for cond in conditions {
            let hasInstalled = cached.contains { $0.bid == cond.bundleId || $0.bid.contains(cond.bundleId) }
            guard hasInstalled else { continue }
            if cond.include.contains(where: { normalizedItemPath.contains($0) }) { return true }
            if cond.includeForce.contains(where: { normalizedItemPath.contains($0.path.normalized()) }) { return true }
        }
        return false
    }

    func find() -> [URL] {
        var out: [URL] = []
        for location in reverseLocations where FileManager.default.fileExists(atPath: location) {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: location) else { continue }
            for name in contents {
                let url = URL(fileURLWithPath: location).appendingPathComponent(name)
                let normalizedPath = url.standardizedFileURL.path.normalized()
                if normalizedPath.contains("dsstore") || normalizedPath.contains("daemonnameoridentifierhere") { continue }
                let normalizedName = name.normalized()
                if isUUIDFormatted(normalizedName) { continue }
                if skipReverse.contains(where: { normalizedName.contains($0) }) { continue }
                if !isSupportedFileType(at: url.path) { continue }
                if isRelatedToInstalled(at: url) { continue }
                if isExcludedByConditions(normalizedPath) { continue }
                out.append(url)
            }
        }
        return out
    }
}

func cmdOrphan(_ args: [String]) {
    let apps = enumerateInstalledApps()
    let paths = ReversePathFinder(apps: apps).find()
    if paths.isEmpty { print("No orphans found."); return }
    let rows = paths.map { SelectableRow(label: tildeCollapse($0.path), url: $0, size: totalSizeOnDisk(for: $0)) }
    selectAndTrash(rows: rows)
}

// ═══════════════════════════════════════════════════════════════════════════
// PART 8 — CLI dispatch
// ═══════════════════════════════════════════════════════════════════════════

struct Command {
    let name: String
    let usage: String
    let summary: String
    let run: ([String]) -> Void
}

let allCommands: [Command] = [
    Command(name: "app-list",          usage: "app-list",
            summary: "list third-party apps",
            run: cmdAppList),
    Command(name: "app-uninstall",     usage: "app-uninstall <name>",
            summary: "trash an .app",
            run: cmdAppUninstall),
    Command(name: "pkg-list",          usage: "pkg-list",
            summary: "list third-party .pkg packages",
            run: cmdPkgList),
    Command(name: "pkg-uninstall",     usage: "pkg-uninstall <pkg-id>",
            summary: "trash a .pkg",
            run: cmdPkgUninstall),
    Command(name: "plugin-list",       usage: "plugin-list",
            summary: "list installed plugins",
            run: cmdPluginList),
    Command(name: "plugin-uninstall",  usage: "plugin-uninstall <filename>",
            summary: "trash a plugin",
            run: cmdPluginUninstall),
    Command(name: "devenv-list",       usage: "devenv-list",
            summary: "list dev environments",
            run: cmdDevenvList),
    Command(name: "devenv-uninstall",  usage: "devenv-uninstall <path>",
            summary: "trash a dev environment",
            run: cmdDevenvUninstall),
    Command(name: "orphan",            usage: "orphan",
            summary: "trash unclaimed Library residuals",
            run: cmdOrphan)
]

let commandsByName: [String: Command] = Dictionary(uniqueKeysWithValues: allCommands.map { ($0.name, $0) })

func usage() -> Never {
    print("cleaner — macOS cleanup CLI")
    print("")
    print("USAGE:")
    let maxName = allCommands.map { $0.name.count }.max() ?? 18
    for cmd in allCommands {
        print("  " + padCol(cmd.name, maxName + 2) + cmd.summary)
    }
    print("")
    print("DETAILS:")
    for cmd in allCommands {
        print("  cleaner " + cmd.usage)
    }
    print("")
    print("Delete commands show an interactive checklist — ↑↓ navigate, ←/→ toggle, enter to delete, q to cancel.")
    exit(64)
}

let rawArgs = CommandLine.arguments
guard rawArgs.count >= 2 else { usage() }
let cmdName = rawArgs[1]
let cmdArgs = Array(rawArgs.dropFirst(2))

if ["-h", "--help", "help"].contains(cmdName) { usage() }
guard let cmd = commandsByName[cmdName] else {
    FileHandle.standardError.write(Data("Unknown command: \(cmdName)\n".utf8))
    usage()
}
cmd.run(cmdArgs)
