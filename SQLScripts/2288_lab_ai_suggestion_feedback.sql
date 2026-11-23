-- ============================================================================================================
-- Migration: 2288_lab_ai_suggestion_feedback.sql
-- LAB > B2C Booking - AI test suggestions learn from the staff: every suggestion accepted (Add / Switch) or dismissed
-- (x) is kept here, and the suggestion engine lowers what is usually dismissed and raises what is usually taken.
--   dbo.LabAiSuggestionFeedback     one row per click
--   endpoint POST LabOrderBooking/TestSuggestionFeedback on control AI_SUGGEST (from 2287; no grant changes)
-- Run after 2287. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.LabAiSuggestionFeedback', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.LabAiSuggestionFeedback
    (
        FeedbackId    BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LabAiSuggestionFeedback PRIMARY KEY,
        CompanyId     INT          NOT NULL,
        BranchId      INT          NOT NULL,
        SuggestedKey  VARCHAR(20)  NOT NULL,                 -- I_<test id> / P_<package id>, as the booking screen keys items
        ContextKey    VARCHAR(20)  NULL,                     -- the selected item it was suggested for
        Kind          CHAR(1)      NOT NULL,                 -- T = billed together, B = package / profile saving
        Action        CHAR(1)      NOT NULL,                 -- A = accepted, D = dismissed
        UserId        INT          NULL,
        CreatedDate   DATETIME     NOT NULL CONSTRAINT DF_LabAiSuggestionFeedback_Created DEFAULT (GETDATE()),
        CONSTRAINT CK_LabAiSuggestionFeedback_Kind CHECK (Kind IN ('T', 'B')),
        CONSTRAINT CK_LabAiSuggestionFeedback_Action CHECK (Action IN ('A', 'D'))
    );
    CREATE INDEX IX_LabAiSuggestionFeedback_Company ON dbo.LabAiSuggestionFeedback (CompanyId, CreatedDate) INCLUDE (BranchId, SuggestedKey, ContextKey, Action);
    PRINT 'Created dbo.LabAiSuggestionFeedback.';
END
GO

DECLARE @page INT, @ctl INT;
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'LAB.LABORDERBOOKING.B2CBOOKING';
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'AI_SUGGEST');
    IF @ctl IS NOT NULL
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
             @Controller = N'LabOrderBooking', @Action = N'TestSuggestionFeedback', @Route = N'LabOrderBooking/TestSuggestionFeedback', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2288 applied: LAB AI test suggestion feedback.';
GO
