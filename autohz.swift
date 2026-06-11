// studio-display-autohz — keep the SwitchResX-overclocked Studio Display at max refresh.
//
// The 86.5 Hz mode is injected into the system mode table by the SwitchResX
// daemon (it survives in CGDisplayCopyAllDisplayModes as a mode whose declared
// refreshRate reads "86.0"; the real wire timing is 1349.41 MHz / 5200x3000 =
// 86.5006 Hz — verify with: ioreg -c AppleCLCD2 | grep DPTimingModeId, the
// active element ID must match the injected timing element).
// This tool never talks to SwitchResX: it just picks the highest-refresh
// 5120x2880 HiDPI mode from the public CG mode list and applies it.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Config

let targetVendor: UInt32 = 0x610   // Apple
let targetModel: UInt32 = 0xae42   // SwitchResX-overridden product ID of the Studio Display
let pixelW = 5120, pixelH = 2880   // full 5K
let pointW = 2560                  // HiDPI ("Retina") desktop size
let minHz = 80.0                   // anything >= this counts as the overclocked mode
// Enforcement runs several times after a hotplug because the SwitchResX daemon
// re-injects its mode table a few seconds after the display attaches; an early
// pass may only see the timings from the on-disk .mtdd override.
let enforceDelays: [Double] = [2, 8, 20]

// MARK: - Logging

let logPath = ("~/Library/Logs/studio-display-autohz.log" as NSString).expandingTildeInPath

func log(_ msg: String) {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "[\(fmt.string(from: Date()))] \(msg)\n"
    print(line, terminator: "")
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        h.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Display / mode lookup

func findTargetDisplay() -> CGDirectDisplayID? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
    for i in 0..<Int(count) {
        let did = ids[i]
        if CGDisplayVendorNumber(did) == targetVendor && CGDisplayModelNumber(did) == targetModel {
            return did
        }
    }
    return nil
}

func allModes(_ did: CGDirectDisplayID) -> [CGDisplayMode] {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    return (CGDisplayCopyAllDisplayModes(did, opts) as? [CGDisplayMode]) ?? []
}

func findBestMode(_ did: CGDirectDisplayID) -> CGDisplayMode? {
    allModes(did)
        .filter {
            $0.pixelWidth == pixelW && $0.pixelHeight == pixelH
                && $0.width == pointW                      // HiDPI variant only
                && $0.refreshRate >= minHz
                && $0.isUsableForDesktopGUI()
        }
        // Highest refresh first; tie-break on lowest mode ID for stability
        // (the VRR/non-VRR twins of one timing share the declared refresh).
        .sorted {
            $0.refreshRate != $1.refreshRate
                ? $0.refreshRate > $1.refreshRate
                : $0.ioDisplayModeID < $1.ioDisplayModeID
        }
        .first
}

func describe(_ m: CGDisplayMode) -> String {
    "\(m.pixelWidth)x\(m.pixelHeight) (\(m.width)x\(m.height) pt) @ \(m.refreshRate)Hz [id \(m.ioDisplayModeID)]"
}

// MARK: - Enforce

@discardableResult
func enforce(reason: String) -> Bool {
    guard let did = findTargetDisplay() else {
        log("enforce(\(reason)): target display not online")
        return false
    }
    guard let target = findBestMode(did) else {
        log("enforce(\(reason)): no >=\(minHz)Hz 5K HiDPI mode in the list (SwitchResX override not loaded yet?)")
        return false
    }
    guard let current = CGDisplayCopyDisplayMode(did) else { return false }
    if current.ioDisplayModeID == target.ioDisplayModeID {
        log("enforce(\(reason)): already at \(describe(current))")
        return true
    }
    log("enforce(\(reason)): switching \(describe(current)) -> \(describe(target))")
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success,
          CGConfigureDisplayWithDisplayMode(config, did, target, nil) == .success else {
        log("enforce(\(reason)): failed to stage configuration")
        if config != nil { CGCancelDisplayConfiguration(config) }
        return false
    }
    let err = CGCompleteDisplayConfiguration(config, .permanently)
    log("enforce(\(reason)): result \(err == .success ? "OK" : "error \(err.rawValue)")")
    return err == .success
}

func scheduleEnforces(reason: String) {
    for delay in enforceDelays {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            enforce(reason: "\(reason)+\(Int(delay))s")
        }
    }
}

// MARK: - Watch mode

func watch() {
    log("watch: started (target vendor 0x\(String(targetVendor, radix: 16)) model 0x\(String(targetModel, radix: 16)))")
    enforce(reason: "launch")
    scheduleEnforces(reason: "launch")

    CGDisplayRegisterReconfigurationCallback({ did, flags, _ in
        guard flags.contains(.addFlag) else { return }
        if CGDisplayVendorNumber(did) == targetVendor && CGDisplayModelNumber(did) == targetModel {
            log("watch: display \(did) attached")
            scheduleEnforces(reason: "hotplug")
        }
    }, nil)

    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { _ in
        log("watch: system woke")
        scheduleEnforces(reason: "wake")
    }

    // Background agents must pump the AppKit run loop to receive NSWorkspace
    // notifications (CFRunLoopRun alone is not enough).
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.run()
}

// MARK: - Status

func status() {
    guard let did = findTargetDisplay() else {
        print("target display (vendor 0x610 model 0xae42) not online")
        return
    }
    print("display \(did) online, main=\(CGDisplayIsMain(did) != 0)")
    if let cur = CGDisplayCopyDisplayMode(did) {
        print("current: \(describe(cur))")
    }
    if let best = findBestMode(did) {
        print("target:  \(describe(best))")
    } else {
        print("target:  no >=\(minHz)Hz 5K HiDPI mode found")
    }
    print("\nall 5120x2880 + >=\(Int(minHz))Hz modes:")
    for m in allModes(did) where m.pixelWidth == pixelW || m.refreshRate >= minHz {
        print("  \(describe(m)) usable=\(m.isUsableForDesktopGUI())")
    }
}

// MARK: - main

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "help" {
case "status":
    status()
case "enforce":
    enforce(reason: "manual")
case "watch":
    watch()
case "set-mode" where args.count > 2:
    // debug helper: switch the target display to an arbitrary mode ID
    guard let did = findTargetDisplay(),
          let wanted = Int32(args[2]),
          let mode = allModes(did).first(where: { $0.ioDisplayModeID == wanted }) else {
        print("display or mode not found"); exit(1)
    }
    var config: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&config)
    CGConfigureDisplayWithDisplayMode(config, did, mode, nil)
    let err = CGCompleteDisplayConfiguration(config, .permanently)
    print("set-mode \(wanted): \(err == .success ? "OK" : "error")")
default:
    print("""
    usage: studio-display-autohz <command>
      status    show current and target mode
      enforce   one-shot: switch to the highest-refresh 5K HiDPI mode
      watch     daemon mode: enforce on launch, hotplug, and wake
    """)
}
