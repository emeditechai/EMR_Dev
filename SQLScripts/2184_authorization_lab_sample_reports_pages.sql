-- ============================================================================
-- Migration: 2184_authorization_lab_sample_reports_pages.sql
-- Description: Reports > LAB, Sample stage, in the database navigation and the page catalogue - after the B2B partner
--   reports (a block of its own, as in the LAB Reports Roadmap):
--     REPORTS.LABSAMPLESPENDING   Samples Pending Collection          (LR-10)
--     REPORTS.LABSAMPLEREJECTION  Sample Rejection & Re-collection    (LR-11)
--     REPORTS.LABSAMPLETRANSFER   Sample Transfer Register            (LR-12)
--     REPORTS.LABOUTSOURCED       Outsourced Test Register            (LR-13)
--   Each page: VIEW on its own action and on the shared data endpoint (GET Reports/GetLabReportData), like the other
--   LAB registers. LR-13 also records outsourcing from the register: its own controls OUTSOURCE_SEND (Mark sent to the
--   outside lab) and OUTSOURCE_RESULT (Record the outside lab's result), mapped to their POST actions. No role or user grant is seeded: who may open them is set in Settings > Security > Role Permissions.
--   Run after 2183.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @Pages TABLE (Code NVARCHAR(150), Title NVARCHAR(150), Action NVARCHAR(150), Sort INT, Icon NVARCHAR(100));
INSERT INTO @Pages VALUES
    (N'REPORTS.LABSAMPLESPENDING',  N'Samples Pending Collection',       N'LabSamplesPending',  130, N'bi bi-eyedropper me-2'),
    (N'REPORTS.LABSAMPLEREJECTION', N'Sample Rejection & Re-collection', N'LabSampleRejection', 140, N'bi bi-arrow-repeat me-2'),
    (N'REPORTS.LABSAMPLETRANSFER',  N'Sample Transfer Register',         N'LabSampleTransfer',  150, N'bi bi-arrow-left-right me-2'),
    (N'REPORTS.LABOUTSOURCED',      N'Outsourced Test Register',         N'LabOutsourcedTests', 160, N'bi bi-send-check me-2');

DECLARE @co INT, @menu INT, @page INT, @view INT, @code NVARCHAR(150), @title NVARCHAR(150), @action NVARCHAR(150), @sort INT, @icon NVARCHAR(100);
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.LAB' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Action, Sort, Icon FROM @Pages;
        OPEN pc; FETCH NEXT FROM pc INTO @code, @title, @action, @sort, @icon;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @code, @Title = @title,
                 @Controller = N'Reports', @Action = @action, @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon,
                 @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
            SET @view = NULL;
            SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
                 @Controller = N'Reports', @Action = @action, @Source = 'SEED';
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
                 @Controller = N'Reports', @Action = N'GetLabReportData', @Source = 'SEED';
            IF @code = N'REPORTS.LABOUTSOURCED'
            BEGIN
                DECLARE @send INT, @result INT;
                EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'OUTSOURCE_SEND',
                     @Title = N'Mark sent to outside lab', @Sort_Order = 60, @Control_ID = @send OUTPUT;
                EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'OUTSOURCE_RESULT',
                     @Title = N'Record outside-lab result', @Sort_Order = 70, @Control_ID = @result OUTPUT;
                EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @send, @App = 'WEB', @Http_Method = 'POST',
                     @Controller = N'Reports', @Action = N'MarkOutsourceSent', @Source = 'SEED';
                EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @result, @App = 'WEB', @Http_Method = 'POST',
                     @Controller = N'Reports', @Action = N'MarkOutsourceReceived', @Source = 'SEED';
            END
            FETCH NEXT FROM pc INTO @code, @title, @action, @sort, @icon;
        END
        CLOSE pc; DEALLOCATE pc;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

PRINT 'Script 2184 applied: Reports > LAB sample-stage pages in the catalogue.';
GO
