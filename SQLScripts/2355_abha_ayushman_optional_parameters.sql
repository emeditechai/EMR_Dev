-- ============================================================================================================
-- 2355  ABHA and Ayushman Bharat as optional parameters (Hospital Settings > OPD), per company, default No.
--   EnableAbha           Yes = OPD registration and LAB booking (B2C / B2B) show optional ABHA Number / ABHA Address.
--   EnableAyushmanBharat Yes = OPD registration shows optional Ayushman Card No.
--   Numbers are typed by the desk and stay unverified until the ABDM integration is built. Neither is ever mandatory.
-- Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF COL_LENGTH('dbo.HospitalSettings', 'EnableAbha') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD EnableAbha BIT NOT NULL CONSTRAINT DF_HS_EnableAbha DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'EnableAyushmanBharat') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD EnableAyushmanBharat BIT NOT NULL CONSTRAINT DF_HS_EnableAyushmanBharat DEFAULT (0);
GO
IF COL_LENGTH('dbo.PatientMaster', 'AbhaNumber') IS NULL
    ALTER TABLE dbo.PatientMaster ADD AbhaNumber NVARCHAR(20) NULL, AbhaAddress NVARCHAR(100) NULL, AyushmanCardNo NVARCHAR(30) NULL;
GO

-- descriptions (picked up by the data dictionary)
DECLARE @d TABLE (t SYSNAME, c SYSNAME, v NVARCHAR(400));
INSERT @d VALUES
 (N'HospitalSettings', N'EnableAbha', N'1 = OPD registration and LAB booking show optional ABHA fields. Saved for all branches of the company.'),
 (N'HospitalSettings', N'EnableAyushmanBharat', N'1 = OPD registration shows the optional Ayushman Card No. Saved for all branches of the company.'),
 (N'PatientMaster', N'AbhaNumber', N'14-digit ABHA number as nn-nnnn-nnnn-nnnn, optional; typed by the desk, not verified with ABDM.'),
 (N'PatientMaster', N'AbhaAddress', N'ABHA address, optional; typed by the desk, not verified with ABDM.'),
 (N'PatientMaster', N'AyushmanCardNo', N'Ayushman Bharat (AB-PMJAY) card or beneficiary number, optional; typed by the desk, not verified.');
DECLARE @t SYSNAME, @c SYSNAME, @v NVARCHAR(400);
DECLARE dc CURSOR LOCAL FAST_FORWARD FOR SELECT t, c, v FROM @d;
OPEN dc;
FETCH NEXT FROM dc INTO @t, @c, @v;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE class = 1 AND major_id = OBJECT_ID(N'dbo.' + @t) AND name = N'MS_Description'
               AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'dbo.' + @t), @c, 'ColumnId'))
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = @v, @level0type = N'SCHEMA', @level0name = N'dbo',
             @level1type = N'TABLE', @level1name = @t, @level2type = N'COLUMN', @level2name = @c;
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = @v, @level0type = N'SCHEMA', @level0name = N'dbo',
             @level1type = N'TABLE', @level1name = @t, @level2type = N'COLUMN', @level2name = @c;
    FETCH NEXT FROM dc INTO @t, @c, @v;
END
CLOSE dc;
DEALLOCATE dc;
GO
PRINT 'Script 2355 applied: ABHA and Ayushman Bharat optional parameters.';
GO
