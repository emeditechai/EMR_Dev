ALTER PROCEDURE [dbo].[usp_Api_PaymentSummary_GetByBill]
    @ModuleCode  NVARCHAR(20),
    @ModuleRefId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- RS1: Bill header + patient info
    SELECT
        s.OPDServiceId          AS ModuleRefId,
        'OPD'                   AS ModuleCode,
        s.OPDServiceId,
        s.OPDBillNo,
        s.TokenNo,
        p.PatientId,
        p.PatientCode,
        (p.FirstName + ' ' + ISNULL(p.LastName, '')) AS PatientName,
        p.PhoneNumber           AS PatientPhone,
        ISNULL(s.BranchId, 0)  AS BranchId,
        ISNULL(s.TotalAmount, 0) AS SubTotal
    FROM PatientOPDService s
    INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
    WHERE s.OPDServiceId = @ModuleRefId;

    -- RS2: Line items
    SELECT
        si.ItemId               AS LineRefId,
        si.ServiceType,
        ISNULL(sm.ItemName, '(Unknown)') AS ItemName,
        ISNULL(si.ServiceCharges, 0)     AS OriginalAmount,
        0                                AS LineDiscountAmount,
        ISNULL(si.ServiceCharges, 0)     AS NetLineAmount,
        ISNULL(sm.IsGstRequired, 0)      AS IsGstRequired,
        sm.GstPercentage                 AS GstPercentage
    FROM PatientOPDServiceItem si
    LEFT JOIN ServiceMaster sm ON sm.ServiceId = si.ServiceId
    WHERE si.OPDServiceId = @ModuleRefId AND si.IsActive = 1
    ORDER BY si.ItemId;

    -- RS3: Existing payment header (if any)
    SELECT
        PaymentHeaderId,
        ISNULL(LineDiscountTotal, 0)      AS LineDiscountTotal,
        HeaderDiscountType,
        HeaderDiscountValue,
        ISNULL(HeaderDiscountAmount, 0)   AS HeaderDiscountAmount,
        ISNULL(NetAmount, 0)              AS NetAmount,
        ISNULL(TotalPaid, 0)              AS TotalPaid,
        ISNULL(BalanceDue, 0)             AS BalanceDue,
        ISNULL(PaymentStatus, 'U')        AS PaymentStatus
    FROM PaymentHeader
    WHERE ModuleCode = @ModuleCode
      AND ModuleRefId = @ModuleRefId
      AND IsActive = 1;
END
GO
