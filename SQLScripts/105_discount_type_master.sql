USE [Dev_EMR];
GO

-- 1. Create Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DiscountTypeMaster')
BEGIN
    CREATE TABLE [dbo].[DiscountTypeMaster] (
        [DiscountTypeId] INT IDENTITY(1,1) NOT NULL,
        [DiscountTypeName] NVARCHAR(100) NOT NULL,
        [DiscountFlag] CHAR(1) NOT NULL DEFAULT 'P', -- 'P' for Percentage, 'A' for Amount
        [PercentageFrom] DECIMAL(5,2) NULL,
        [PercentageTo] DECIMAL(5,2) NULL,
        [DiscountAmount] DECIMAL(18,2) NULL,
        [IsActive] BIT NOT NULL DEFAULT 1,
        [BranchId] INT NULL,
        [CompanyId] INT NULL,
        [CreatedBy] INT NOT NULL,
        [CreatedDate] DATETIME NOT NULL DEFAULT GETDATE(),
        [ModifiedBy] INT NULL,
        [ModifiedDate] DATETIME NULL,
        CONSTRAINT [PK_DiscountTypeMaster] PRIMARY KEY CLUSTERED ([DiscountTypeId] ASC)
    );
END
GO

-- 2. Create SP: Create
CREATE OR ALTER PROCEDURE [dbo].[usp_DiscountType_Create]
    @DiscountTypeName NVARCHAR(100),
    @DiscountFlag CHAR(1),
    @PercentageFrom DECIMAL(5,2),
    @PercentageTo DECIMAL(5,2),
    @DiscountAmount DECIMAL(18,2),
    @IsActive BIT,
    @BranchId INT,
    @CompanyId INT,
    @CreatedBy INT,
    @NewId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO [dbo].[DiscountTypeMaster] (
        [DiscountTypeName], 
        [DiscountFlag],
        [PercentageFrom], 
        [PercentageTo],
        [DiscountAmount],
        [IsActive], 
        [BranchId], 
        [CompanyId], 
        [CreatedBy], 
        [CreatedDate]
    )
    VALUES (
        LTRIM(RTRIM(@DiscountTypeName)), 
        @DiscountFlag,
        @PercentageFrom, 
        @PercentageTo,
        @DiscountAmount,
        @IsActive, 
        @BranchId, 
        @CompanyId, 
        @CreatedBy, 
        GETDATE()
    );

    SET @NewId = SCOPE_IDENTITY();
END
GO

-- 3. Create SP: Update
CREATE OR ALTER PROCEDURE [dbo].[usp_DiscountType_Update]
    @DiscountTypeId INT,
    @DiscountTypeName NVARCHAR(100),
    @DiscountFlag CHAR(1),
    @PercentageFrom DECIMAL(5,2),
    @PercentageTo DECIMAL(5,2),
    @DiscountAmount DECIMAL(18,2),
    @IsActive BIT,
    @ModifiedBy INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE [dbo].[DiscountTypeMaster]
    SET [DiscountTypeName] = LTRIM(RTRIM(@DiscountTypeName)),
        [DiscountFlag] = @DiscountFlag,
        [PercentageFrom] = @PercentageFrom,
        [PercentageTo] = @PercentageTo,
        [DiscountAmount] = @DiscountAmount,
        [IsActive] = @IsActive,
        [ModifiedBy] = @ModifiedBy,
        [ModifiedDate] = GETDATE()
    WHERE [DiscountTypeId] = @DiscountTypeId;
END
GO

-- 4. Create SP: Delete
CREATE OR ALTER PROCEDURE [dbo].[usp_DiscountType_Delete]
    @DiscountTypeId INT
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM [dbo].[DiscountTypeMaster]
    WHERE [DiscountTypeId] = @DiscountTypeId;
END
GO

-- 5. Create SP: GetById
CREATE OR ALTER PROCEDURE [dbo].[usp_DiscountType_GetById]
    @DiscountTypeId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * 
    FROM [dbo].[DiscountTypeMaster] 
    WHERE [DiscountTypeId] = @DiscountTypeId;
END
GO

-- 6. Create SP: GetList (Api)
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DiscountType_GetList]
    @BranchId INT = NULL,
    @Status BIT = NULL,
    @Search NVARCHAR(100) = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    
    SELECT *
    FROM [dbo].[DiscountTypeMaster]
    WHERE (@BranchId IS NULL OR [BranchId] = @BranchId)
      AND (@CompanyId IS NULL OR [CompanyId] = @CompanyId)
      AND (@Status IS NULL OR [IsActive] = @Status)
      AND (@Search IS NULL OR [DiscountTypeName] LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY [DiscountTypeName];
END
GO
