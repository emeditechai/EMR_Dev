-- ============================================================================
-- Migration: 2140_lab_order_compliance_documents.sql
-- Description:
--   Investigation Master already carries three per-test flags: Prescription_Required,
--   OVD_Document, Is_Consent_Required. This script adds the storage and the lookups
--   needed so B2C and B2B LAB billing can act on them:
--
--   dbo.LabOrder                              + 6 new nullable columns: one file path
--                                              and one remarks column per condition
--                                              (prescription / OVD document / consent).
--                                              A bill needs at most one of each,
--                                              regardless of how many tests asked for it.
--   dbo.usp_Lab_GetInvestigationDocFlags       new: given the tests on the current
--                                              booking grid (plain tests and/or
--                                              profiles/packages, by id), resolves every
--                                              constituent investigation and returns
--                                              which of the three flags each one carries.
--                                              A profile/package is resolved the same way
--                                              usp on GetProfileDetails already does:
--                                              Profile_ID first, else Test_ID / Profile_Name,
--                                              then one level of nested sub-profiles.
--   dbo.usp_LabOrder_SaveComplianceDocuments   new: stores the uploaded file path and/or
--                                              the bypass remark for a bill, one call per
--                                              booking, right after the order is created.
--                                              Never overwrites a column with NULL - a
--                                              later partial call cannot erase what an
--                                              earlier one saved.
--   dbo.usp_LabOrder_GetComplianceDocuments    new: reads them back for the "view uploaded
--                                              files" action on the B2C and B2B order lists.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.LabOrder', 'PrescriptionFilePath') IS NULL
    ALTER TABLE dbo.LabOrder ADD PrescriptionFilePath NVARCHAR(300) NULL;
GO
IF COL_LENGTH('dbo.LabOrder', 'PrescriptionRemarks') IS NULL
    ALTER TABLE dbo.LabOrder ADD PrescriptionRemarks NVARCHAR(500) NULL;
GO
IF COL_LENGTH('dbo.LabOrder', 'OVDDocumentFilePath') IS NULL
    ALTER TABLE dbo.LabOrder ADD OVDDocumentFilePath NVARCHAR(300) NULL;
GO
IF COL_LENGTH('dbo.LabOrder', 'OVDDocumentRemarks') IS NULL
    ALTER TABLE dbo.LabOrder ADD OVDDocumentRemarks NVARCHAR(500) NULL;
GO
IF COL_LENGTH('dbo.LabOrder', 'ConsentFilePath') IS NULL
    ALTER TABLE dbo.LabOrder ADD ConsentFilePath NVARCHAR(300) NULL;
GO
IF COL_LENGTH('dbo.LabOrder', 'ConsentRemarks') IS NULL
    ALTER TABLE dbo.LabOrder ADD ConsentRemarks NVARCHAR(500) NULL;
GO

-- ============================================================================
-- usp_Lab_GetInvestigationDocFlags
--   @PlainTestIds  CSV of Test_ID values for line items that are a single investigation.
--   @GroupIds      CSV of ids for line items that are a profile or a package. Each id is
--                  resolved exactly like usp behind GetProfileDetails: Profile_ID first,
--                  then Test_ID or a matching Profile_Name, Profile_Type = 1 only.
--                  Nested sub-profiles (a test inside the profile that is itself a
--                  profile) are expanded one level further, same as GetProfileDetails.
--
--   Returns one row per resolved test, tagged with which requested id it came from
--   (SourceType 'I' or 'G', SourceId), so the caller can both aggregate per bill and
--   show which test triggered which requirement.
-- ============================================================================
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

    SELECT
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

-- ============================================================================
-- usp_LabOrder_SaveComplianceDocuments
--   Called once, right after the bill is created. Any parameter left NULL keeps
--   whatever is already stored - a later re-save (e.g. adding the remark after
--   choosing "not available" for one condition only) never wipes the other two.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_SaveComplianceDocuments
    @LabOrderId            INT,
    @PrescriptionFilePath  NVARCHAR(300) = NULL,
    @PrescriptionRemarks   NVARCHAR(500) = NULL,
    @OVDDocumentFilePath   NVARCHAR(300) = NULL,
    @OVDDocumentRemarks    NVARCHAR(500) = NULL,
    @ConsentFilePath       NVARCHAR(300) = NULL,
    @ConsentRemarks        NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        RAISERROR('A valid LabOrderId is required.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabOrder
    SET PrescriptionFilePath = ISNULL(@PrescriptionFilePath, PrescriptionFilePath),
        PrescriptionRemarks  = ISNULL(@PrescriptionRemarks, PrescriptionRemarks),
        OVDDocumentFilePath  = ISNULL(@OVDDocumentFilePath, OVDDocumentFilePath),
        OVDDocumentRemarks   = ISNULL(@OVDDocumentRemarks, OVDDocumentRemarks),
        ConsentFilePath      = ISNULL(@ConsentFilePath, ConsentFilePath),
        ConsentRemarks       = ISNULL(@ConsentRemarks, ConsentRemarks),
        ModifiedDate         = GETDATE()
    WHERE LabOrderId = @LabOrderId;
END;
GO

-- ============================================================================
-- usp_LabOrder_GetComplianceDocuments
--   Read-back for the "view uploaded files" action on the B2C and B2B order lists.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_GetComplianceDocuments
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        lo.LabOrderId, lo.BillNo,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        lo.PrescriptionFilePath, lo.PrescriptionRemarks,
        lo.OVDDocumentFilePath, lo.OVDDocumentRemarks,
        lo.ConsentFilePath, lo.ConsentRemarks
    FROM dbo.LabOrder lo
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    WHERE lo.LabOrderId = @LabOrderId;
END;
GO

PRINT 'Script 2140 applied: LabOrder compliance document columns and lookups created.';
GO
