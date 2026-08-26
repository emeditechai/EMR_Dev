#!/bin/bash
echo "=== Killing processes on ports 5124 and 5125 ==="
lsof -ti:5124 | xargs kill -9 2>/dev/null && echo "Killed port 5124" || echo "Port 5124 was free"
lsof -ti:5125 | xargs kill -9 2>/dev/null && echo "Killed port 5125" || echo "Port 5125 was free"
pkill -9 -f "dotnet" 2>/dev/null && echo "Killed all dotnet processes" || echo "No dotnet processes"
sleep 3

BASE="/Users/purojitbhar/My work/EMR_Dev"

echo ""
echo "=== Starting EMR.Api ==="
osascript -e "tell application \"Terminal\" to do script \"cd '$BASE/EMR.Api' && dotnet run\""
sleep 5

echo "=== Starting EMR.Web ==="
osascript -e "tell application \"Terminal\" to do script \"cd '$BASE/EMR.Web' && dotnet run\""

echo ""
echo "Both apps starting... watch the new Terminal windows."
echo "Open Chrome to https://localhost:5124 when ready."
