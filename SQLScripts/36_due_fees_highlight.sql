-- =================================================================================
-- Script : 36_due_fees_highlight.sql
-- Purpose: Updates stored procedures usp_GetServiceBookingsPaged and
--          usp_Api_ServiceBooking_GetByBranch to include the PaymentStatus column.
-- =================================================================================

USE Dev_EMR;
GO

-- ── 1. Update usp_GetServiceBookingsPaged ─────────────────────────────────────────
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_GetServiceBookingsPaged]
    @BranchId       INT            = NULL,
    @FromDate       DATE           = NULL,
    @ToDate         DATE           = NULL,
    @PageNumber     INT            = 1,
    @PageSize       INT            = 10,
    @SearchTerm     NVARCHAR(100)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Normalise inputs
    SET @PageNumber = ISNULL(@PageNumber, 1);
    SET @PageSize   = ISNULL(@PageSize,  10);
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize   < 1 SET @PageSize   = 10;
    IF @SearchTerm = '' SET @SearchTerm = NULL;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    SELECT
        s.OPDServiceId,
        s.VisitDate,
        s.OPDBillNo,
        s.TokenNo,
        p.PatientCode,
        p.PatientId,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ', '') +
            p.LastName
        ))                          AS PatientName,
        p.Gender,
        CASE
            WHEN p.DateOfBirth IS NULL THEN NULL
            ELSE DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                 - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
        END                         AS Age,
        d.FullName                  AS ConsultingDoctorName,
        ISNULL(s.TotalAmount, 0)    AS TotalAmount,
        s.Status,
        ISNULL(
            STUFF((
                SELECT DISTINCT ', ' + ISNULL(si.ServiceType, '')
                FROM PatientOPDServiceItem si
                WHERE si.OPDServiceId = s.OPDServiceId AND si.IsActive = 1
                FOR XML PATH(''), TYPE
            ).value('.','NVARCHAR(MAX)'), 1, 2, ''), ''
        )                           AS ServiceTypesSummary,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        -- ── Aggregate window columns (same value on every row) ──────────
        COUNT(*)                    OVER()  AS TotalCount,
        SUM(ISNULL(s.TotalAmount,0)) OVER() AS TotalFeesAll,
        SUM(CASE WHEN s.Status = 'Registered'  THEN 1 ELSE 0 END) OVER() AS RegisteredCount,
        SUM(CASE WHEN s.Status = 'Completed'   THEN 1 ELSE 0 END) OVER() AS CompletedCount
    FROM PatientOPDService s
    INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
    LEFT  JOIN DoctorMaster  d ON d.DoctorId  = s.ConsultingDoctorId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1
    WHERE s.IsActive  = 1
      AND p.IsActive  = 1
      AND (@BranchId  IS NULL OR s.BranchId = @BranchId)
      AND (@FromDate  IS NULL OR CAST(s.VisitDate AS DATE) >= @FromDate)
      AND (@ToDate    IS NULL OR CAST(s.VisitDate AS DATE) <= @ToDate)
      AND (
            @SearchTerm IS NULL
            OR p.PatientCode LIKE '%' + @SearchTerm + '%'
            OR p.FirstName   LIKE '%' + @SearchTerm + '%'
            OR p.LastName    LIKE '%' + @SearchTerm + '%'
            OR p.PhoneNumber LIKE '%' + @SearchTerm + '%'
            OR s.OPDBillNo   LIKE '%' + @SearchTerm + '%'
          )
    ORDER BY s.OPDServiceId DESC
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
END;
GO

-- ── 2. Update usp_Api_ServiceBooking_GetByBranch ───────────────────────────────────
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_ServiceBooking_GetByBranch
    @BranchId   INT            = NULL,
    @FromDate   DATE           = NULL,
    @ToDate     DATE           = NULL,
    @PageNumber INT            = 1,
    @PageSize   INT            = 10,
    @Search     NVARCHAR(100)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Normalise inputs
    SET @PageNumber = ISNULL(@PageNumber, 1);
    SET @PageSize   = ISNULL(@PageSize,  10);
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize   < 1 SET @PageSize   = 10;
    IF @Search = '' SET @Search = NULL;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    SELECT
        s.OPDServiceId,
        s.VisitDate,
        s.OPDBillNo,
        s.TokenNo,
        p.PatientCode,
        p.PatientId,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ', '') +
            p.LastName
        ))                           AS PatientName,
        p.Gender,
        CASE
            WHEN p.DateOfBirth IS NULL THEN NULL
            ELSE DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                 - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
        END                          AS Age,
        d.FullName                   AS ConsultingDoctorName,
        ISNULL(s.TotalAmount, 0)     AS TotalAmount,
        s.Status,
        ISNULL(
            STUFF((
                SELECT DISTINCT ', ' + ISNULL(si.ServiceType, '')
                FROM PatientOPDServiceItem si
                WHERE si.OPDServiceId = s.OPDServiceId AND si.IsActive = 1
                FOR XML PATH(''), TYPE
            ).value('.','NVARCHAR(MAX)'), 1, 2, ''), ''
        )                            AS ServiceTypesSummary,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        -- ── Aggregate window columns ─────────────────────────────────
        COUNT(*)                     OVER() AS TotalCount,
        SUM(ISNULL(s.TotalAmount,0)) OVER() AS TotalFeesAll,
        SUM(CASE WHEN s.Status = 'Registered' THEN 1 ELSE 0 END) OVER() AS RegisteredCount,
        SUM(CASE WHEN s.Status = 'Completed'  THEN 1 ELSE 0 END) OVER() AS CompletedCount
    FROM PatientOPDService s
    INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
    LEFT  JOIN DoctorMaster  d ON d.DoctorId  = s.ConsultingDoctorId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1
    WHERE s.IsActive = 1
      AND p.IsActive = 1
      AND (@BranchId IS NULL OR s.BranchId = @BranchId)
      AND (@FromDate IS NULL OR CAST(s.VisitDate AS DATE) >= @FromDate)
      AND (@ToDate   IS NULL OR CAST(s.VisitDate AS DATE) <= @ToDate)
      AND (
            @Search IS NULL
            OR p.PatientCode LIKE '%' + @Search + '%'
            OR p.FirstName   LIKE '%' + @Search + '%'
            OR p.LastName    LIKE '%' + @Search + '%'
            OR p.PhoneNumber LIKE '%' + @Search + '%'
            OR s.OPDBillNo   LIKE '%' + @Search + '%'
          )
    ORDER BY s.OPDServiceId DESC
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
END;
GO
