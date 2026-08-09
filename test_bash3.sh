bash -c '
echo "Launch mode: sandboxRequiredMissingBinary"
echo "Error: Zoom must be launched in sandbox mode, but the Zoom binary was not found at $(echo pwned > /tmp/pwned). Install Zoom from https://zoom.us/download, or pick the correct Zoom location in 1132 Fixer, and try again."
'
cat /tmp/pwned
