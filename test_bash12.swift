import Foundation

func shellSingleQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: #"'\\''"#) + "'"
}

let zoomBinaryPath = "$(touch /tmp/pwned12)"
let zoomBinaryExists = true

let encodedProfile = Data("profile".utf8).base64EncodedString()
let script = """
/bin/bash -c '
set -u

zoom_binary=\(shellSingleQuote(zoomBinaryPath))
encoded_profile=\(shellSingleQuote(encodedProfile))

echo "$zoom_binary"
'
"""

print(script)
