#!/bin/sh
# Installs the data dictionary post-commit hook for this repository (all worktrees share it).
# Re-running is safe. An existing post-commit hook is kept and still runs first.
set -e
HOOKS="$(git rev-parse --git-common-dir)/hooks"
SRC="$(git rev-parse --show-toplevel)/Tools/datadictionary/hooks/post-commit"
mkdir -p "$HOOKS"
TARGET="$HOOKS/post-commit"
if [ -f "$TARGET" ] && ! grep -q "Data dictionary auto-refresh" "$TARGET"; then
    mv "$TARGET" "$HOOKS/post-commit.local"
    echo "Existing post-commit hook kept as post-commit.local"
fi
{
    echo '#!/bin/sh'
    echo '# Data dictionary auto-refresh (installed by Tools/datadictionary/install_hooks.sh)'
    echo '[ -x "$(git rev-parse --git-common-dir)/hooks/post-commit.local" ] && "$(git rev-parse --git-common-dir)/hooks/post-commit.local"'
    echo 'H="$(git rev-parse --show-toplevel)/Tools/datadictionary/hooks/post-commit"'
    echo '[ -f "$H" ] && sh "$H"'
    echo 'exit 0'
} > "$TARGET"
chmod +x "$TARGET"
echo "Installed: $TARGET"
python3 -c "import pymssql, docx, PIL" 2>/dev/null || echo "Install the Python packages: pip3 install -r Tools/datadictionary/requirements.txt"
