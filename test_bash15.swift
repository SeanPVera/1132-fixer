import Foundation

func shellSingleQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: #"'\\''"#) + "'"
}

let zoomBinaryPath = "$(touch /tmp/pwned15)"

let script = """
/bin/bash -c '
set -u

zoom_binary=\(shellSingleQuote(zoomBinaryPath))
echo "done"
'
"""

print(script)
