-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2439  LAB > AI Prescription Assist learns from use (per company, offline, on this database)
--   Every time the user adds suggested tests, the text the assist read and the test chosen are recorded:
--     ticked suggestion = confirmed, unticked = rejected, a "Not matched" text searched and then added = a new link.
--   The next readings use it: a text confirmed before is recognised directly (preselected once confirmed), a suggestion
--   users keep rejecting is no longer offered. Phrases are normalised (lower case, letters / digits) and at most 80 chars.
--   usp_Api_LabRx_Learn (record), usp_Api_LabRx_Learned (what the matcher reads). Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID('dbo.LabRxLearning', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LabRxLearning
    (
        CompanyId   INT           NOT NULL,
        Phrase      NVARCHAR(80)  NOT NULL,
        OptionKey   VARCHAR(20)   NOT NULL,   -- I_<investigation> / P_<package>, as the booking search box keys them
        Accepted    INT           NOT NULL CONSTRAINT DF_LabRxLearning_Acc DEFAULT (0),
        Rejected    INT           NOT NULL CONSTRAINT DF_LabRxLearning_Rej DEFAULT (0),
        FirstSeen   DATETIME      NOT NULL CONSTRAINT DF_LabRxLearning_First DEFAULT (GETDATE()),
        LastUsed    DATETIME      NOT NULL CONSTRAINT DF_LabRxLearning_Last DEFAULT (GETDATE()),
        LastUserId  INT           NULL,
        CONSTRAINT PK_LabRxLearning PRIMARY KEY (CompanyId, Phrase, OptionKey)
    );
END
GO
-- @Items JSON [{Phrase, OptionKey, Accepted (true/false)}]
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabRx_Learn @CompanyId INT, @UserId INT, @Items NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@Items) <> 1 BEGIN SELECT CAST(1 AS BIT) AS Success, 0 AS Recorded; RETURN; END
    DECLARE @I TABLE (Phrase NVARCHAR(80), OptionKey VARCHAR(20), Acc BIT);
    INSERT @I
    SELECT DISTINCT LEFT(LOWER(LTRIM(RTRIM(j.Phrase))), 80), j.OptionKey, ISNULL(j.Accepted, 0)
    FROM OPENJSON(@Items) WITH (Phrase NVARCHAR(200), OptionKey VARCHAR(20), Accepted BIT) j
    WHERE LEN(LTRIM(RTRIM(ISNULL(j.Phrase, N'')))) BETWEEN 2 AND 80 AND j.OptionKey LIKE '[IP][_]%' AND LEN(j.OptionKey) <= 20;
    MERGE dbo.LabRxLearning AS t
    USING (SELECT Phrase, OptionKey, MAX(CAST(Acc AS INT)) AS Acc FROM @I GROUP BY Phrase, OptionKey) s
       ON t.CompanyId = @CompanyId AND t.Phrase = s.Phrase AND t.OptionKey = s.OptionKey
    WHEN MATCHED THEN UPDATE SET Accepted = t.Accepted + s.Acc, Rejected = t.Rejected + (1 - s.Acc), LastUsed = GETDATE(), LastUserId = @UserId
    WHEN NOT MATCHED THEN INSERT (CompanyId, Phrase, OptionKey, Accepted, Rejected, LastUserId) VALUES (@CompanyId, s.Phrase, s.OptionKey, s.Acc, 1 - s.Acc, @UserId);
    SELECT CAST(1 AS BIT) AS Success, (SELECT COUNT(*) FROM @I) AS Recorded;
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabRx_Learned @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (5000) Phrase, OptionKey, Accepted, Rejected FROM dbo.LabRxLearning WHERE CompanyId = @CompanyId ORDER BY LastUsed DESC;
END;
GO
PRINT '2439 LAB prescription assist learning - done.';
GO
