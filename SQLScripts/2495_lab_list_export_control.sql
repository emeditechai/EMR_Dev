-- ============================================================================
-- Migration: 2495_lab_list_export_control.sql
-- Excel / CSV / PDF download on the list pages of: Investigation Master, Lab Rate List (B2C), Lab Rate List
-- (Corporate), Lab Rate List (Franchise), Franchise Setup Master, and IPD LAB Rate List (it shares the B2C page).
--   Control EXPORT ("Download list (Excel / CSV / PDF)") on each of those pages, every company.
-- The file is built in the browser from the list on the screen (wwwroot/js/emr-list-export.js), so there is no
-- endpoint to map. Roles granted the whole page get it; a role can be denied it per control. Safe to re-run.
-- ============================================================================
SET NOCOUNT ON;
GO

DECLARE @Pages TABLE (Code NVARCHAR(100));
INSERT @Pages VALUES (N'MASTER.LABINVESTIGATIONS'), (N'MASTER.LABRATELISTB2C'), (N'MASTER.LABRATELISTCORPORATE'),
                     (N'MASTER.LABRATELISTFRANCHISE'), (N'MASTER.LABFRANCHISES'), (N'MASTER.IPD_LABRATELIST');

DECLARE @page INT, @ctl INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR
    SELECT p.Page_ID FROM dbo.PageMaster p JOIN @Pages x ON x.Code = p.Page_Code;
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EXPORT',
         @Title = N'Download list (Excel / CSV / PDF)', @Sort_Order = 60, @Control_ID = @ctl OUTPUT;
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO
