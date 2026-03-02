-- ============================================================
-- Stored Procedure: usp_GetPatientListPaged
-- Description : Server-side paginated patient list for OPD Index.
--               Returns matched rows + TotalCount via window function.
-- ============================================================
CREATE OR ALTER PROCEDURE [dbo].[usp_GetPatientListPaged]
    @BranchId   INT          = NULL,
    @PageNumber  INT          = 1,
    @PageSize    INT          = 10,
    @SearchTerm  NVARCHAR(100)= NULL
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
        p.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ', '') +
            p.LastName
        )) AS FullName,
        p.PhoneNumber,
        p.Gender,
        p.BloodGroup,
        p.DateOfBirth,
        p.CreatedDate,
        p.IsActive,
        d.FullName AS ConsultingDoctorName,
        COUNT(*) OVER() AS TotalCount
    FROM PatientMaster p
    OUTER APPLY (
        SELECT TOP 1 ConsultingDoctorId
        FROM PatientOPDService
        WHERE PatientId = p.PatientId AND IsActive = 1
        ORDER BY OPDServiceId DESC
    ) latest
    LEFT JOIN DoctorMaster d ON d.DoctorId = latest.ConsultingDoctorId
    WHERE p.IsActive = 1
      AND (@BranchId IS NULL OR p.BranchId = @BranchId)
      AND (
            @SearchTerm IS NULL
            OR p.PatientCode   LIKE '%' + @SearchTerm + '%'
            OR p.FirstName     LIKE '%' + @SearchTerm + '%'
            OR p.LastName      LIKE '%' + @SearchTerm + '%'
            OR p.PhoneNumber   LIKE '%' + @SearchTerm + '%'
          )
    ORDER BY p.CreatedDate DESC
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
END;
GO
