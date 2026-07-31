import Darwin
import Foundation
import HerdrBlockSleepCore

let config = Config(environment: ProcessInfo.processInfo.environment)
let command = CommandLine.arguments.dropFirst().first ?? "start"

switch command {
case "start":
    exit(CLI(config: config).start())
case "stop":
    exit(CLI(config: config).stop())
case "status":
    exit(CLI(config: config).status())
case "daemon":
    signal(SIGINT) { _ in Termination.requested = true }
    signal(SIGTERM) { _ in Termination.requested = true }
    exit(Monitor(config: config).run())
case "help", "--help", "-h":
    usage()
    exit(0)
default:
    usage()
    exit(2)
}
