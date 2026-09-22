-- ============================================================================
-- Migration: 2126_doctor_list_rupee_symbol.sql
-- Description: Doctor Master list showed consulting fees as "GENERAL CONSULTING (?500)": the fee text was built
--              with a non-Unicode literal (' (₹'), so SQL Server turned ₹ into '?'. The literals are now N'...'.
--              usp_Api_Doctor_GetList = live definition with only that change.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Doctor_GetList
    @CompanyId INT = NULL,
    @BranchId INT = NULL,
    @SearchQuery NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        COUNT(*) OVER() AS TotalCount,
        d.DoctorId,
        ISNULL(d.NamePrefix + ' ', '') + d.FullName AS FullName,
        ps.SpecialityName                    AS PrimarySpecialityName,
        ISNULL(dep.DepartmentNames, '')       AS DepartmentNames,
        d.PhoneNumber,
        d.EmailId,
        d.IsActive,
        ISNULL(fees.ConsultingFeeNames, '')   AS ConsultingFeeNames,
        CAST(CASE WHEN EXISTS (
            SELECT 1
            FROM DoctorDepartmentMap ddm2
            INNER JOIN DepartmentMaster dm2 ON dm2.DeptId = ddm2.DeptId
            WHERE ddm2.DoctorId = d.DoctorId
              AND ddm2.IsActive = 1
              AND dm2.DeptType  = 'OPD'
        ) THEN 1 ELSE 0 END AS BIT)           AS HasOPDDept
    FROM DoctorMaster d
    INNER JOIN DoctorSpecialityMaster ps ON ps.SpecialityId = d.PrimarySpecialityId
    OUTER APPLY (
        SELECT STUFF((
            SELECT ', ' + dm.DeptName
            FROM DoctorDepartmentMap ddm
            INNER JOIN DepartmentMaster dm ON dm.DeptId = ddm.DeptId
            WHERE ddm.DoctorId = d.DoctorId AND ddm.IsActive = 1
            FOR XML PATH(''), TYPE
        ).value('.','NVARCHAR(MAX)'), 1, 2, '') AS DepartmentNames
    ) dep
    OUTER APPLY (
        SELECT STUFF((
            SELECT N', ' + s.ItemName
                   + N' (₹' + CAST(CAST(s.ItemCharges AS DECIMAL(18,0)) AS NVARCHAR) + N')'
            FROM DoctorConsultingFeeMap m
            INNER JOIN ServiceMaster s ON s.ServiceId = m.ServiceId
            WHERE m.DoctorId = d.DoctorId
              AND m.BranchId = ISNULL(@BranchId, m.BranchId)
              AND m.IsActive = 1
            FOR XML PATH(''), TYPE
        ).value('.','NVARCHAR(MAX)'), 1, 2, '') AS ConsultingFeeNames
    ) fees
    WHERE (@CompanyId IS NULL OR d.CompanyId = @CompanyId)
      AND (
        @BranchId IS NULL
        OR d.CreatedBranchId = @BranchId
        OR EXISTS (
            SELECT 1 FROM DoctorBranchMap dbm
            WHERE dbm.DoctorId = d.DoctorId
              AND dbm.BranchId = @BranchId
              AND dbm.IsActive = 1
        )
    )
    AND (
        @SearchQuery IS NULL 
        OR d.FullName LIKE '%' + @SearchQuery + '%'
        OR d.PhoneNumber LIKE '%' + @SearchQuery + '%'
        OR d.EmailId LIKE '%' + @SearchQuery + '%'
        OR ps.SpecialityName LIKE '%' + @SearchQuery + '%'
    )
    ORDER BY d.IsActive DESC, ISNULL(d.NamePrefix + ' ', '') + d.FullName ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

PRINT 'Updated dbo.usp_Api_Doctor_GetList (rupee symbol).';
GO
