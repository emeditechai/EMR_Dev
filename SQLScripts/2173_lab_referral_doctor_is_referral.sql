-- ============================================================================
-- Migration: 2173_lab_referral_doctor_is_referral.sql
-- Description:
--   B2C / B2B LAB booking > "Referred By Doctor": besides the existing rules (active Doctor Master doctor,
--   active LAB-type department, the company / branch), the doctor must be marked "Is Referral Doctor"
--   (Doctor Master, script 2172).
--     dbo.usp_Lab_GetReferralDoctors   the dropdown list   (live definition from 2127 + d.IsReferralDoctor = 1)
--     dbo.usp_CreateLabOrder           the save re-checks the chosen doctor the same way (live 2127 + the same rule)
--   Bills already saved keep their referral doctor; only new bookings are checked.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Lab_GetReferralDoctors
    @CompanyId INT = NULL,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Active Doctor Master doctors marked "Is Referral Doctor" and assigned to an active LAB-type department,
    -- available in the branch (same branch rule as the Doctor list: created in the branch or mapped to it).
    SELECT d.DoctorId,
           LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS DoctorName,
           ps.SpecialityName,
           dep.DepartmentNames
    FROM dbo.DoctorMaster d
    LEFT JOIN dbo.DoctorSpecialityMaster ps ON ps.SpecialityId = d.PrimarySpecialityId
    CROSS APPLY (
        SELECT STRING_AGG(CAST(dm.DeptName AS NVARCHAR(MAX)), N', ') AS DepartmentNames
        FROM dbo.DoctorDepartmentMap ddm
        INNER JOIN dbo.DepartmentMaster dm ON dm.DeptId = ddm.DeptId
        WHERE ddm.DoctorId = d.DoctorId AND ddm.IsActive = 1 AND dm.IsActive = 1 AND dm.DeptType = 'LAB'
    ) dep
    WHERE d.IsActive = 1
      AND d.IsReferralDoctor = 1
      AND dep.DepartmentNames IS NOT NULL
      AND (@CompanyId IS NULL OR d.CompanyId = @CompanyId)
      AND (@BranchId IS NULL
           OR d.CreatedBranchId = @BranchId
           OR EXISTS (SELECT 1 FROM dbo.DoctorBranchMap dbm
                      WHERE dbm.DoctorId = d.DoctorId AND dbm.BranchId = @BranchId AND dbm.IsActive = 1))
    ORDER BY d.FullName;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CreateLabOrder
    @PatientId        INT,
    @BranchId         INT,
    @CreatedBy        INT,
    @TotalAmount      DECIMAL(10,2),
    @Items            dbo.udt_LabOrderItem READONLY,
    @CollectionType   NVARCHAR(50) = 'Lab',
    @PhlebotomistId   INT          = NULL,
    @BookingDate      DATETIME     = NULL,
    @IsB2B            BIT          = 0,
    @B2BAgentID       INT          = NULL,
    @AgentType        VARCHAR(10)  = NULL,
    @B2BTotal         DECIMAL(18,2)= NULL,
    @ReferralDoctorId INT          = NULL,
    @LabOrderId       INT          OUTPUT,
    @BillNo           NVARCHAR(50) OUTPUT,
    @TokenNo          NVARCHAR(50) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Strict validation: Cannot create lab order without at least one valid test investigation
    IF NOT EXISTS (SELECT 1 FROM @Items WHERE ISNULL(InvestigationId, 0) > 0)
    BEGIN
        RAISERROR('Cannot create a laboratory bill without at least one valid test investigation (InvestigationId > 0).', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM @Items WHERE ISNULL(InvestigationId, 0) <= 0)
    BEGIN
        RAISERROR('One or more test items have an invalid Investigation ID (InvestigationId <= 0). Billing cannot proceed.', 16, 1);
        RETURN;
    END

    -- Referral doctor = Doctor Master doctor marked Is Referral Doctor, assigned to an active LAB-type department (2127, 2173)
    SET @ReferralDoctorId = NULLIF(@ReferralDoctorId, 0);
    IF @ReferralDoctorId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM dbo.DoctorMaster d
        INNER JOIN dbo.DoctorDepartmentMap ddm ON ddm.DoctorId = d.DoctorId AND ddm.IsActive = 1
        INNER JOIN dbo.DepartmentMaster dm ON dm.DeptId = ddm.DeptId AND dm.IsActive = 1 AND dm.DeptType = 'LAB'
        WHERE d.DoctorId = @ReferralDoctorId AND d.IsActive = 1 AND d.IsReferralDoctor = 1)
    BEGIN
        RAISERROR('The selected referral doctor is not an active referral doctor of a LAB department.', 16, 1);
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Set effective booking date
        DECLARE @EffectiveDate DATETIME = ISNULL(@BookingDate, GETDATE());

        -- Generate dedicated LAB Bill No
        EXEC dbo.usp_LAB_GetNextBillNo @BranchId = @BranchId, @BillNo = @BillNo OUTPUT;

        -- Generate Token immediately for each B2B billing
        IF ISNULL(@IsB2B, 0) = 1
        BEGIN
            DECLARE @DateOnly DATE = CAST(@EffectiveDate AS DATE);
            EXEC dbo.usp_B2B_LAB_GetNextTokenNo 
                @BranchId  = @BranchId, 
                @TokenDate = @DateOnly, 
                @TokenNo   = @TokenNo OUTPUT;
        END
        ELSE
        BEGIN
            SET @TokenNo = NULL; -- B2C tokens are assigned upon payment
        END

        -- Check if any item is marked urgent
        DECLARE @HasUrgent BIT = 0;
        IF EXISTS (SELECT 1 FROM @Items WHERE IsUrgent = 1)
            SET @HasUrgent = 1;

        -- Insert Header with generated TokenNo
        INSERT INTO dbo.LabOrder 
            (PatientId, BranchId, OrderDate, BillNo, TokenNo, TotalAmount, CollectionType, PhlebotomistId, BookingDate, IsUrgent, CreatedBy, CreatedDate, IsActive, IsB2B, B2BAgentID, AgentType, B2BTotal, RefDoctorId)
        VALUES 
            (@PatientId, @BranchId, @EffectiveDate, @BillNo, @TokenNo, @TotalAmount, ISNULL(@CollectionType, 'Lab'), @PhlebotomistId, @EffectiveDate, @HasUrgent, @CreatedBy, GETDATE(), 1, ISNULL(@IsB2B, 0), @B2BAgentID, @AgentType, @B2BTotal, @ReferralDoctorId);
        
        SET @LabOrderId = SCOPE_IDENTITY();

        -- Insert Items (include Type, IsUrgent, and B2BRate from @Items)
        INSERT INTO dbo.LabOrderItem (LabOrderId, InvestigationId, [Type], Price, IsUrgent, CreatedBy, CreatedDate, IsActive, B2BRate)
        SELECT 
            @LabOrderId, 
            InvestigationId, 
            ISNULL(NULLIF([Type], ''), 'I'), 
            Price, 
            ISNULL(IsUrgent, 0), 
            @CreatedBy, 
            GETDATE(), 
            1,
            B2BRate
        FROM @Items
        WHERE InvestigationId > 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
PRINT 'Script 2173 applied: LAB referral doctors are Doctor Master doctors marked Is Referral Doctor.';
GO
