Text
----
CREATE PROCEDURE dbo.usp_LabOrder_GetPagedList
    @BranchId INT,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @Search NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromDate IS NULL 
SET @FromDate = CAST(GETDATE() AS DATE);
    IF @ToDate IS NULL SET @ToDate = CAST(GETDATE() AS DATE);
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize < 1 SET @PageSize = 10;

    -- Stats
    SELECT 
        COUNT(1) AS TotalOrders,
        
ISNULL(SUM(o.TotalAmount), 0.00) AS TotalAmount,
        ISNULL(SUM(CASE WHEN ph.PaymentStatus = 'P' THEN 1 ELSE 0 END), 0) AS PaidCount,
        ISNULL(SUM(CASE WHEN ISNULL(ph.PaymentStatus, 'U') = 'U' THEN 1 ELSE 0 END), 0) AS UnpaidCount
    FROM dbo.L
abOrder o
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    WHERE o.BranchId = @BranchId
      AND CAST(o.OrderDate AS DATE) BETWEEN @FromDate AND @ToDate
      AND (
          @Search IS
 NULL 
          OR o.BillNo LIKE '%' + @Search + '%' 
          OR o.TokenNo LIKE '%' + @Search + '%'
          OR EXISTS (
              SELECT 1 FROM dbo.PatientMaster p 
              WHERE p.PatientId = o.PatientId 
                AND (p.FirstName L
IKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%' OR p.PatientCode LIKE '%' + @Search + '%')
          )
      );

    -- Paged Items
    WITH PagedOrders AS (
        SELECT 
            o.LabOrderId
,
            o.PatientId,
            o.BranchId,
            o.OrderDate,
            o.BillNo,
            o.TokenNo,
            o.TotalAmount,
            o.CollectionType,
            o.PhlebotomistId,
            phleb.FullName AS PhlebotomistName,

            o.BookingDate,
            o.IsActive,
            o.CreatedDate,
            o.CreatedBy,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.MiddleName, '') + ' ' + IS
NULL(p.LastName, ''))) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            p.DateOfBirth,
            CASE 
                WHEN p.DateOfBirth IS NOT NULL THEN DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                ELSE NULL 
  
          END AS Age,
            ph.PaymentHeaderId,
            ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
            ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
            ISNULL(ph.BalanceDue, o.TotalAmount) AS BalanceDue,
            u.FullName A
S CreatedByName,
            (
                SELECT COUNT(1) 
                FROM dbo.LabOrderItem loi 
                WHERE loi.LabOrderId = o.LabOrderId
            ) AS ItemCount,
            (
                SELECT STRING_AGG(lim.Test_Name, ', ')

                FROM dbo.LabOrderItem loi
                INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId
                WHERE loi.LabOrderId = o.LabOrderId
            ) AS TestNamesSummary,
            ROW_NUMBER() OVER 
(ORDER BY o.LabOrderId DESC) AS RowNum,
            COUNT(1) OVER() AS TotalCount
        FROM dbo.LabOrder o
        INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
        LEFT JOIN dbo.Users u ON u.Id = o.CreatedBy
        LEFT JOIN dbo.Use
rs phleb ON phleb.Id = o.PhlebotomistId
        LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
        WHERE o.BranchId = @BranchId
          AND CAST(o.OrderDate AS DATE) BETWEEN @FromDate AN
D @ToDate
          AND (
              @Search IS NULL 
              OR o.BillNo LIKE '%' + @Search + '%' 
              OR o.TokenNo LIKE '%' + @Search + '%'
              OR p.FirstName LIKE '%' + @Search + '%'
              OR p.LastName LIKE '%' + @
Search + '%'
              OR p.PhoneNumber LIKE '%' + @Search + '%'
              OR p.PatientCode LIKE '%' + @Search + '%'
          )
    )
    SELECT * FROM PagedOrders
   WHERE RowNum BETWEEN ((@PageNumber - 1) * @PageSize + 1) AND (@PageNumber * @Pa
geSize)
    ORDER BY RowNum;
END;
