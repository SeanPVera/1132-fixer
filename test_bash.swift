import Foundation

func shellSingleQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: #"'\\''"#) + "'"
}

let path = "\\\"$(touch /tmp/pwned)\\\""
let safePath = shellSingleQuote(path)

let script = """
        echo "Launch mode: sandboxRequiredMissingBinary"
        echo "Error: Zoom must be launched in sandbox mode, but the Zoom binary was not found at \(safePath). Install Zoom from https://zoom.us/download, or pick the correct Zoom location in 1132 Fixer, and try again."
"""

print(script)
