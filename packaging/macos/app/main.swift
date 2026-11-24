import Cocoa

// SuperSurfer.app is two programs in one executable.
//
// Started by Launch Services (a link click, login, `open -a SuperSurfer`) it
// is the resident menu bar app: it stays loaded and answers URL events from
// the routing engine it keeps warm.
//
// Started from a shell it is the ordinary `supersurfer` command line
// (`register`, `doctor`, `test <url>`, ...). The Rust core handles the whole
// invocation and the process exits without creating any UI.

let launchArguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }

if launchArguments == ["--self-test"] {
    exit(SelfTest.run())
}

// Launch Services starts apps as children of launchd. Anything else is a
// person or a script at a shell, where SuperSurfer has always been a CLI.
let startedByLaunchServices = getppid() == 1
let residentRequested = launchArguments == ["--resident"]

if !residentRequested && (!launchArguments.isEmpty || !startedByLaunchServices) {
    exit(runCommandLine(launchArguments))
}

if anotherInstanceIsRunning() {
    exit(0)
}

AppDelegate.traceToStderr = residentRequested

let sharedApplication = NSApplication.shared
let appDelegate = AppDelegate()
sharedApplication.delegate = appDelegate
sharedApplication.setActivationPolicy(.accessory)
sharedApplication.run()
