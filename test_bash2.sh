safe_path="'\$(touch /tmp/pwned)'"
# Swift output:
echo "Launch mode: sandboxRequiredMissingBinary"
echo "Error: Zoom must be launched in sandbox mode, but the Zoom binary was not found at "$safe_path". Install Zoom from https://zoom.us/download, or pick the correct Zoom location in 1132 Fixer, and try again."
