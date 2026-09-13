import Foundation
import Paw

// `paw`: start and steer terminals from inside a terminal of the app (see `Paw`).
let environment = ProcessInfo.processInfo.environment
// The shell's own idea of where it is (a folder reached through a link keeps its name), when it agrees.
let folder: String = {
    let real = FileManager.default.currentDirectoryPath
    guard let logical = environment["PWD"], logical.hasPrefix("/"),
          URL(fileURLWithPath: logical).resolvingSymlinksInPath().path == URL(fileURLWithPath: real).resolvingSymlinksInPath().path else { return real }
    return logical
}()
exit(Paw(environment: environment, currentFolder: folder).run(Array(CommandLine.arguments.dropFirst())))
