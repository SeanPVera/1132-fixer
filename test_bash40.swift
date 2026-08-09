import Foundation

func shellSingleQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: #"'\\''"#) + "'"
}

let zoomBinaryPath = "\\\" \\\\$(touch /tmp/pwned40) \\\""

let script = """
echo "Launch mode: sandboxRequiredMissingBinary"
echo "Error: Zoom must be launched in sandbox mode, but the Zoom binary was not found at \(zoomBinaryPath). Install Zoom from https://zoom.us/download, or pick the correct Zoom location in 1132 Fixer, and try again."
"""

print(script)
