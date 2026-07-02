#!/usr/bin/env swift
import Foundation
import Darwin

struct CommandError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func log(_ message: String = "") {
    print(message)
    fflush(stdout)
}

struct Options {
    var command = ""
    var device: String?
    var bundle: String?
    var sdk = "27.0"
    var xcode = "/Applications/Xcode-beta.app"
    var workdir: String?
    var launch = true
}

@discardableResult
func run(_ args: [String], env extraEnv: [String: String] = [:], quiet: Bool = false, allowFailure: Bool = false) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: args[0])
    process.arguments = Array(args.dropFirst())
    var env = ProcessInfo.processInfo.environment
    for (key, value) in extraEnv { env[key] = value }
    process.environment = env

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    if !quiet, !output.isEmpty {
        print(output, terminator: output.hasSuffix("\n") ? "" : "\n")
    }
    if process.terminationStatus != 0, !allowFailure {
        throw CommandError(message: "Command failed (\(process.terminationStatus)): \(args.joined(separator: " "))\n\(output)")
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

func usage(_ code: Int32 = 2) -> Never {
    print("""
    Xcode Resize Mode Workarounds
    Make iOS 26.x SDK simulator apps usable with Xcode 27 Device Hub Resize Mode.

    Usage:
      xcode-resize-mode-workarounds.swift patch --device <sim-udid-or-name> --bundle <bundle-id> [--sdk 27.0] [--xcode /Applications/Xcode-beta.app] [--workdir <dir>] [--no-launch]
      xcode-resize-mode-workarounds.swift restore --workdir <dir> [--no-launch]

    Examples:
      ./xcode-resize-mode-workarounds.swift patch -d 9F559260-7656-40E0-A638-0F54724390B7 -b com.example.MyApp
      ./xcode-resize-mode-workarounds.swift restore --workdir /tmp/xcode-resize-mode-workarounds-20260702-145500
    """)
    exit(code)
}

func parseArgs() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { usage() }
    if command == "-h" || command == "--help" { usage(0) }
    options.command = command
    args.removeFirst()

    var index = 0
    while index < args.count {
        let arg = args[index]
        func value() -> String {
            guard index + 1 < args.count else { usage() }
            index += 1
            return args[index]
        }
        switch arg {
        case "-d", "--device": options.device = value()
        case "-b", "--bundle": options.bundle = value()
        case "--sdk": options.sdk = value()
        case "--xcode": options.xcode = value()
        case "--workdir": options.workdir = value()
        case "--no-launch": options.launch = false
        case "-h", "--help": usage(0)
        default:
            print("Unknown argument: \(arg)")
            usage()
        }
        index += 1
    }
    return options
}

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
}

func devDir(_ xcode: String) -> String { "\(xcode)/Contents/Developer" }
func deviceCtl(_ xcode: String) -> String { "\(xcode)/Contents/Developer/usr/bin/devicectl" }
func simctlEnv(_ xcode: String) -> [String: String] { ["DEVELOPER_DIR": devDir(xcode)] }

func simctl(_ xcode: String, _ arguments: [String], quiet: Bool = false) throws -> String {
    try run(["/usr/bin/xcrun", "simctl"] + arguments, env: simctlEnv(xcode), quiet: quiet)
}

func isMachO(_ path: String) -> Bool {
    ((try? run(["/usr/bin/file", "-b", path], quiet: true, allowFailure: true)) ?? "").contains("Mach-O")
}

func buildVersion(_ path: String) throws -> (platform: String?, minOS: String?, sdk: String?) {
    let output = try run(["/usr/bin/vtool", "-show-build", path], quiet: true)
    var platform: String?
    var minOS: String?
    var sdk: String?
    for line in output.split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2 else { continue }
        if parts[0] == "platform" { platform = parts[1] }
        if parts[0] == "minos" { minOS = parts[1] }
        if parts[0] == "sdk" { sdk = parts[1] }
    }
    return (platform, minOS, sdk)
}

func infoPlistValue(_ key: String, in bundle: String) -> String? {
    let plist = (bundle as NSString).appendingPathComponent("Info.plist")
    guard FileManager.default.fileExists(atPath: plist) else { return nil }
    return try? run(["/usr/libexec/PlistBuddy", "-c", "Print :\(key)", plist], quiet: true, allowFailure: true)
}

func addIfFile(_ path: String, to set: inout Set<String>) {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
        set.insert(path)
    }
}

func candidateMachOFiles(under app: String) -> [String] {
    var candidates = Set<String>()

    if let exe = infoPlistValue("CFBundleExecutable", in: app), !exe.isEmpty {
        addIfFile((app as NSString).appendingPathComponent(exe), to: &candidates)
    }

    guard let enumerator = FileManager.default.enumerator(atPath: app) else { return [] }
    for case let relative as String in enumerator {
        if relative.contains("/_CodeSignature/") { continue }
        let path = (app as NSString).appendingPathComponent(relative)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }

        if isDir.boolValue {
            if path.hasSuffix(".framework") {
                let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                addIfFile((path as NSString).appendingPathComponent(name), to: &candidates)
            } else if path.hasSuffix(".appex") || path.hasSuffix(".app") {
                if let exe = infoPlistValue("CFBundleExecutable", in: path), !exe.isEmpty {
                    addIfFile((path as NSString).appendingPathComponent(exe), to: &candidates)
                }
            }
            continue
        }

        if path.hasSuffix(".dylib") {
            candidates.insert(path)
            continue
        }

        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        if let permissions = attrs[.posixPermissions] as? NSNumber, permissions.intValue & 0o111 != 0 {
            candidates.insert(path)
        }
    }

    return candidates.sorted().filter(isMachO)
}

func bundleDirectories(under root: String) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
    let suffixes = [".framework", ".appex", ".bundle", ".app"]
    return enumerator.compactMap { item -> String? in
        guard let relative = item as? String else { return nil }
        let path = (root as NSString).appendingPathComponent(relative)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return suffixes.contains(where: path.hasSuffix) ? path : nil
    }.sorted { $0.count > $1.count }
}


func writeJSON(_ object: Any, to path: String) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: path))
}

func readStringJSON(_ path: String) throws -> [String: String] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
        throw CommandError(message: "Invalid JSON dictionary: \(path)")
    }
    return object
}

func relativePath(_ path: String, under root: String) -> String {
    path.replacingOccurrences(of: root + "/", with: "")
}

func copyBundle(from source: String, to destination: String, label: String) throws {
    log("\(label)...")
    if FileManager.default.fileExists(atPath: destination) {
        try FileManager.default.removeItem(atPath: destination)
    }
    do {
        try run(["/bin/cp", "-cR", source, destination], quiet: true)
    } catch {
        log("APFS clone copy failed; falling back to ditto")
        try run(["/usr/bin/ditto", source, destination], quiet: true)
    }
}

func patchMachOFiles(app: String, workdir: String, targetSDK: String) throws -> [[String]] {
    let files = candidateMachOFiles(under: app)
    log("found Mach-O candidates: \(files.count)")

    var changed: [[String]] = []
    var failed: [[String]] = []
    for (index, file) in files.enumerated() {
        do {
            let version = try buildVersion(file)
            guard version.platform == "IOSSIMULATOR", let minOS = version.minOS else { continue }
            guard version.sdk != targetSDK else { continue }

            let relative = relativePath(file, under: app)
            log("patching \(index + 1)/\(files.count): \(relative) sdk \(version.sdk ?? "unknown") -> \(targetSDK)")

            let tmp = (workdir as NSString).appendingPathComponent("tmp-patched-mach-o")
            if FileManager.default.fileExists(atPath: tmp) {
                try FileManager.default.removeItem(atPath: tmp)
            }
            try run(["/usr/bin/vtool", "-set-build-version", "iossim", minOS, targetSDK, "-replace", "-output", tmp, file], quiet: true)
            let attrs = try FileManager.default.attributesOfItem(atPath: file)
            let permissions = attrs[.posixPermissions]
            try FileManager.default.removeItem(atPath: file)
            try FileManager.default.copyItem(atPath: tmp, toPath: file)
            try FileManager.default.removeItem(atPath: tmp)
            if let permissions {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file)
            }
            changed.append([relative, minOS, version.sdk ?? "", targetSDK])
        } catch {
            failed.append([relativePath(file, under: app), String(describing: error)])
        }
    }
    try writeJSON(changed, to: (workdir as NSString).appendingPathComponent("changed.json"))
    try writeJSON(failed, to: (workdir as NSString).appendingPathComponent("failed.json"))
    if !failed.isEmpty {
        throw CommandError(message: "Failed to patch \(failed.count) Mach-O files. See \(workdir)/failed.json")
    }
    return changed
}

func signPatchedApp(_ app: String) throws {
    let bundles = bundleDirectories(under: app)
    log("signing nested bundles: \(bundles.count)")
    for bundle in bundles {
        _ = try run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", bundle], quiet: true, allowFailure: true)
    }

    let topLevelExecutables = candidateMachOFiles(under: app).filter { ($0 as NSString).deletingLastPathComponent == app }
    for file in topLevelExecutables {
        _ = try run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", file], quiet: true, allowFailure: true)
    }

    log("signing app bundle...")
    try run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", app], quiet: true)
    log("verifying code signature...")
    try run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
}

func patch(_ options: Options) throws {
    guard let device = options.device, let bundle = options.bundle else { usage() }
    let xcode = options.xcode
    let workdir = options.workdir ?? "/tmp/xcode-resize-mode-workarounds-\(timestamp())"
    try FileManager.default.createDirectory(atPath: workdir, withIntermediateDirectories: true)

    let sourceApp = try simctl(xcode, ["get_app_container", device, bundle, "app"], quiet: true)
    let original = (workdir as NSString).appendingPathComponent("original.app")
    let patched = (workdir as NSString).appendingPathComponent("patched.app")

    if FileManager.default.fileExists(atPath: original) || FileManager.default.fileExists(atPath: patched) {
        throw CommandError(message: "Work directory already contains original.app or patched.app: \(workdir)")
    }

    log("source app: \(sourceApp)")
    log("work dir:   \(workdir)")
    try copyBundle(from: sourceApp, to: original, label: "saving original app")
    try copyBundle(from: sourceApp, to: patched, label: "creating patched copy")

    let changed = try patchMachOFiles(app: patched, workdir: workdir, targetSDK: options.sdk)
    log("patched Mach-O files: \(changed.count)")
    try signPatchedApp(patched)

    log("installing patched app...")
    try run([deviceCtl(xcode), "device", "install", "app", "-d", device, patched, "--json-output", "\(workdir)/install-patched.json"])
    if options.launch {
        log("launching patched app...")
        try run([deviceCtl(xcode), "device", "process", "launch", "-d", device, "--terminate-existing", "--activate", bundle, "--json-output", "\(workdir)/launch-patched.json"])
    }

    try writeJSON([
        "xcode": xcode,
        "device": device,
        "bundle": bundle,
        "original": original
    ], to: (workdir as NSString).appendingPathComponent("restore-info.json"))

    let launchLine = options.launch ? "DEVELOPER_DIR=\"\(devDir(xcode))\" xcrun simctl launch --terminate-running-process \"\(device)\" \"\(bundle)\"\n" : ""
    let restoreScript = """
    #!/usr/bin/env bash
    set -euo pipefail
    "\(deviceCtl(xcode))" device install app -d "\(device)" "\(original)"
    \(launchLine)
    """
    let restorePath = (workdir as NSString).appendingPathComponent("restore-original.sh")
    try restoreScript.write(toFile: restorePath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: restorePath)

    log("\npatched install complete")
    log("try Device Hub Enter Resize Mode now")
    log("restore with: ./xcode-resize-mode-workarounds.swift restore --workdir \(workdir)")
    log("restore script: \(restorePath)")
}

func restore(_ options: Options) throws {
    guard let workdir = options.workdir else { usage() }
    let infoPath = (workdir as NSString).appendingPathComponent("restore-info.json")
    if FileManager.default.fileExists(atPath: infoPath) {
        let info = try readStringJSON(infoPath)
        guard let xcode = info["xcode"], let device = info["device"], let bundle = info["bundle"], let original = info["original"] else {
            throw CommandError(message: "Missing required fields in \(infoPath)")
        }
        log("installing original app...")
        try run([deviceCtl(xcode), "device", "install", "app", "-d", device, original])
        if options.launch {
            log("launching original app...")
            try run([deviceCtl(xcode), "device", "process", "launch", "-d", device, "--terminate-existing", "--activate", bundle])
        }
        return
    }

    let restorePath = (workdir as NSString).appendingPathComponent("restore-original.sh")
    guard FileManager.default.fileExists(atPath: restorePath) else {
        throw CommandError(message: "Missing restore info or restore script in: \(workdir)")
    }
    try run([restorePath])
}

let options = parseArgs()
do {
    switch options.command {
    case "patch": try patch(options)
    case "restore": try restore(options)
    default: usage()
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
