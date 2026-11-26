-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2559: Doctor Master - the doctor's signature (image), used on the IPD discharge prints (discharge / death summary,
--   MCCD) when that doctor signs. Separate from the pathologist signature of User Master (Users.SignaturePath), which is
--   not touched.
--     DoctorMaster.SignaturePath        file name of the image, kept in App_Data/doctor-signatures (not web-served)
--     usp_Api_Doctor_SignatureGet       the stored name of one doctor of the company
--     usp_Api_Doctor_SignatureSet       store / clear it (@SignaturePath NULL = remove); returns the previous name
--   Permission: Doctor Master (MASTER.DOCTORS) - upload / remove under EDIT, the preview under VIEW. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF COL_LENGTH('dbo.DoctorMaster', 'SignaturePath') IS NULL
    ALTER TABLE dbo.DoctorMaster ADD SignaturePath NVARCHAR(300) NULL;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Doctor_SignatureGet @CompanyId INT, @DoctorId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.DoctorId, d.FullName, d.SignaturePath
    FROM dbo.DoctorMaster d
    WHERE d.DoctorId = @DoctorId AND (d.CompanyId = @CompanyId OR d.CompanyId IS NULL);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Doctor_SignatureSet @CompanyId INT, @UserId INT, @DoctorId INT, @SignaturePath NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @old NVARCHAR(300), @found BIT = 0;
    SELECT @old = SignaturePath, @found = 1 FROM dbo.DoctorMaster WITH (UPDLOCK)
    WHERE DoctorId = @DoctorId AND (CompanyId = @CompanyId OR CompanyId IS NULL);
    IF @found = 0
    BEGIN
        SELECT CAST(0 AS BIT) AS Success, N'The doctor was not found.' AS Error, CAST(NULL AS NVARCHAR(300)) AS PreviousPath;
        RETURN;
    END
    UPDATE dbo.DoctorMaster SET SignaturePath = NULLIF(LTRIM(RTRIM(@SignaturePath)), N''), ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE DoctorId = @DoctorId;
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @old AS PreviousPath;
END;
GO

-- ── permissions: Doctor Master page ──
DECLARE @page INT, @edit INT, @view INT;
DECLARE pp CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'MASTER.DOCTORS';
OPEN pp; FETCH NEXT FROM pp INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @edit = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'EDIT';
    SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @edit, @App = 'WEB', @Http_Method = 'POST', @Controller = N'Doctors', @Action = N'UploadSignature', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @edit, @App = 'WEB', @Http_Method = 'POST', @Controller = N'Doctors', @Action = N'RemoveSignature', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'Doctors', @Action = N'Signature', @Source = 'SEED';
    FETCH NEXT FROM pp INTO @page;
END
CLOSE pp; DEALLOCATE pp;
-- the discharge prints read the signing doctor's image through IpdDischarge/DoctorSignature (IPD Patient VIEW)
DECLARE @pp INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'IPD.PATIENT' AND CompanyId = 1), @pv INT;
SELECT @pv = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pp AND Control_Code = 'VIEW';
IF @pp IS NOT NULL
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @pv, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdDischarge', @Action = N'DoctorSignature', @Source = 'SEED';

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2559 applied: Doctor Master signature.';
GO
