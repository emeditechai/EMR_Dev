-- ============================================================
-- 13_doctor_consulting_fees.sql
-- Maps doctors to their consulting fee(s) from ServiceMaster
-- ============================================================

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_NAME = 'DoctorConsultingFeeMap'
)
BEGIN
    CREATE TABLE DoctorConsultingFeeMap (
        MappingId    INT IDENTITY(1,1) PRIMARY KEY,
        DoctorId     INT  NOT NULL,
        ServiceId    INT  NOT NULL,
        BranchId     INT  NOT NULL,
        IsActive     BIT  NOT NULL DEFAULT 1,
        CreatedBy    INT  NULL,
        CreatedDate  DATETIME2 NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_DoctorConsultingFeeMap_Doctor
            FOREIGN KEY (DoctorId)  REFERENCES DoctorMaster(DoctorId),
        CONSTRAINT FK_DoctorConsultingFeeMap_Service
            FOREIGN KEY (ServiceId) REFERENCES ServiceMaster(ServiceId),
        CONSTRAINT FK_DoctorConsultingFeeMap_Branch
            FOREIGN KEY (BranchId)  REFERENCES BranchMaster(BranchId),
        CONSTRAINT UQ_DoctorConsultingFeeMap
            UNIQUE (DoctorId, ServiceId, BranchId)
    );

    CREATE INDEX IX_DoctorConsultingFeeMap_Doctor  ON DoctorConsultingFeeMap(DoctorId);
    CREATE INDEX IX_DoctorConsultingFeeMap_Branch  ON DoctorConsultingFeeMap(BranchId);

    PRINT 'DoctorConsultingFeeMap table created.';
END
ELSE
BEGIN
    PRINT 'DoctorConsultingFeeMap table already exists — skipped.';
END
GO
