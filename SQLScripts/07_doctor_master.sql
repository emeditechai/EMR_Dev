-- ============================================================
-- 07_doctor_master.sql
-- Doctor Master + Branch Mapping + Department Mapping
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DoctorMaster')
BEGIN
    CREATE TABLE DoctorMaster (
        DoctorId              INT IDENTITY(1,1) PRIMARY KEY,
        FullName              NVARCHAR(150) NOT NULL,
        Gender                NVARCHAR(20)  NOT NULL,
        DateOfBirth           DATE          NULL,
        EmailId               NVARCHAR(150) NOT NULL,
        PhoneNumber           NVARCHAR(20)  NOT NULL,
        MedicalLicenseNo      NVARCHAR(80)  NULL,
        PrimarySpecialityId   INT           NOT NULL,
        SecondarySpecialityId INT           NULL,
        JoiningDate           DATE          NULL,
        IsActive              BIT           NOT NULL DEFAULT 1,
        CreatedBranchId       INT           NOT NULL,
        CreatedBy             INT           NULL,
        CreatedDate           DATETIME      NOT NULL DEFAULT GETDATE(),
        ModifiedBy            INT           NULL,
        ModifiedDate          DATETIME      NULL,

        CONSTRAINT FK_DoctorMaster_PrimarySpeciality FOREIGN KEY (PrimarySpecialityId)
            REFERENCES DoctorSpecialityMaster(SpecialityId),
        CONSTRAINT FK_DoctorMaster_SecondarySpeciality FOREIGN KEY (SecondarySpecialityId)
            REFERENCES DoctorSpecialityMaster(SpecialityId),
        CONSTRAINT FK_DoctorMaster_CreatedBranch FOREIGN KEY (CreatedBranchId)
            REFERENCES Branchmaster(BranchID),
        CONSTRAINT CK_DoctorMaster_Gender CHECK (Gender IN ('Male', 'Female', 'Other'))
    );

    CREATE INDEX IX_DoctorMaster_PrimarySpecialityId ON DoctorMaster (PrimarySpecialityId);
    CREATE INDEX IX_DoctorMaster_CreatedBranchId ON DoctorMaster (CreatedBranchId);
    CREATE INDEX IX_DoctorMaster_EmailId ON DoctorMaster (EmailId);
    CREATE INDEX IX_DoctorMaster_PhoneNumber ON DoctorMaster (PhoneNumber);

    PRINT 'DoctorMaster table created.';
END
ELSE
BEGIN
    PRINT 'DoctorMaster table already exists.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DoctorBranchMap')
BEGIN
    CREATE TABLE DoctorBranchMap (
        DoctorBranchMapId INT IDENTITY(1,1) PRIMARY KEY,
        DoctorId          INT      NOT NULL,
        BranchId          INT      NOT NULL,
        IsActive          BIT      NOT NULL DEFAULT 1,
        CreatedBy         INT      NULL,
        CreatedDate       DATETIME NOT NULL DEFAULT GETDATE(),
        ModifiedBy        INT      NULL,
        ModifiedDate      DATETIME NULL,

        CONSTRAINT FK_DoctorBranchMap_Doctor FOREIGN KEY (DoctorId)
            REFERENCES DoctorMaster(DoctorId) ON DELETE CASCADE,
        CONSTRAINT FK_DoctorBranchMap_Branch FOREIGN KEY (BranchId)
            REFERENCES Branchmaster(BranchID),
        CONSTRAINT UQ_DoctorBranchMap_Doctor_Branch UNIQUE (DoctorId, BranchId)
    );

    CREATE INDEX IX_DoctorBranchMap_BranchId ON DoctorBranchMap (BranchId);
    PRINT 'DoctorBranchMap table created.';
END
ELSE
BEGIN
    PRINT 'DoctorBranchMap table already exists.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DoctorDepartmentMap')
BEGIN
    CREATE TABLE DoctorDepartmentMap (
        DoctorDepartmentMapId INT IDENTITY(1,1) PRIMARY KEY,
        DoctorId              INT      NOT NULL,
        DeptId                INT      NOT NULL,
        IsActive              BIT      NOT NULL DEFAULT 1,
        CreatedBy             INT      NULL,
        CreatedDate           DATETIME NOT NULL DEFAULT GETDATE(),
        ModifiedBy            INT      NULL,
        ModifiedDate          DATETIME NULL,

        CONSTRAINT FK_DoctorDepartmentMap_Doctor FOREIGN KEY (DoctorId)
            REFERENCES DoctorMaster(DoctorId) ON DELETE CASCADE,
        CONSTRAINT FK_DoctorDepartmentMap_Department FOREIGN KEY (DeptId)
            REFERENCES DepartmentMaster(DeptId),
        CONSTRAINT UQ_DoctorDepartmentMap_Doctor_Dept UNIQUE (DoctorId, DeptId)
    );

    CREATE INDEX IX_DoctorDepartmentMap_DeptId ON DoctorDepartmentMap (DeptId);
    PRINT 'DoctorDepartmentMap table created.';
END
ELSE
BEGIN
    PRINT 'DoctorDepartmentMap table already exists.';
END
GO
