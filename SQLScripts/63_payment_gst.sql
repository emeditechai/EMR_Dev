IF NOT EXISTS(SELECT 1 FROM sys.columns WHERE Name = N'IsGstApplicable' AND Object_ID = Object_ID(N'dbo.PaymentLineItem'))
BEGIN
    ALTER TABLE dbo.PaymentLineItem ADD IsGstApplicable BIT NOT NULL DEFAULT 0;
END
GO
IF NOT EXISTS(SELECT 1 FROM sys.columns WHERE Name = N'GstPercentage' AND Object_ID = Object_ID(N'dbo.PaymentLineItem'))
BEGIN
    ALTER TABLE dbo.PaymentLineItem ADD GstPercentage DECIMAL(5,2) NULL;
END
GO
IF NOT EXISTS(SELECT 1 FROM sys.columns WHERE Name = N'CgstAmount' AND Object_ID = Object_ID(N'dbo.PaymentLineItem'))
BEGIN
    ALTER TABLE dbo.PaymentLineItem ADD CgstAmount DECIMAL(18,2) NOT NULL DEFAULT 0;
END
GO
IF NOT EXISTS(SELECT 1 FROM sys.columns WHERE Name = N'SgstAmount' AND Object_ID = Object_ID(N'dbo.PaymentLineItem'))
BEGIN
    ALTER TABLE dbo.PaymentLineItem ADD SgstAmount DECIMAL(18,2) NOT NULL DEFAULT 0;
END
GO
IF NOT EXISTS(SELECT 1 FROM sys.columns WHERE Name = N'IgstAmount' AND Object_ID = Object_ID(N'dbo.PaymentLineItem'))
BEGIN
    ALTER TABLE dbo.PaymentLineItem ADD IgstAmount DECIMAL(18,2) NOT NULL DEFAULT 0;
END
GO

IF NOT EXISTS(SELECT 1 FROM sys.columns WHERE Name = N'TotalCgstAmount' AND Object_ID = Object_ID(N'dbo.PaymentHeader'))
BEGIN
    ALTER TABLE dbo.PaymentHeader ADD TotalCgstAmount DECIMAL(18,2) NOT NULL DEFAULT 0;
END
GO
IF NOT EXISTS(SELECT 1 FROM sys.columns WHERE Name = N'TotalSgstAmount' AND Object_ID = Object_ID(N'dbo.PaymentHeader'))
BEGIN
    ALTER TABLE dbo.PaymentHeader ADD TotalSgstAmount DECIMAL(18,2) NOT NULL DEFAULT 0;
END
GO
IF NOT EXISTS(SELECT 1 FROM sys.columns WHERE Name = N'TotalIgstAmount' AND Object_ID = Object_ID(N'dbo.PaymentHeader'))
BEGIN
    ALTER TABLE dbo.PaymentHeader ADD TotalIgstAmount DECIMAL(18,2) NOT NULL DEFAULT 0;
END
GO
