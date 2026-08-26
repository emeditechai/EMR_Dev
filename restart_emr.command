#!/bin/bash
BASE="/Users/purojitbhar/My work/EMR_Dev"

echo "=========================================="
echo "  Stopping any running EMR instances..."
echo "=========================================="
pkill -f "dotnet.*EMR" 2>/dev/null
pkill -f "dotnet.*emr" 2>/dev/null
sleep 3

# Also kill by port
lsof -ti:5124 | xargs kill -9 2>/dev/null
lsof -ti:5125 | xargs kill -9 2>/dev/null
sleep 2
echo "All previous instances stopped."

echo ""
echo "=========================================="
echo "  Starting EMR.Api on port 5125..."
echo "=========================================="
osascript -e "
tell application \"Terminal\"
    activate
    do script \"echo '=== EMR.Api ===' && cd '$BASE/EMR.Api' && dotnet run\"
    delay 3
    do script \"echo '=== EMR.Web ===' && cd '$BASE/EMR.Web' && dotnet run\"
end tell
"
echo "Both apps launching in new Terminal windows..."
echo "Wait for 'Now listening on https://localhost:51xx' in both."
