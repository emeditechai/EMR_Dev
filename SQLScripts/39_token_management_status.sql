-- ── Stored Procedure to Update OPD Token/Service Status ─────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_ServiceBooking_UpdateStatus
    @OPDServiceId INT,
    @Status       NVARCHAR(50),
    @UserId       INT
AS
BEGIN
    -- Do not use SET NOCOUNT ON so Dapper can get the rows affected

    IF NOT EXISTS (SELECT 1 FROM dbo.PatientOPDService WHERE OPDServiceId = @OPDServiceId)
    BEGIN
        RAISERROR('Booking not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.PatientOPDService
    SET    Status = @Status,
           ModifiedBy = @UserId,
           ModifiedDate = GETDATE()
    WHERE  OPDServiceId = @OPDServiceId;

END
GO
