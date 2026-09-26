-- ============================================================================
-- Migration: 2142_lab_report_print_meta_credit_facility_type.sql
-- Description:
--   dbo.usp_LabReporting_GetPrintMeta (script 2088) already returns the B2B
--   partner (Franchise / Company) an order was billed to in RS4, but not its
--   Credit Facility Type - the Report Entry / Image Report Entry banner needs
--   this to show "Prepaid (Wallet)" / "Postpaid (Credit)" / "Hybrid" in place
--   of the Payment Status pill for B2B orders (B2C orders keep Payment Status
--   unchanged - RS4 simply returns no row for them).
--
--   Same source and mapping as dbo.usp_B2B_GetPartnerCreditStatus (script
--   2058): Franchise reads LabFranchiseCreditLimitMaster.Credit_Facility_Type
--   (default 1 = Prepaid when no credit-limit row exists yet); Corporate
--   companies are always Postpaid (Credit) - there is no Corporate credit
--   facility type column, corporate billing is contract-based credit only.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_GetPrintMeta
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BillNo   NVARCHAR(100);
    DECLARE @BranchId INT;
    SELECT @BillNo = lo.BillNo, @BranchId = lo.BranchId FROM dbo.LabOrder lo WHERE lo.LabOrderId = @LabOrderId;

    -- ── RS1: department / category per sample ───────────────────────────────
    SELECT
        sc.samplecollectionID                           AS SamplecollectionID,
        d.DeptId                                        AS DepartmentId,
        d.DeptName                                      AS DepartmentName,
        c.Category_ID                                   AS CategoryId,
        c.Category_Name                                 AS CategoryName,
        ISNULL(c.Display_Order, 9999)                   AS CategoryOrder,
        sub.SubCategory_Name                            AS SubCategoryName,
        sc.ReceivedDate                                 AS ReceivedDate
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.LabTestCategoryMaster c    ON c.Category_ID = COALESCE(NULLIF(sc.TestcategoryID, 0), lim.Category_ID)
    LEFT  JOIN dbo.LabTestSubCategoryMaster sub ON sub.SubCategory_ID = COALESCE(NULLIF(sc.TestsubcategoryID, 0), lim.SubCategory_ID)
    LEFT  JOIN dbo.DepartmentMaster d         ON d.DeptId = COALESCE(NULLIF(sc.DepartmentID, 0), lim.Department_ID)
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1
      AND sc.Iscancelled = 0;

    -- ── RS2: signatories (validated / approved by) ──────────────────────────
    ;WITH Ev AS (
        SELECT
            CASE a.ActionName WHEN 'LAB.ReportValidated' THEN 'VALIDATED' ELSE 'APPROVED' END AS SignRole,
            a.UserId,
            MAX(a.CreatedDate) AS EventDate
        FROM dbo.AuditLogs a
        WHERE @BillNo IS NOT NULL
          AND a.ModuleCode = 'LAB'
          AND a.ReferenceNo = @BillNo
          AND a.ActionName IN ('LAB.ReportValidated', 'LAB.ReportApproved')
          AND a.UserId IS NOT NULL
        GROUP BY CASE a.ActionName WHEN 'LAB.ReportValidated' THEN 'VALIDATED' ELSE 'APPROVED' END, a.UserId

        UNION ALL

        -- fallback for orders approved before audit logging existed: last modifier of approved rows
        SELECT 'APPROVED', led.ModifiedBy, MAX(led.Approved_Date)
        FROM dbo.labentrydetails led
        WHERE led.LabOrderId = @LabOrderId
          AND led.ReportStatusId = 5
          AND led.ModifiedBy IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dbo.AuditLogs a2
                          WHERE a2.ModuleCode = 'LAB' AND a2.ReferenceNo = @BillNo
                            AND a2.ActionName = 'LAB.ReportApproved' AND a2.UserId IS NOT NULL)
        GROUP BY led.ModifiedBy
    )
    SELECT
        Ev.SignRole,
        Ev.UserId,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS FullName,
        u.RegistrationNo,
        u.CertificationNo,
        CAST(ISNULL(u.IsPathologist, 0) AS BIT)                  AS IsPathologist,
        Ev.EventDate
    FROM Ev
    INNER JOIN dbo.Users u ON u.Id = Ev.UserId
    ORDER BY Ev.SignRole, Ev.EventDate DESC;

    -- ── RS3: processing lab (where the specimen was tested) ─────────────────
    DECLARE @LabBranchId INT = @BranchId;
    SELECT TOP 1 @LabBranchId = sc.TargetBranchID
    FROM dbo.SampleCollection sc
    WHERE sc.Laborderid = @LabOrderId AND sc.IsTransferred = 1 AND sc.TargetBranchID IS NOT NULL
    ORDER BY sc.TransferredDate DESC;

    SELECT TOP 1
        b.BranchId                                       AS BranchId,
        b.BranchName                                     AS BranchName,
        b.BranchCode                                     AS BranchCode,
        COALESCE(NULLIF(LTRIM(RTRIM(hs.Address)), ''), b.Address) AS Address,
        b.City                                           AS City,
        b.State                                          AS State,
        b.Pincode                                        AS Pincode,
        hs.ContactNumber1                                AS Phone,
        hs.EmailAddress                                  AS Email
    FROM dbo.Branchmaster b
    LEFT JOIN dbo.HospitalSettings hs ON hs.BranchID = b.BranchID AND hs.IsActive = 1
    WHERE b.BranchID = @LabBranchId;

    -- ── RS4: B2B partner (Franchise 'F' / Company 'C'); no row for B2C ───────
    -- Credit Facility Type: same source/mapping as usp_B2B_GetPartnerCreditStatus.
    SELECT TOP 1
        CASE o.AgentType WHEN 'F' THEN 'FRANCHISE' ELSE 'COMPANY' END              AS ClientType,
        CASE WHEN o.AgentType = 'F' THEN f.Franchise_Code ELSE corp.Corporate_Code END AS Code,
        CASE WHEN o.AgentType = 'F' THEN f.Franchise_Name ELSE corp.Corporate_Name END AS Name,
        CASE WHEN o.AgentType = 'C'
             THEN NULLIF(LTRIM(RTRIM(CONCAT(corp.Address,
                        CASE WHEN NULLIF(CAST(corp.Pincode AS NVARCHAR(20)), '') IS NOT NULL
                             THEN ' - ' + CAST(corp.Pincode AS NVARCHAR(20)) ELSE '' END))), '')
             ELSE NULL END                                                          AS Address,
        CASE WHEN o.AgentType = 'F' THEN f.Mobile_No ELSE corp.Contact_No END       AS Phone,
        CASE WHEN o.AgentType = 'F' THEN ISNULL(fc.Credit_Facility_Type, 1) ELSE 2 END AS CreditFacilityType,
        CASE
            WHEN o.AgentType = 'F' THEN
                CASE ISNULL(fc.Credit_Facility_Type, 1)
                    WHEN 1 THEN 'Prepaid (Wallet)'
                    WHEN 2 THEN 'Postpaid (Credit)'
                    WHEN 3 THEN 'Hybrid'
                    ELSE 'Prepaid (Wallet)'
                END
            ELSE 'Postpaid (Credit)'
        END                                                                         AS CreditFacilityTypeName
    FROM dbo.LabOrder o
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID  = o.B2BAgentID AND o.AgentType = 'F'
    LEFT JOIN dbo.LabFranchiseCreditLimitMaster fc ON fc.Franchise_ID = f.Franchise_ID AND o.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster  corp ON corp.Corporate_ID = o.B2BAgentID AND o.AgentType = 'C'
    WHERE o.LabOrderId = @LabOrderId
      AND o.IsB2B = 1
      AND o.AgentType IN ('F', 'C');
END;
GO

PRINT 'Script 2142 applied: usp_LabReporting_GetPrintMeta now also returns Credit Facility Type for B2B orders.';
GO
