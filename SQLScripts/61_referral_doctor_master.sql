IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[ReferralDoctorMaster]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[ReferralDoctorMaster](
        [ReferralDoctorId] [int] IDENTITY(1,1) NOT NULL,
        [Salutation] [nvarchar](10) NULL,
        [DoctorName] [nvarchar](150) NOT NULL,
        [PhoneNumber] [nvarchar](15) NULL,
        [EmailId] [nvarchar](150) NULL,
        [RegistrationNumber] [nvarchar](50) NULL,
        [IsActive] [bit] NOT NULL CONSTRAINT [DF_ReferralDoctorMaster_IsActive] DEFAULT ((1)),
        [CreatedBy] [int] NULL,
        [CreatedDate] [datetime2](7) NOT NULL CONSTRAINT [DF_ReferralDoctorMaster_CreatedDate] DEFAULT (sysdatetime()),
        [ModifiedBy] [int] NULL,
        [ModifiedDate] [datetime2](7) NULL,
        CONSTRAINT [PK_ReferralDoctorMaster] PRIMARY KEY CLUSTERED 
        (
            [ReferralDoctorId] ASC
        )
    ) ON [PRIMARY]
END
GO
