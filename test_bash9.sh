zoomBinaryPath="\" \$(touch /tmp/pwned9) \""
cat << SCRIPT > script.sh
echo "Launch mode: sandboxRequiredMissingBinary"
echo 'Error: Zoom must be launched in sandbox mode, but the Zoom binary was not found at '"$zoomBinaryPath"'. Install Zoom from https://zoom.us/download, or pick the correct Zoom location in 1132 Fixer, and try again.'
SCRIPT
bash -c "$(cat script.sh)"
