import Darwin
import VigilCore

// One binary, three roles: the menu-bar app, the watchdog agent, and the CLI.
let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "app":
    AppMain.run()
case "watchdog":
    WatchdogMain.run()
case nil where isatty(STDIN_FILENO) == 0 && isatty(STDOUT_FILENO) == 0:
    AppMain.run() // opened from Finder or LaunchServices
case let first? where first.hasPrefix("-psn_"):
    AppMain.run()
default:
    exit(CLI.main(arguments))
}
