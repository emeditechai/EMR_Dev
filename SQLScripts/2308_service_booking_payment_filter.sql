-- ============================================================================================================
-- Migration: 2308_service_booking_payment_filter.sql
-- OPD Service Booking list: a Payment Status filter within the date range, as on the B2C Order List -
-- All, Full Due, Partial Due, Paid, Partial Cancelled, Full Cancelled.
-- usp_Api_ServiceBooking_GetByBranch (live body) gets @PaymentFilter (NULL = All, unchanged: active bills only).
--   DUE / PARTIAL / PAID : active bill whose PaymentHeader status is U / R / P (no header = due)
--   PCAN                 : active bill with at least one cancelled service line
--   FCAN                 : fully cancelled bill (usp_Bill_Cancel sets PatientOPDService.IsActive = 0), shown as "Cancelled"
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_ServiceBooking_GetByBranch
    @BranchId   INT            = NULL,
    @FromDate   DATE           = NULL,
    @ToDate     DATE           = NULL,
    @PageNumber INT            = 1,
    @PageSize   INT            = 10,
    @Search     NVARCHAR(100)  = NULL,
    -- payment status filter (SQLScripts/2308): NULL all, DUE, PARTIAL, PAID, PCAN partly cancelled, FCAN fully cancelled
    @PaymentFilter VARCHAR(10)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Normalise inputs
    SET @PageNumber = ISNULL(@PageNumber, 1);
    SET @PageSize   = ISNULL(@PageSize,  10);
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize   < 1 SET @PageSize   = 10;
    IF @Search = '' SET @Search = NULL;
    SET @PaymentFilter = NULLIF(UPPER(LTRIM(RTRIM(@PaymentFilter))), '');
    IF @PaymentFilter NOT IN ('DUE', 'PARTIAL', 'PAID', 'PCAN', 'FCAN') SET @PaymentFilter = NULL;

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
        CASE WHEN s.IsActive = 0 THEN 'Cancelled' ELSE s.Status END AS Status,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        ISNULL(
            STUFF((
                SELECT DISTINCT ', ' + ISNULL(si.ServiceType, '')
                FROM PatientOPDServiceItem si
                WHERE si.OPDServiceId = s.OPDServiceId AND si.IsActive = 1
                FOR XML PATH(''), TYPE
            ).value('.','NVARCHAR(MAX)'), 1, 2, ''), ''
        )                            AS ServiceTypesSummary,
        -- ── Aggregate window columns ─────────────────────────────────
        COUNT(*)                     OVER() AS TotalCount,
        SUM(ISNULL(s.TotalAmount,0)) OVER() AS TotalFeesAll,
        SUM(CASE WHEN s.Status = 'Registered' THEN 1 ELSE 0 END) OVER() AS RegisteredCount,
        SUM(CASE WHEN s.Status = 'Completed'  THEN 1 ELSE 0 END) OVER() AS CompletedCount
    FROM PatientOPDService s
    INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
    LEFT  JOIN DoctorMaster d ON d.DoctorId  = s.ConsultingDoctorId
    LEFT  JOIN PaymentHeader ph ON ph.OPDServiceId = s.OPDServiceId AND ph.ModuleCode = 'OPD' AND ph.IsActive = 1
    -- a fully cancelled bill (usp_Bill_Cancel sets IsActive = 0) is listed only under Full Cancelled
    WHERE (CASE WHEN @PaymentFilter = 'FCAN' THEN 0 ELSE 1 END) = s.IsActive
      AND p.IsActive = 1
      AND (@BranchId IS NULL OR s.BranchId = @BranchId)
      AND (@FromDate IS NULL OR CAST(s.VisitDate AS DATE) >= @FromDate)
      AND (@ToDate   IS NULL OR CAST(s.VisitDate AS DATE) <= @ToDate)
      AND (@PaymentFilter IS NULL OR @PaymentFilter = 'FCAN'
           OR (@PaymentFilter = 'PCAN'
               AND EXISTS (SELECT 1 FROM dbo.PatientOPDServiceItem xi WHERE xi.OPDServiceId = s.OPDServiceId AND ISNULL(xi.IsActive, 0) = 0))
           OR (@PaymentFilter IN ('DUE', 'PARTIAL', 'PAID')
               AND ISNULL(ph.PaymentStatus, 'U') = CASE @PaymentFilter WHEN 'DUE' THEN 'U' WHEN 'PARTIAL' THEN 'R' ELSE 'P' END))
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
END
GO

PRINT 'Script 2308 applied: Service Booking payment status filter.';
GO
