import Foundation

func shellSingleQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: #"'\\''"#) + "'"
}

let zoomBinaryPath = "\\$(touch /tmp/pwned48)"

let script = """
echo "Launch mode: sandboxRequiredMissingBinary"
echo "Error: Zoom must be launched in sandbox mode, but the Zoom binary was not found at \(zoomBinaryPath). Install Zoom from https://zoom.us/download, or pick the correct Zoom location in 1132 Fixer, and try again."
"""

let encodedCommand = Data(script.utf8).base64EncodedString()
let runScript = "do shell script \\"/bin/bash -c \\\\\\"$(/bin/echo '\(encodedCommand)' | /usr/bin/base64 --decode)\\\\\\"\\""
print(runScript)
