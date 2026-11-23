-- ============================================================================================================
-- Migration: 2485_bed_tariff_rmo_charge.sql   (application database)
-- Master > IPD > Bed / Room Tariff: a new daily component "RMO Charge" (Resident Medical Officer), with Room, Bed,
-- Nursing, Attendant and Isolation. Existing tariffs get 0, so bills / estimates do not change until a rate is entered.
--   BedRoomTariffMaster.RmoCharge, BedRoomTariffHistory.RmoCharge   DECIMAL(18,2) NOT NULL DEFAULT 0
--   everything that adds up or lists the components takes it too:
--     fn_Ipd_BedRate       the bed's rate (RmoCharge column)
--     fn_Ipd_BedDays       each bed day: RmoCharge, the day total and the GST threshold
--     fn_Ipd_BillLines     a bed-day line "RMO Charge" (after Nursing, before Attendant)
--     usp_Api_Ipd_Beds, usp_Api_IpdBed_ForTransfer   the daily rate shown on the bed board / transfer
--     usp_Api_IpdAdmission_Save                       the minimum-advance daily rate
--     usp_Api_IpdPreEstimate_Calc                     the pre-admission estimate (its own line, and the GST threshold)
--     usp_Api_BedRoomTariff_GetList                   the tariff list
-- Each change is guarded: an object that does not read as expected is reported and left as it is. Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.BedRoomTariffMaster', 'RmoCharge') IS NULL
    ALTER TABLE dbo.BedRoomTariffMaster ADD RmoCharge DECIMAL(18,2) NOT NULL CONSTRAINT DF_BedRoomTariffMaster_RmoCharge DEFAULT (0);
GO
IF COL_LENGTH('dbo.BedRoomTariffHistory', 'RmoCharge') IS NULL
    ALTER TABLE dbo.BedRoomTariffHistory ADD RmoCharge DECIMAL(18,2) NOT NULL CONSTRAINT DF_BedRoomTariffHistory_RmoCharge DEFAULT (0);
GO

-- patches an object's definition: every @from must be found, else nothing is changed and the object is reported
CREATE OR ALTER PROCEDURE #Patch @name SYSNAME, @pairs NVARCHAR(MAX)
AS
BEGIN
    DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.' + @name));
    IF @def IS NULL BEGIN PRINT '2485: ' + @name + ' not found - skipped.'; RETURN; END
    IF @def LIKE N'%RmoCharge%' BEGIN PRINT '2485: ' + @name + ' already has RmoCharge.'; RETURN; END
    DECLARE @f NVARCHAR(MAX), @t NVARCHAR(MAX);
    DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT JSON_VALUE(value, '$.f'), JSON_VALUE(value, '$.t') FROM OPENJSON(@pairs);
    OPEN pc; FETCH NEXT FROM pc INTO @f, @t;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF CHARINDEX(@f, @def) = 0
        BEGIN
            CLOSE pc; DEALLOCATE pc;
            PRINT '2485: ' + @name + ' has changed (text not found: ' + LEFT(@f, 120) + ') - add RmoCharge by hand.';
            RETURN;
        END
        SET @def = REPLACE(@def, @f, @t);
        FETCH NEXT FROM pc INTO @f, @t;
    END
    CLOSE pc; DEALLOCATE pc;
    SET @def = REPLACE(@def, 'CREATE   FUNCTION', 'CREATE OR ALTER FUNCTION');
    SET @def = REPLACE(@def, 'CREATE FUNCTION', 'CREATE OR ALTER FUNCTION');
    SET @def = REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
    PRINT '2485: ' + @name + ' - RMO Charge added.';
END
GO

EXEC #Patch N'fn_Ipd_BedRate', N'[
 {"f":"CAST(t.NursingCharge AS DECIMAL(18,2)) AS NursingCharge,","t":"CAST(t.NursingCharge AS DECIMAL(18,2)) AS NursingCharge, CAST(t.RmoCharge AS DECIMAL(18,2)) AS RmoCharge,"}]';
GO
EXEC #Patch N'fn_Ipd_BedDays', N'[
 {"f":"ISNULL(rt.NursingCharge, 0) AS NursingCharge,","t":"ISNULL(rt.NursingCharge, 0) AS NursingCharge, ISNULL(rt.RmoCharge, 0) AS RmoCharge,"},
 {"f":"rt.NursingCharge + rt.AttendantCharge","t":"rt.NursingCharge + rt.RmoCharge + rt.AttendantCharge"}]';
GO
EXEC #Patch N'fn_Ipd_BillLines', N'[
 {"f":"(''ATTENDANT'', N''Attendant Charge'', bd.AttendantCharge, 4),","t":"(''RMO'', N''RMO Charge'', bd.RmoCharge, 4), (''ATTENDANT'', N''Attendant Charge'', bd.AttendantCharge, 5),"},
 {"f":"(''ISOLATION'', N''Isolation Charge'', bd.IsolationCharge, 5), (''NOTARIFF'', N'''', CAST(0 AS DECIMAL(18,2)), 6)","t":"(''ISOLATION'', N''Isolation Charge'', bd.IsolationCharge, 6), (''NOTARIFF'', N'''', CAST(0 AS DECIMAL(18,2)), 7)"}]';
GO
EXEC #Patch N'usp_Api_Ipd_Beds', N'[
 {"f":"rt.NursingCharge + rt.AttendantCharge","t":"rt.NursingCharge + rt.RmoCharge + rt.AttendantCharge"}]';
GO
EXEC #Patch N'usp_Api_IpdBed_ForTransfer', N'[
 {"f":"rt.NursingCharge + rt.AttendantCharge","t":"rt.NursingCharge + rt.RmoCharge + rt.AttendantCharge"}]';
GO
EXEC #Patch N'usp_Api_IpdAdmission_Save', N'[
 {"f":"NursingCharge + AttendantCharge + IsolationCharge","t":"NursingCharge + RmoCharge + AttendantCharge + IsolationCharge"}]';
GO
EXEC #Patch N'usp_Api_IpdPreEstimate_Calc', N'[
 {"f":"NursingCharge DECIMAL(18,2),","t":"NursingCharge DECIMAL(18,2), RmoCharge DECIMAL(18,2),"},
 {"f":"t.NursingCharge, t.AttendantCharge,","t":"t.NursingCharge, t.RmoCharge, t.AttendantCharge,"},
 {"f":"t.NursingCharge + t.AttendantCharge <= @thr","t":"t.NursingCharge + t.RmoCharge + t.AttendantCharge <= @thr"},
 {"f":"(3, N''Nursing Charge'', r.NursingCharge), (4, N''Attendant Charge'', r.AttendantCharge)","t":"(3, N''Nursing Charge'', r.NursingCharge), (4, N''RMO Charge'', r.RmoCharge), (5, N''Attendant Charge'', r.AttendantCharge)"}]';
GO
EXEC #Patch N'usp_Api_BedRoomTariff_GetList', N'[
 {"f":"        t.NursingCharge,","t":"        t.NursingCharge,\n        t.RmoCharge,"}]';
GO
DROP PROCEDURE IF EXISTS #Patch;
GO
PRINT 'Script 2485 applied: Bed / Room Tariff RMO Charge.';
GO
