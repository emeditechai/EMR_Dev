-- Query active reference ranges
SELECT 
    r.RefRange_ID,
    r.Test_ID,
    t.Test_Name,
    r.Is_Common_For_All,
    r.Age_From,
    r.Age_To,
    r.Age_Unit,
    r.Gender,
    r.Low_Value,
    r.High_Value,
    r.IsDeleted
FROM dbo.LabReferenceRangeMaster r
INNER JOIN dbo.LabInvestigationMaster t ON r.Test_ID = t.Test_ID
WHERE r.IsDeleted = 0
ORDER BY t.Test_Name, r.Gender, r.Age_From;
