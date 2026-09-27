-- =============================================
-- Script : 2149_microbiology_starter_kit_loader.sql
-- Purpose: Copy the microbiology starter kit (organisms, antibiotics, antibiotic
--          panels with tiers, expert rules, breakpoints) from a template company
--          into a client company. Safe to re-run: rows are matched by name and
--          existing rows in the target company are never changed.
-- Usage  : EXEC dbo.usp_Lab_Microbiology_LoadStarterKit @TargetCompanyId = 2;
-- Note   : Investigations, profiles and picklist options are not copied here;
--          they belong to the Investigation / Profile / Parameter Option masters.
-- =============================================

CREATE OR ALTER PROCEDURE dbo.usp_Lab_Microbiology_LoadStarterKit
    @TargetCompanyId INT,
    @SourceCompanyId INT = 1,
    @UserId          INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @TargetCompanyId IS NULL OR @TargetCompanyId = @SourceCompanyId
    BEGIN
        RAISERROR('Target company must be different from the source company.', 16, 1);
        RETURN;
    END

    DECLARE @Org INT = 0, @Abx INT = 0, @Pnl INT = 0, @Rul INT = 0, @Bkp INT = 0, @Base INT;

    BEGIN TRANSACTION;
    BEGIN TRY
        -- 1. Organisms
        SET @Base = (SELECT ISNULL(MAX(Organism_ID), 0) FROM dbo.LabOrganismMaster);
        INSERT INTO dbo.LabOrganismMaster (CompanyId, Organism_Code, Organism_Name, Gram_Type, Organism_Type, Organism_Category, WHONET_Code, Description, Status, CreatedBy, CreatedDate)
        SELECT @TargetCompanyId, 'ORG' + RIGHT('0000' + CAST(@Base + ROW_NUMBER() OVER (ORDER BY s.Organism_ID) AS NVARCHAR(10)), 4),
               s.Organism_Name, s.Gram_Type, s.Organism_Type, s.Organism_Category, s.WHONET_Code, s.Description, s.Status, @UserId, GETDATE()
        FROM dbo.LabOrganismMaster s
        WHERE s.CompanyId = @SourceCompanyId AND s.IsDeleted = 0
          AND NOT EXISTS (SELECT 1 FROM dbo.LabOrganismMaster t WHERE t.CompanyId = @TargetCompanyId AND t.IsDeleted = 0 AND LOWER(t.Organism_Name) = LOWER(s.Organism_Name));
        SET @Org = @@ROWCOUNT;

        -- 2. Antibiotics
        SET @Base = (SELECT ISNULL(MAX(Antibiotic_ID), 0) FROM dbo.LabAntibioticMaster);
        INSERT INTO dbo.LabAntibioticMaster (CompanyId, Antibiotic_Code, Antibiotic_Name, Abbreviation, Antibiotic_Class, Route, WHONET_Code, Description, Status, CreatedBy, CreatedDate)
        SELECT @TargetCompanyId, 'ABX' + RIGHT('0000' + CAST(@Base + ROW_NUMBER() OVER (ORDER BY s.Antibiotic_ID) AS NVARCHAR(10)), 4),
               s.Antibiotic_Name, s.Abbreviation, s.Antibiotic_Class, s.Route, s.WHONET_Code, s.Description, s.Status, @UserId, GETDATE()
        FROM dbo.LabAntibioticMaster s
        WHERE s.CompanyId = @SourceCompanyId AND s.IsDeleted = 0
          AND NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticMaster t WHERE t.CompanyId = @TargetCompanyId AND t.IsDeleted = 0 AND LOWER(t.Antibiotic_Name) = LOWER(s.Antibiotic_Name));
        SET @Abx = @@ROWCOUNT;

        -- 3. Antibiotic panels (+ specimen by name, + antibiotics and tiers)
        DECLARE @NewPanels TABLE (SourcePanelId INT, TargetPanelId INT);
        SET @Base = (SELECT ISNULL(MAX(Panel_ID), 0) FROM dbo.LabAntibioticPanelMaster);

        MERGE dbo.LabAntibioticPanelMaster AS t
        USING (
            SELECT s.*, ROW_NUMBER() OVER (ORDER BY s.Panel_ID) AS rn, ts.Sample_Type_ID AS TargetSampleId
            FROM dbo.LabAntibioticPanelMaster s
            LEFT JOIN dbo.LabSampleTypeMaster ss ON ss.Sample_Type_ID = s.Sample_Type_ID
            LEFT JOIN dbo.LabSampleTypeMaster ts ON ts.Sample_Name = ss.Sample_Name AND ts.CompanyId = @TargetCompanyId AND ts.IsDeleted = 0
            WHERE s.CompanyId = @SourceCompanyId AND s.IsDeleted = 0
              AND NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticPanelMaster x WHERE x.CompanyId = @TargetCompanyId AND x.IsDeleted = 0 AND LOWER(x.Panel_Name) = LOWER(s.Panel_Name))
        ) AS src ON 1 = 0
        WHEN NOT MATCHED THEN
            INSERT (CompanyId, Panel_Code, Panel_Name, Gram_Type, Organism_Category, Sample_Type_ID, Description, Status, CreatedBy, CreatedDate)
            VALUES (@TargetCompanyId, 'ABP' + RIGHT('0000' + CAST(@Base + src.rn AS NVARCHAR(10)), 4), src.Panel_Name, src.Gram_Type,
                    src.Organism_Category, src.TargetSampleId, src.Description, src.Status, @UserId, GETDATE())
        OUTPUT src.Panel_ID, inserted.Panel_ID INTO @NewPanels (SourcePanelId, TargetPanelId);
        SET @Pnl = (SELECT COUNT(*) FROM @NewPanels);

        INSERT INTO dbo.LabAntibioticPanelDetail (Panel_ID, Antibiotic_ID, Display_Order, Tier)
        SELECT np.TargetPanelId, ta.Antibiotic_ID, d.Display_Order, d.Tier
        FROM @NewPanels np
        JOIN dbo.LabAntibioticPanelDetail d ON d.Panel_ID = np.SourcePanelId
        JOIN dbo.LabAntibioticMaster sa ON sa.Antibiotic_ID = d.Antibiotic_ID
        JOIN dbo.LabAntibioticMaster ta ON LOWER(ta.Antibiotic_Name) = LOWER(sa.Antibiotic_Name) AND ta.CompanyId = @TargetCompanyId AND ta.IsDeleted = 0;

        -- 4. Expert rules
        SET @Base = (SELECT ISNULL(MAX(Rule_ID), 0) FROM dbo.LabExpertRuleMaster);
        INSERT INTO dbo.LabExpertRuleMaster (CompanyId, Rule_Code, Rule_Type, Organism_Category, Organism_ID, Antibiotic_ID, Trigger_Result, Rule_Action, Alert_Message, Status, CreatedBy, CreatedDate)
        SELECT @TargetCompanyId, 'EXR' + RIGHT('0000' + CAST(@Base + ROW_NUMBER() OVER (ORDER BY s.Rule_ID) AS NVARCHAR(10)), 4),
               s.Rule_Type, s.Organism_Category, tor.Organism_ID, ta.Antibiotic_ID, s.Trigger_Result, s.Rule_Action, s.Alert_Message, s.Status, @UserId, GETDATE()
        FROM dbo.LabExpertRuleMaster s
        JOIN dbo.LabAntibioticMaster sa ON sa.Antibiotic_ID = s.Antibiotic_ID
        JOIN dbo.LabAntibioticMaster ta ON LOWER(ta.Antibiotic_Name) = LOWER(sa.Antibiotic_Name) AND ta.CompanyId = @TargetCompanyId AND ta.IsDeleted = 0
        LEFT JOIN dbo.LabOrganismMaster so ON so.Organism_ID = s.Organism_ID
        LEFT JOIN dbo.LabOrganismMaster tor ON LOWER(tor.Organism_Name) = LOWER(so.Organism_Name) AND tor.CompanyId = @TargetCompanyId AND tor.IsDeleted = 0
        WHERE s.CompanyId = @SourceCompanyId AND s.IsDeleted = 0
          AND (s.Organism_ID IS NULL OR tor.Organism_ID IS NOT NULL)
          AND NOT EXISTS (SELECT 1 FROM dbo.LabExpertRuleMaster x
                          WHERE x.CompanyId = @TargetCompanyId AND x.IsDeleted = 0 AND x.Rule_Type = s.Rule_Type
                            AND x.Antibiotic_ID = ta.Antibiotic_ID AND x.Trigger_Result = s.Trigger_Result
                            AND ISNULL(x.Organism_ID, -1) = ISNULL(tor.Organism_ID, -1)
                            AND ISNULL(x.Organism_Category, '') = ISNULL(s.Organism_Category, ''));
        SET @Rul = @@ROWCOUNT;

        -- 5. Breakpoints
        SET @Base = (SELECT ISNULL(MAX(Breakpoint_ID), 0) FROM dbo.LabBreakpointMaster);
        INSERT INTO dbo.LabBreakpointMaster (CompanyId, Breakpoint_Code, Organism_Category, Organism_ID, Antibiotic_ID, Standard, Standard_Version, Method, Specimen_Scope, S_Breakpoint, R_Breakpoint, Remarks, Status, CreatedBy, CreatedDate)
        SELECT @TargetCompanyId, 'BKP' + RIGHT('0000' + CAST(@Base + ROW_NUMBER() OVER (ORDER BY s.Breakpoint_ID) AS NVARCHAR(10)), 4),
               s.Organism_Category, tor.Organism_ID, ta.Antibiotic_ID, s.Standard, s.Standard_Version, s.Method, s.Specimen_Scope,
               s.S_Breakpoint, s.R_Breakpoint, s.Remarks, s.Status, @UserId, GETDATE()
        FROM dbo.LabBreakpointMaster s
        JOIN dbo.LabAntibioticMaster sa ON sa.Antibiotic_ID = s.Antibiotic_ID
        JOIN dbo.LabAntibioticMaster ta ON LOWER(ta.Antibiotic_Name) = LOWER(sa.Antibiotic_Name) AND ta.CompanyId = @TargetCompanyId AND ta.IsDeleted = 0
        LEFT JOIN dbo.LabOrganismMaster so ON so.Organism_ID = s.Organism_ID
        LEFT JOIN dbo.LabOrganismMaster tor ON LOWER(tor.Organism_Name) = LOWER(so.Organism_Name) AND tor.CompanyId = @TargetCompanyId AND tor.IsDeleted = 0
        WHERE s.CompanyId = @SourceCompanyId AND s.IsDeleted = 0
          AND (s.Organism_ID IS NULL OR tor.Organism_ID IS NOT NULL)
          AND NOT EXISTS (SELECT 1 FROM dbo.LabBreakpointMaster x
                          WHERE x.CompanyId = @TargetCompanyId AND x.IsDeleted = 0 AND x.Organism_Category = s.Organism_Category
                            AND x.Antibiotic_ID = ta.Antibiotic_ID AND ISNULL(x.Organism_ID, -1) = ISNULL(tor.Organism_ID, -1)
                            AND x.Standard = s.Standard AND x.Standard_Version = s.Standard_Version
                            AND x.Method = s.Method AND x.Specimen_Scope = s.Specimen_Scope);
        SET @Bkp = @@ROWCOUNT;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT @Org AS OrganismsAdded, @Abx AS AntibioticsAdded, @Pnl AS PanelsAdded, @Rul AS ExpertRulesAdded, @Bkp AS BreakpointsAdded;
END
GO

PRINT 'Microbiology starter kit loader ready.';
