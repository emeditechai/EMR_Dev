#!/bin/bash
cd "/Users/purojitbhar/My work/EMR_Dev"
echo "======================================"
echo " Running: 2011_remove_branchid_from_lab_modules.sql"
echo "======================================"
dotnet script apply_sql.csx
echo ""
echo "======================================"
echo " Done. Press any key to close."
echo "======================================"
read -n 1
