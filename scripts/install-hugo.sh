#!/bin/bash
set -e

# Check if hugo is already available
if command -v hugo &> /dev/null; then
    echo "Hugo is already installed"
    hugo version
    exit 0
fi

# Install Hugo Extended to local bin directory
HUGO_VERSION="0.154.2"
echo "Installing Hugo Extended ${HUGO_VERSION}..."

# Create local bin directory if it doesn't exist
mkdir -p ~/.local/bin

# Download and install Hugo
cd /tmp
wget -q "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_Linux-64bit.tar.gz"
tar -xzf "hugo_extended_${HUGO_VERSION}_Linux-64bit.tar.gz"
mv hugo ~/.local/bin/
rm -f "hugo_extended_${HUGO_VERSION}_Linux-64bit.tar.gz"

# Add to PATH for this session
export PATH="$HOME/.local/bin:$PATH"

echo "Hugo installed successfully"
~/.local/bin/hugo version

