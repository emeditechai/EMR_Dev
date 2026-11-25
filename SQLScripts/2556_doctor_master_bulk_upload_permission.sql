-- ============================================================================
-- 2556: Doctor Master (Doctors/Index) - Excel bulk upload of referral doctors and OPD / IPD doctors.
--   Control IMPORT "Bulk upload (Excel)" on page MASTER.DOCTORS, mapped to the web endpoints
--   DoctorBulkUpload/Template (GET) and DoctorBulkUpload/Import (POST).
--   No schema change: the upload writes DoctorMaster, DoctorBranchMap and DoctorDepartmentMap like the Doctor form,
--   and the marketing executive through dbo.usp_Api_Doctor_SetMarketingExecutive.
--   Re-runnable.
-- ============================================================================
SET NOCOUNT ON;

DECLARE @page INT, @ctl INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR
    SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = 'MASTER.DOCTORS';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'IMPORT', @Title = N'Bulk upload (Excel)', @Sort_Order = 60, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'DoctorBulkUpload', @Action = N'Template', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'DoctorBulkUpload', @Action = N'Import', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO

PRINT '2556: MASTER.DOCTORS IMPORT control and DoctorBulkUpload endpoints mapped.';
GO
