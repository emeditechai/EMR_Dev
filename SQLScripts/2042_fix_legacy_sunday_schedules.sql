USE [Dev_EMR]
GO

BEGIN TRY
    BEGIN TRANSACTION;

    -- Update legacy Sunday schedules in DoctorScheduleMaster from 7 to 0
    UPDATE dbo.DoctorScheduleMaster
    SET DayOfWeek = 0
    WHERE DayOfWeek = 7;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO
