#!/bin/bash
BASE="/Users/purojitbhar/My work/EMR_Dev"

# Kill anything holding the ports
lsof -ti:5124 | xargs kill -9 2>/dev/null
lsof -ti:5125 | xargs kill -9 2>/dev/null
pkill -9 -f "dotnet" 2>/dev/null
sleep 3

# Start EMR.Api in a new Terminal window
osascript -e "tell application \"Terminal\"
  activate
  do script \"cd '/Users/purojitbhar/My work/EMR_Dev/EMR.Api' && dotnet build && dotnet run\"
end tell"

sleep 10

# Start EMR.Web in another Terminal window
osascript -e "tell application \"Terminal\"
  activate
  do script \"cd '/Users/purojitbhar/My work/EMR_Dev/EMR.Web' && dotnet build && dotnet run\"
end tell"

sleep 15

# Open Chrome to both apps
open -a "Google Chrome" "https://localhost:5125/swagger"
sleep 2
open -a "Google Chrome" "https://localhost:5124"
