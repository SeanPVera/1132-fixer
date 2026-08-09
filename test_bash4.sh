bash -c '
echo "Launch mode: sandboxRequiredMissingBinary"
echo "Error: Zoom must be launched in sandbox mode, but the Zoom binary was not found at "'\''/path/$(echo pwned > /tmp/pwned3)'\''". Install Zoom from https://zoom.us/download, or pick the correct Zoom location in 1132 Fixer, and try again."
'
cat /tmp/pwned3 2>/dev/null || echo "not created"
