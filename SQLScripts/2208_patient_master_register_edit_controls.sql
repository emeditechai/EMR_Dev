-- =====================================================================================================================
-- 2208  Settings > Security > Role Permissions: Patient Master (MASTER.OPD) gets its own Register and Edit controls
--
--   REGISTER  "Register patient"  the Register Patient button of Patient Master. Registering itself stays the
--                                 Patient Registration page (OPD.PATIENTREGISTRATION), which has its own menu item.
--   EDIT      "Edit patient"      editing a patient's details from Patient Master (list / details page). Checked inside
--                                 OPD/PatientRegistration when it opens or saves an existing patient's demographics
--                                 (the screen itself still needs Patient Registration > Open page).
--
-- "List view" is the page's existing Open page (VIEW) control. Like every control, an unset one follows its page:
-- a role allowed Patient Master keeps editing as today until someone denies Edit. No grants are seeded.
-- Safe to re-run.
-- =====================================================================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @page INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'MASTER.OPD'), @ctl INT;
IF @page IS NOT NULL
BEGIN
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'REGISTER', @Title = N'Register patient', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EDIT', @Title = N'Edit patient', @Sort_Order = 40, @Control_ID = @ctl OUTPUT;
END

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
