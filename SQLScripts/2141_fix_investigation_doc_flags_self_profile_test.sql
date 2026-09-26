-- ============================================================================
-- Migration: 2141_fix_investigation_doc_flags_self_profile_test.sql
-- Description:
--   Bug fix for dbo.usp_Lab_GetInvestigationDocFlags (added in script 2140).
--
--   A test can be BOTH an investigation and a profile at the same time
--   (LabInvestigationMaster.Is_Profile_Test = 1, e.g. "Complete Blood Count
--   (CBC) with ESR", Test_ID 1, which breaks down into Hemoglobin, WBC, ESR,
--   etc. under LabInvestigationProfileHeader/Detail). Its own
--   Prescription_Required / OVD_Document / Is_Consent_Required flags live on
--   its OWN LabInvestigationMaster row - separate from its constituent
--   analytes, which normally carry no flags of their own.
--
--   The original procedure, when given such a test as a @GroupIds entry
--   (which the booking grid does whenever Is_Profile_Test = 1), resolved it
--   to its constituent analytes and returned ONLY their flags - the
--   container test's own flags were never looked up, so e.g. CBC's
--   Consent Required = Yes was silently dropped and the upload/alert never
--   fired during B2C/B2B billing.
--
--   Fix: also look up LabInvestigationMaster directly by the @GroupIds id
--   itself (a group id IS a Test_ID when it is a profile-test, exactly the
--   same id the booking grid already sends), and include that row's own
--   flags in the result alongside its constituent analytes'.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Lab_GetInvestigationDocFlags
    @PlainTestIds NVARCHAR(MAX) = NULL,
    @GroupIds     NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Plain TABLE (TestId INT PRIMARY KEY);
    INSERT INTO @Plain (TestId)
    SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
    FROM STRING_SPLIT(ISNULL(@PlainTestIds, ''), ',')
    WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL;

    DECLARE @Groups TABLE (GroupId INT PRIMARY KEY);
    INSERT INTO @Groups (GroupId)
    SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
    FROM STRING_SPLIT(ISNULL(@GroupIds, ''), ',')
    WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL;

    -- Resolve each group id to a real Profile_ID, the same fallback order GetProfileDetails uses.
    DECLARE @ResolvedGroups TABLE (GroupId INT, ProfileId INT);
    INSERT INTO @ResolvedGroups (GroupId, ProfileId)
    SELECT g.GroupId,
           COALESCE(
               (SELECT TOP 1 h.Profile_ID FROM dbo.LabInvestigationProfileHeader h
                WHERE h.Profile_ID = g.GroupId AND h.IsDeleted = 0),
               (SELECT TOP 1 h.Profile_ID FROM dbo.LabInvestigationProfileHeader h
                WHERE h.IsDeleted = 0 AND h.Profile_Type = 1
                  AND (h.Test_ID = g.GroupId
                       OR h.Profile_Name = (SELECT TOP 1 Test_Name FROM dbo.LabInvestigationMaster WHERE Test_ID = g.GroupId)))
           ) AS ProfileId
    FROM @Groups g;

    -- Direct constituent tests of each resolved profile/package
    DECLARE @GroupTests TABLE (GroupId INT, TestId INT);
    INSERT INTO @GroupTests (GroupId, TestId)
    SELECT rg.GroupId, d.Test_ID
    FROM @ResolvedGroups rg
    INNER JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = rg.ProfileId AND d.IsDeleted = 0
    WHERE rg.ProfileId IS NOT NULL;

    -- One level of nested sub-profiles: a constituent test that is itself a profile
    INSERT INTO @GroupTests (GroupId, TestId)
    SELECT gt.GroupId, d2.Test_ID
    FROM @GroupTests gt
    INNER JOIN dbo.LabInvestigationMaster t ON t.Test_ID = gt.TestId AND ISNULL(t.Is_Profile_Test, 0) = 1
    INNER JOIN dbo.LabInvestigationProfileHeader subH
        ON (subH.Test_ID = t.Test_ID OR subH.Profile_Name = t.Test_Name)
       AND subH.Profile_Type = 1 AND subH.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationProfileDetail d2 ON d2.Profile_ID = subH.Profile_ID AND d2.IsDeleted = 0;

    -- FIX: a group id can be a test that is BOTH an investigation and a profile
    -- (Is_Profile_Test = 1). Its own compliance flags live on its own
    -- LabInvestigationMaster row and must be included alongside its constituent
    -- analytes' - not just theirs.
    INSERT INTO @GroupTests (GroupId, TestId)
    SELECT g.GroupId, g.GroupId
    FROM @Groups g
    WHERE EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster m WHERE m.Test_ID = g.GroupId);

    SELECT
        'I'                                          AS SourceType,
        p.TestId                                     AS SourceId,
        m.Test_ID, m.Test_Name,
        CAST(ISNULL(m.Prescription_Required, 0) AS BIT) AS PrescriptionRequired,
        CAST(ISNULL(m.OVD_Document, 0) AS BIT)          AS OvdRequired,
        CAST(ISNULL(m.Is_Consent_Required, 0) AS BIT)   AS ConsentRequired
    FROM @Plain p
    INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = p.TestId

    UNION ALL

    SELECT DISTINCT
        'G'                                          AS SourceType,
        gt.GroupId                                   AS SourceId,
        m.Test_ID, m.Test_Name,
        CAST(ISNULL(m.Prescription_Required, 0) AS BIT) AS PrescriptionRequired,
        CAST(ISNULL(m.OVD_Document, 0) AS BIT)          AS OvdRequired,
        CAST(ISNULL(m.Is_Consent_Required, 0) AS BIT)   AS ConsentRequired
    FROM @GroupTests gt
    INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = gt.TestId;
END;
GO

PRINT 'Script 2141 applied: usp_Lab_GetInvestigationDocFlags now also checks a profile-test''s own flags.';
GO
