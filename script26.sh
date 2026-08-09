/bin/bash -c '
set -u

zoom_binary='`touch /tmp/pwned26`'

echo "Error: Zoom must be launched in sandbox mode, but the Zoom binary was not found at \"$zoom_binary\". Install Zoom from https://zoom.us/download, or pick the correct Zoom location in 1132 Fixer, and try again."
'
