import Foundation

func shellSingleQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: #"'\\''"#) + "'"
}

let zoomBinaryPath = "$(touch /tmp/pwned17)"

// Swift's string interpolation combined with bash command line parsing:
let script = """
/bin/bash -c "zoom_binary=\(shellSingleQuote(zoomBinaryPath))"
"""
print(script)
