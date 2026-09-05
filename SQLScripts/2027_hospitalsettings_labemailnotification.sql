IF NOT EXISTS (
    SELECT * FROM sys.columns 
    WHERE Name = N'LabEmailNotificationRequired'
    AND Object_ID = Object_ID(N'[dbo].[HospitalSettings]')
)
BEGIN
    ALTER TABLE [dbo].[HospitalSettings] ADD [LabEmailNotificationRequired] BIT NOT NULL DEFAULT 1;
    PRINT 'Added LabEmailNotificationRequired column to HospitalSettings table.'
END
ELSE
BEGIN
    PRINT 'LabEmailNotificationRequired column already exists in HospitalSettings table.'
END
GO
