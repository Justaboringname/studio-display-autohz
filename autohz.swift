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

struct ModeSpec {
    let name: String
    let pixelW: Int, pixelH: Int   // wire resolution
    let pointW: Int                // desktop size in points (pointW < pixelW means HiDPI)
    let minHz: Double              // lowest acceptable declared refresh
}

// Office: full 5K HiDPI at the SwitchResX-overclocked ~86.5 Hz.
let productivitySpec = ModeSpec(name: "5K", pixelW: 5120, pixelH: 2880, pointW: 2560, minHz: 80)
// Gaming: 2560x1440 @ 120 Hz, 1x — the only 120 Hz mode whose desktop size
// matches the office profile (2560x1440 points). Non-Retina, but the panel
// upscales 2x integer and the game renders 1440p either way. There is no
// 5120x2880-backed 120 Hz mode in the table (the display engine tops out at
// ~86.5 Hz for 5K, which is the whole point of this tool).
let gamingSpec = ModeSpec(name: "1440p120", pixelW: 2560, pixelH: 1440, pointW: 2560, minHz: 100)

// While any of these apps is running, gamingSpec wins. The League client and
// the game itself are separate processes — covering both means the display
// stays at 4K120 even if the client quits mid-game.
let gamingBundleIDs: Set<String> = [
    "com.riotgames.RiotGames.RiotClient",
    "com.riotgames.leagueoflegends",
]

func gamingActive() -> Bool {
    NSWorkspace.shared.runningApplications.contains {
        if let bid = $0.bundleIdentifier { return gamingBundleIDs.contains(bid) }
        return false
    }
}

func desiredSpec() -> ModeSpec { gamingActive() ? gamingSpec : productivitySpec }
// Enforcement runs several times after a hotplug because the SwitchResX daemon
// re-injects its mode table a few seconds after the display attaches; an early
// pass may only see the timings from the on-disk .mtdd override.
let enforceDelays: [Double] = [2, 8, 20]
// The daemon's injection can also take minutes (observed 2026-06-12: ~2-3 min
// after an attach event, and not at all until the next attach if the daemon
// itself started late). When every fixed-delay pass misses, keep polling until
// the mode shows up instead of leaving the display stuck on a fallback mode.
let pollInterval: Double = 30
let pollMaxTicks = 20   // give up after 10 min; any later event re-arms polling

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

func findBestMode(_ did: CGDirectDisplayID, _ spec: ModeSpec) -> CGDisplayMode? {
    allModes(did)
        .filter {
            $0.pixelWidth == spec.pixelW && $0.pixelHeight == spec.pixelH
                && $0.width == spec.pointW
                && $0.refreshRate >= spec.minHz
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
    let spec = desiredSpec()
    guard let target = findBestMode(did, spec) else {
        log("enforce(\(reason)): no \(spec.name) (>=\(spec.minHz)Hz) mode in the list (SwitchResX daemon not injected yet?)")
        return false
    }
    guard let current = CGDisplayCopyDisplayMode(did) else { return false }
    if current.ioDisplayModeID == target.ioDisplayModeID {
        log("enforce(\(reason)): already at \(spec.name) \(describe(current))")
        return true
    }
    log("enforce(\(reason)): [\(spec.name)] switching \(describe(current)) -> \(describe(target))")
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

var pollTimer: Timer?

func startPolling(reason: String) {
    guard pollTimer == nil else { return }
    log("poll(\(reason)): target mode still missing, retrying every \(Int(pollInterval))s")
    var ticks = 0
    pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { timer in
        ticks += 1
        if enforce(reason: "\(reason)+poll\(ticks)") || ticks >= pollMaxTicks {
            timer.invalidate()
            pollTimer = nil
        }
    }
}

func scheduleEnforces(reason: String) {
    for delay in enforceDelays {
        let isLast = delay == enforceDelays.last
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let ok = enforce(reason: "\(reason)+\(Int(delay))s")
            if isLast && !ok { startPolling(reason: reason) }
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

    // Game-aware switching: 4K120 while the Riot client / LoL runs, 5K when done.
    for (name, event) in [(NSWorkspace.didLaunchApplicationNotification, "app-launch"),
                          (NSWorkspace.didTerminateApplicationNotification, "app-quit")] {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: name, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier, gamingBundleIDs.contains(bid) else { return }
            log("watch: \(event) \(bid)")
            if event == "app-launch" {
                enforce(reason: event)
            } else {
                // The quitting app can linger in runningApplications for a
                // moment after didTerminate fires — re-check after a beat.
                let delays = [1.0, 5.0, 12.0]
                for delay in delays {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        let ok = enforce(reason: "\(event)+\(Int(delay))s")
                        if delay == delays.last && !ok { startPolling(reason: event) }
                    }
                }
            }
        }
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
    let spec = desiredSpec()
    print("display \(did) online, main=\(CGDisplayIsMain(did) != 0)")
    print("gaming apps running: \(gamingActive()) -> desired profile: \(spec.name)")
    if let cur = CGDisplayCopyDisplayMode(did) {
        print("current: \(describe(cur))")
    }
    if let best = findBestMode(did, spec) {
        print("target:  \(describe(best))")
    } else {
        print("target:  no \(spec.name) (>=\(spec.minHz)Hz) mode found")
    }
    print("\nall 5K + 4K + >=80Hz modes:")
    for m in allModes(did) where m.pixelWidth >= 3840 || m.refreshRate >= 80 {
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
