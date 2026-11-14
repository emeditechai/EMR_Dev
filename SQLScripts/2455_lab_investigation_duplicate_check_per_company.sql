-- ============================================================================
-- Migration: 2455_lab_investigation_duplicate_check_per_company.sql
-- Investigation Master: the "same Test Name already exists in this Department" check now looks only at the
-- test's own company. Departments are shared across companies (usp_Company_CopyLabMasters keeps Department_ID),
-- so after copying lab masters to a new company every test of the source company failed to save on Edit.
--   usp_Api_LabInvestigationMaster_Create  duplicate check scoped to @CompanyId
--   usp_Api_LabInvestigationMaster_Update  duplicate check scoped to the edited test's CompanyId
-- Procedures are the live definitions with only that condition changed. Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 3. Update Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabInvestigationMaster_Create
    @CompanyId                 INT = 1,
    @Department_ID             INT,
    @Category_ID               INT,
    @SubCategory_ID            INT = NULL,
    @Sample_Type_ID            INT = NULL,
    @Method_ID                 INT = NULL,
    @Unit_ID                   INT = NULL,
    @Test_Name                 NVARCHAR(200),
    @Reporting_Name            NVARCHAR(200) = NULL,
    @Reporting_Type            NVARCHAR(50),
    @TAT_Hours                 INT = 24,
    @NABL_Accredited           BIT = 0,
    @NABL_Scope_No             NVARCHAR(100) = NULL,
    @Is_Outsourced             BIT = 0,
    @Is_Profile_Test           BIT = 0,
    @Applicable_Gender         VARCHAR(20) = 'All',
    @Is_Billable               BIT = 1,
    @Age_Operator              VARCHAR(20) = NULL,
    @Applicable_Age            INT = NULL,
    @Is_Fasting_Required       BIT = 0,
    @Sample_Quantity           DECIMAL(18,2) = NULL,
    @Sample_Quantity_Unit_ID   INT = NULL,
    @Reported_Duration_Value   INT = NULL,
    @Reported_Duration_Unit    VARCHAR(20) = 'Days',
    @Is_Consent_Required       BIT = 0,
    @OVD_Document  BIT = 0,
    @Prescription_Required     BIT = 0,
    @Has_External_Document     BIT = 0,
    @Is_LMP_Date_Required      BIT = 0,
    @MRP                       DECIMAL(18,2) = 0.00,
    @Status                    BIT = 1,
    @UserId                    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE CompanyId = @CompanyId AND Test_Name = @Test_Name AND Department_ID = @Department_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Investigation Master with the same Test Name already exists in this Department.', 16, 1);
        RETURN;
    END

    DECLARE @NextNum INT;
    SELECT @NextNum = ISNULL(MAX(Test_ID), 0) + 1 FROM dbo.LabInvestigationMaster;
    DECLARE @Test_Code NVARCHAR(50) = 'LAB-' + RIGHT('00000' + CAST(@NextNum AS NVARCHAR(10)), 5);

    INSERT INTO dbo.LabInvestigationMaster
    (
        CompanyId, Test_Code, Test_Name, Reporting_Name, Department_ID, Category_ID, SubCategory_ID,
        Sample_Type_ID, Method_ID, Unit_ID, Reporting_Type, TAT_Hours, NABL_Accredited,
        NABL_Scope_No, Is_Outsourced, Is_Profile_Test, Applicable_Gender, Is_Billable,
        Age_Operator, Applicable_Age, Is_Fasting_Required, Sample_Quantity, Sample_Quantity_Unit_ID,
        Reported_Duration_Value, Reported_Duration_Unit, Is_Consent_Required,
        OVD_Document, Prescription_Required, Has_External_Document, Is_LMP_Date_Required,
        MRP, Status, IsDeleted, CreatedBy, CreatedDate
    )
    VALUES
    (
        @CompanyId, @Test_Code, @Test_Name, ISNULL(NULLIF(LTRIM(RTRIM(@Reporting_Name)), ''), @Test_Name), @Department_ID, @Category_ID, @SubCategory_ID,
        @Sample_Type_ID, @Method_ID, @Unit_ID, @Reporting_Type, @TAT_Hours, @NABL_Accredited,
        @NABL_Scope_No, @Is_Outsourced, @Is_Profile_Test, ISNULL(@Applicable_Gender, 'All'), ISNULL(@Is_Billable, 1),
        @Age_Operator, @Applicable_Age, ISNULL(@Is_Fasting_Required, 0), @Sample_Quantity, @Sample_Quantity_Unit_ID,
        @Reported_Duration_Value, ISNULL(@Reported_Duration_Unit, 'Days'), ISNULL(@Is_Consent_Required, 0),
        ISNULL(@OVD_Document, 0), ISNULL(@Prescription_Required, 0), ISNULL(@Has_External_Document, 0), ISNULL(@Is_LMP_Date_Required, 0),
        @MRP, @Status, 0, @UserId, GETDATE()
    );

    SELECT SCOPE_IDENTITY() AS Test_ID;
END
GO

-- 4. Update Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabInvestigationMaster_Update
    @Test_ID                   INT,
    @Department_ID             INT,
    @Category_ID               INT,
    @SubCategory_ID            INT = NULL,
    @Sample_Type_ID            INT = NULL,
    @Method_ID                 INT = NULL,
    @Unit_ID                   INT = NULL,
    @Test_Name                 NVARCHAR(200),
    @Reporting_Name            NVARCHAR(200) = NULL,
    @Reporting_Type            NVARCHAR(50),
    @TAT_Hours                 INT = 24,
    @NABL_Accredited           BIT = 0,
    @NABL_Scope_No             NVARCHAR(100) = NULL,
    @Is_Outsourced             BIT = 0,
    @Is_Profile_Test           BIT = 0,
    @Applicable_Gender         VARCHAR(20) = 'All',
    @Is_Billable               BIT = 1,
    @Age_Operator              VARCHAR(20) = NULL,
    @Applicable_Age            INT = NULL,
    @Is_Fasting_Required       BIT = 0,
    @Sample_Quantity           DECIMAL(18,2) = NULL,
    @Sample_Quantity_Unit_ID   INT = NULL,
    @Reported_Duration_Value   INT = NULL,
    @Reported_Duration_Unit    VARCHAR(20) = 'Days',
    @Is_Consent_Required       BIT = 0,
    @OVD_Document  BIT = 0,
    @Prescription_Required     BIT = 0,
    @Has_External_Document     BIT = 0,
    @Is_LMP_Date_Required      BIT = 0,
    @MRP                       DECIMAL(18,2) = 0.00,
    @Status                    BIT = 1,
    @UserId                    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster WHERE CompanyId = (SELECT CompanyId FROM dbo.LabInvestigationMaster WHERE Test_ID = @Test_ID)
                 AND Test_Name = @Test_Name AND Department_ID = @Department_ID AND Test_ID <> @Test_ID AND IsDeleted = 0)
    BEGIN
        RAISERROR('Another Investigation Master with the same Test Name already exists in this Department.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabInvestigationMaster
    SET Department_ID             = @Department_ID,
        Category_ID               = @Category_ID,
        SubCategory_ID            = @SubCategory_ID,
        Sample_Type_ID            = @Sample_Type_ID,
        Method_ID                 = @Method_ID,
        Unit_ID                   = @Unit_ID,
        Test_Name                 = @Test_Name,
        -- Blank takes the test name. A reporting name that was only a copy of the old
        -- test name (Test_Name below is the value before this update) follows a rename.
        Reporting_Name            = CASE
                                        WHEN NULLIF(LTRIM(RTRIM(@Reporting_Name)), '') IS NULL
                                          OR LTRIM(RTRIM(@Reporting_Name)) = Test_Name
                                        THEN @Test_Name
                                        ELSE LTRIM(RTRIM(@Reporting_Name))
                                    END,
        Reporting_Type            = @Reporting_Type,
        TAT_Hours                 = @TAT_Hours,
        NABL_Accredited           = @NABL_Accredited,
        NABL_Scope_No             = @NABL_Scope_No,
        Is_Outsourced             = @Is_Outsourced,
        Is_Profile_Test           = @Is_Profile_Test,
        Applicable_Gender         = ISNULL(@Applicable_Gender, 'All'),
        Is_Billable               = ISNULL(@Is_Billable, 1),
        Age_Operator              = @Age_Operator,
        Applicable_Age            = @Applicable_Age,
        Is_Fasting_Required       = ISNULL(@Is_Fasting_Required, 0),
        Sample_Quantity           = @Sample_Quantity,
        Sample_Quantity_Unit_ID   = @Sample_Quantity_Unit_ID,
        Reported_Duration_Value   = @Reported_Duration_Value,
        Reported_Duration_Unit    = ISNULL(@Reported_Duration_Unit, 'Days'),
        Is_Consent_Required       = ISNULL(@Is_Consent_Required, 0),
        OVD_Document  = ISNULL(@OVD_Document, 0),
        Prescription_Required     = ISNULL(@Prescription_Required, 0),
        Has_External_Document     = ISNULL(@Has_External_Document, 0),
        Is_LMP_Date_Required      = ISNULL(@Is_LMP_Date_Required, 0),
        MRP                       = @MRP,
        Status                    = @Status,
        ModifiedBy                = @UserId,
        ModifiedDate              = GETDATE()
    WHERE Test_ID = @Test_ID AND IsDeleted = 0;
END
GO
