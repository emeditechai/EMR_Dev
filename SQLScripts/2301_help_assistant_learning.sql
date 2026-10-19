-- ============================================================================================================
-- Migration: 2301_help_assistant_learning.sql
-- Utility > Help Center: the AI Help Assistant improves day by day from how it is used.
--   * every question is logged (what was asked, what it understood, what it answered)
--   * "Yes / No" on an answer and a click on a related topic are recorded against the question; the ML.NET models
--     of EMR.Api are retrained on the confirmed answers (and stop giving rejected ones)
--   * administrators teach it in Help Insights: the right topic for a question it missed takes effect at once
--   * Help Insights shows the daily trend (asked, answered, helpful) and what it has learned
-- Data goes EMR.Web -> EMR.Api (api/help, api/help/learning) -> the procedures below. Needs 2300. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.HelpAskLog', N'U') IS NULL
CREATE TABLE dbo.HelpAskLog
(
    AskId        BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_HelpAskLog PRIMARY KEY,
    CompanyId    INT            NOT NULL,
    Question     NVARCHAR(400)  NOT NULL,
    Intent       VARCHAR(10)    NULL,            -- HOWTO / NEXT / BEFORE / FLOW / PROBLEM / WHERE
    AnswerCode   VARCHAR(120)   NULL,            -- the help topic answered (NULL: no answer found)
    Found        BIT            NOT NULL,
    Confidence   DECIMAL(4, 2)  NULL,
    PageCode     NVARCHAR(100)  NULL,            -- the screen it was asked from
    UserId       INT            NULL,
    CreatedDate  DATETIME       NOT NULL CONSTRAINT DF_HelpAskLog_Created DEFAULT (GETDATE())
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_HelpAskLog_Company_Date' AND object_id = OBJECT_ID(N'dbo.HelpAskLog'))
    CREATE INDEX IX_HelpAskLog_Company_Date ON dbo.HelpAskLog (CompanyId, CreatedDate) INCLUDE (Found, Intent);
GO

-- what the assistant has learned: a question (in its normalised form) -> the right topic and / or what the user wanted
IF OBJECT_ID(N'dbo.HelpLearned', N'U') IS NULL
CREATE TABLE dbo.HelpLearned
(
    LearnedId    INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_HelpLearned PRIMARY KEY,
    CompanyId    INT            NOT NULL,
    QuestionKey  NVARCHAR(400)  NOT NULL,        -- the question's words, normalised and stemmed (EMR.Api)
    Question     NVARCHAR(400)  NOT NULL,        -- as last asked
    TargetCode   VARCHAR(120)   NULL,            -- help topic code or PAGE:<page code>
    Intent       VARCHAR(10)    NULL,
    Source       VARCHAR(10)    NOT NULL CONSTRAINT DF_HelpLearned_Source DEFAULT ('USER'),   -- USER (feedback) / ADMIN (taught)
    UpVotes      INT            NOT NULL CONSTRAINT DF_HelpLearned_Up DEFAULT (0),
    DownVotes    INT            NOT NULL CONSTRAINT DF_HelpLearned_Down DEFAULT (0),
    Clicks       INT            NOT NULL CONSTRAINT DF_HelpLearned_Clicks DEFAULT (0),
    IsActive     BIT            NOT NULL CONSTRAINT DF_HelpLearned_Active DEFAULT (1),
    CreatedBy    INT            NULL,
    CreatedDate  DATETIME       NOT NULL CONSTRAINT DF_HelpLearned_Created DEFAULT (GETDATE()),
    ModifiedBy   INT            NULL,
    ModifiedDate DATETIME       NOT NULL CONSTRAINT DF_HelpLearned_Modified DEFAULT (GETDATE())
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_HelpLearned_Company_Key' AND object_id = OBJECT_ID(N'dbo.HelpLearned'))
    CREATE INDEX IX_HelpLearned_Company_Key ON dbo.HelpLearned (CompanyId, QuestionKey);
GO

CREATE OR ALTER PROCEDURE dbo.usp_Help_Ask_Log
    @CompanyId INT, @Question NVARCHAR(400), @Intent VARCHAR(10) = NULL, @AnswerCode VARCHAR(120) = NULL, @Found BIT,
    @Confidence DECIMAL(4, 2) = NULL, @PageCode NVARCHAR(100) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.HelpAskLog (CompanyId, Question, Intent, AnswerCode, Found, Confidence, PageCode, UserId)
    VALUES (@CompanyId, LEFT(@Question, 400), @Intent, @AnswerCode, @Found, @Confidence, @PageCode, @UserId);
END
GO

-- a signal about a question: UP / DOWN (the "Did this answer your question?" buttons), CLICK (a related topic opened
-- from the answer), TEACH (an administrator sets the right topic; other learned topics of that question are switched off)
CREATE OR ALTER PROCEDURE dbo.usp_Help_Learn
    @CompanyId INT, @Question NVARCHAR(400), @QuestionKey NVARCHAR(400), @TargetCode VARCHAR(120) = NULL, @Intent VARCHAR(10) = NULL,
    @Signal VARCHAR(10), @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NULLIF(LTRIM(@QuestionKey), N'') IS NULL OR (@TargetCode IS NULL AND @Intent IS NULL) RETURN;
    IF @Signal NOT IN ('UP', 'DOWN', 'CLICK', 'TEACH') RETURN;

    DECLARE @id INT = (SELECT TOP 1 LearnedId FROM dbo.HelpLearned
                        WHERE CompanyId = @CompanyId AND QuestionKey = @QuestionKey
                          AND ISNULL(TargetCode, '') = ISNULL(@TargetCode, '') AND ISNULL(Intent, '') = ISNULL(@Intent, '')
                        ORDER BY LearnedId);
    IF @Signal = 'TEACH'
        UPDATE dbo.HelpLearned SET IsActive = 0, ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE CompanyId = @CompanyId AND QuestionKey = @QuestionKey AND (@id IS NULL OR LearnedId <> @id) AND IsActive = 1
           AND (@TargetCode IS NULL OR TargetCode IS NOT NULL);
    IF @id IS NULL
        INSERT dbo.HelpLearned (CompanyId, QuestionKey, Question, TargetCode, Intent, Source, UpVotes, DownVotes, Clicks, CreatedBy, ModifiedBy)
        VALUES (@CompanyId, LEFT(@QuestionKey, 400), LEFT(@Question, 400), @TargetCode, @Intent,
                CASE WHEN @Signal = 'TEACH' THEN 'ADMIN' ELSE 'USER' END,
                CASE WHEN @Signal IN ('UP', 'TEACH') THEN 1 ELSE 0 END, CASE WHEN @Signal = 'DOWN' THEN 1 ELSE 0 END,
                CASE WHEN @Signal = 'CLICK' THEN 1 ELSE 0 END, @UserId, @UserId);
    ELSE
        UPDATE dbo.HelpLearned
           SET Question = LEFT(@Question, 400),
               Source = CASE WHEN @Signal = 'TEACH' THEN 'ADMIN' ELSE Source END,
               UpVotes = UpVotes + CASE WHEN @Signal IN ('UP', 'TEACH') THEN 1 ELSE 0 END,
               DownVotes = DownVotes + CASE WHEN @Signal = 'DOWN' THEN 1 ELSE 0 END,
               Clicks = Clicks + CASE WHEN @Signal = 'CLICK' THEN 1 ELSE 0 END,
               IsActive = CASE WHEN @Signal = 'TEACH' THEN 1 ELSE IsActive END,
               ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE LearnedId = @id;
END
GO

-- everything learned that is still in use (EMR.Api decides the weight of each from its votes)
CREATE OR ALTER PROCEDURE dbo.usp_Help_Learned_List @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT LearnedId, QuestionKey, Question, TargetCode, Intent, Source, UpVotes, DownVotes, Clicks, ModifiedDate
      FROM dbo.HelpLearned WHERE CompanyId = @CompanyId AND IsActive = 1;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Help_Learned_Forget @CompanyId INT, @LearnedId INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.HelpLearned SET IsActive = 0, ModifiedBy = @UserId, ModifiedDate = GETDATE()
     WHERE CompanyId = @CompanyId AND LearnedId = @LearnedId;
    SELECT @@ROWCOUNT AS Affected;
END
GO

-- Help Insights: the daily trend of the last 30 days, the totals and what has been learned
CREATE OR ALTER PROCEDURE dbo.usp_Help_Learning_Stats @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATE = DATEADD(DAY, -29, CAST(GETDATE() AS DATE));
    ;WITH d AS (SELECT @from AS Day UNION ALL SELECT DATEADD(DAY, 1, Day) FROM d WHERE Day < CAST(GETDATE() AS DATE)),
    a AS (SELECT CAST(CreatedDate AS DATE) AS Day, COUNT(*) AS Asked, SUM(CASE WHEN Found = 1 THEN 1 ELSE 0 END) AS Answered
            FROM dbo.HelpAskLog WHERE CompanyId = @CompanyId AND CreatedDate >= @from GROUP BY CAST(CreatedDate AS DATE)),
    f AS (SELECT CAST(CreatedDate AS DATE) AS Day, SUM(CASE WHEN Helpful = 1 THEN 1 ELSE 0 END) AS Helpful, SUM(CASE WHEN Helpful = 0 THEN 1 ELSE 0 END) AS NotHelpful
            FROM dbo.HelpFeedback WHERE CompanyId = @CompanyId AND CreatedDate >= @from AND Helpful IS NOT NULL GROUP BY CAST(CreatedDate AS DATE))
    SELECT d.Day, ISNULL(a.Asked, 0) AS Asked, ISNULL(a.Answered, 0) AS Answered, ISNULL(f.Helpful, 0) AS Helpful, ISNULL(f.NotHelpful, 0) AS NotHelpful
      FROM d LEFT JOIN a ON a.Day = d.Day LEFT JOIN f ON f.Day = d.Day
     ORDER BY d.Day
    OPTION (MAXRECURSION 40);

    SELECT TOP 200 l.LearnedId, l.Question, l.TargetCode, ha.Title AS TargetTitle, l.Intent, l.Source, l.UpVotes, l.DownVotes, l.Clicks, l.ModifiedDate,
           COALESCE(NULLIF(u.FullName, ''), u.Username) AS ByUser
      FROM dbo.HelpLearned l
      LEFT JOIN dbo.HelpArticle ha ON ha.Code = l.TargetCode
      LEFT JOIN dbo.Users u ON u.Id = l.ModifiedBy
     WHERE l.CompanyId = @CompanyId AND l.IsActive = 1 AND (l.Source = 'ADMIN' OR l.UpVotes > 0 OR l.DownVotes > 0 OR l.Clicks > 1)
     ORDER BY CASE l.Source WHEN 'ADMIN' THEN 0 ELSE 1 END, l.ModifiedDate DESC;
END
GO

-- ── EMR.Api api/help/learning: under the Help Center page (outside API clients need the page; EMR.Web checks admin) ──
DECLARE @page INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'UTILITY.HELP';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'GET',  @Controller = N'HelpLearning', @Action = N'Stats',  @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'POST', @Controller = N'HelpLearning', @Action = N'Teach',  @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'POST', @Controller = N'HelpLearning', @Action = N'Forget', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO

PRINT 'Script 2301 applied: the Help Assistant learns from use (ask log, feedback learning, admin teaching).';
GO
