-- 2430  IPD bed charges by the branch's Daily Check-In / Check-Out Time (Hospital Settings): branches that have a
--       check-out time and still use the default calendar-day cycle move to the CHECKINOUT cycle. Needs 2422 (fn_Ipd_BedDays
--       with the CHECKINOUT mode). Safe to re-run.
SET NOCOUNT ON;
UPDATE dbo.HospitalSettings SET IpdBedChargeMode = 'CHECKINOUT' WHERE CheckOutTime IS NOT NULL AND IpdBedChargeMode = 'CALENDAR';
PRINT CONCAT('2430 branches moved to check-in / check-out bed days: ', @@ROWCOUNT);
GO
