import QuickZipCLI
import Foundation

// The `quickzip` command shipped inside the application, in
// QuickZip.app/Contents/Helpers. The same code as `swift run quickzip`.
exit(await QuickZipCLI.run(Array(CommandLine.arguments.dropFirst())))
