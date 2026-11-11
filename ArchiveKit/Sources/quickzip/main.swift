import QuickZipCLI
import Foundation

exit(await QuickZipCLI.run(Array(CommandLine.arguments.dropFirst())))
