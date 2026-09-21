import AppKit
import Foundation

// `--probe` runs the pipeline once and prints what the menu bar would show, so the
// integration can be checked (and scripted) without installing a status item.
if CommandLine.arguments.contains("--probe") {
    exit(MainActor.assumeIsolated { Probe.run(arguments: CommandLine.arguments) })
}

/// Menu bar accessory app: no Dock icon, no windows, lives in the status bar.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
