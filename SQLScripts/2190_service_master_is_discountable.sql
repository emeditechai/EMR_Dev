-- ============================================================================
-- Migration: 2190_service_master_is_discountable.sql
-- Description: Service Master > "Is Discountable". A bill discount in the OPD payment window (booking and collecting
--   a due later) is spread only over the services marked discountable; a non-discountable service always keeps its
--   full charge. Every existing service is discountable (default 1), so existing bills and calculations are unchanged
--   until a service is switched off.
--   Run after 2189.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.ServiceMaster', 'IsDiscountable') IS NULL
    ALTER TABLE dbo.ServiceMaster ADD IsDiscountable BIT NOT NULL
        CONSTRAINT DF_ServiceMaster_IsDiscountable DEFAULT (1) WITH VALUES;
GO
