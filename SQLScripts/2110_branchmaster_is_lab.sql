-- ============================================================================
-- Migration: 2110_branchmaster_is_lab.sql
-- Description:
--   dbo.Branchmaster.IsLab - marks a branch as a lab (diagnostic centre / collection point), independent of
--   IsHOBranch. Used by the Branch Master screen (Create / Edit / list / details) so lab-eligible branches can be
--   picked out later (e.g. for lab-specific dropdowns) without guessing from the branch name.
--   Additive only; existing branches default to 0 and nothing else changes.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Branchmaster') AND name = 'IsLab')
BEGIN
    ALTER TABLE dbo.Branchmaster ADD IsLab BIT NOT NULL CONSTRAINT DF_Branchmaster_IsLab DEFAULT (0);
    PRINT 'Added column dbo.Branchmaster.IsLab';
END
ELSE
    PRINT 'Column dbo.Branchmaster.IsLab already exists';
GO
