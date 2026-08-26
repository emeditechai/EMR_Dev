#!/bin/bash
# EMR System Launcher — double-click this file in Finder to start both apps

BASE="/Users/purojitbhar/My work/EMR_Dev"

echo "=========================================="
echo "  EMR System Launcher"
echo "=========================================="

# Start EMR.Api in a new Terminal tab
osascript -e "
tell application \"Terminal\"
    activate
    do script \"cd '$BASE/EMR.Api' && echo '>>> Building EMR.Api...' && dotnet build --configuration Release && echo '>>> Starting EMR.Api on https://localhost:5125...' && dotnet run\"
    delay 1
    do script \"cd '$BASE/EMR.Web' && echo '>>> Building EMR.Web...' && dotnet build --configuration Release && echo '>>> Starting EMR.Web on https://localhost:5124...' && dotnet run\"
end tell
"

echo "Both apps launching in Terminal windows..."
echo "Once you see 'Now listening on https://localhost:51xx' in both windows,"
echo "open Chrome to https://localhost:5124"
