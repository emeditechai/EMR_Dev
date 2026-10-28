-- 2338 Company > Remove Branch (super admin): usp_Company_Purge gets @Level = 'BRANCH' + @BranchId.
--   Removes one branch and everything of it (bills, samples, payments, its masters / settings, user access, the branch).
--   Company-wide rows that only point at the branch move to the company's Head Office: patients still used by another
--   branch or on a membership card, doctors created there, franchises under it, cards issued there.
--   The Head Office branch cannot be removed on its own (delete the company instead). Company levels are unchanged.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Company_Purge
    @CompanyId INT,
    @Level     VARCHAR(12),          -- TRANSACTIONS | ALL | DELETE | BRANCH (2338)
    @Preview   BIT = 1,
    @UserId    INT = NULL,           -- the super admin running it (never deleted)
    @BranchId  INT = NULL            -- BRANCH: the branch to remove (its company is taken from it)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;              -- a refused delete (FK) is retried later in the same transaction
    SET @Level = UPPER(LTRIM(RTRIM(ISNULL(@Level, ''))));

    IF @Level NOT IN ('TRANSACTIONS', 'ALL', 'DELETE', 'BRANCH') BEGIN RAISERROR('Choose what to remove.', 16, 1); RETURN; END

    -- ── BRANCH (2338): one branch and all its data; company-wide rows that only point at it move to the Head Office ──
    DECLARE @isBr BIT = CASE WHEN @Level = 'BRANCH' THEN 1 ELSE 0 END, @HO INT;
    IF @isBr = 1
    BEGIN
        SELECT @CompanyId = CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId;
        IF @CompanyId IS NULL BEGIN RAISERROR('Branch not found.', 16, 1); RETURN; END
        IF EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId AND IsHOBranch = 1)
        BEGIN RAISERROR('The Head Office branch holds the company''s settings and cannot be removed on its own - delete the company instead.', 16, 1); RETURN; END
        SET @HO = (SELECT TOP 1 BranchID FROM dbo.Branchmaster WHERE CompanyId = @CompanyId AND IsHOBranch = 1 AND BranchID <> @BranchId ORDER BY BranchID);
        IF @HO IS NULL BEGIN RAISERROR('The company has no other Head Office branch to keep its shared records - delete the company instead.', 16, 1); RETURN; END
    END
    ELSE IF ISNULL(@CompanyId, 0) <= 1
    BEGIN RAISERROR('The primary company (ID 1) holds the data shared by every company and cannot be cleared or deleted.', 16, 1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM dbo.CompanyMaster WHERE CompanyId = @CompanyId) BEGIN RAISERROR('Company not found.', 16, 1); RETURN; END
    IF @UserId IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @UserId AND CompanyId = @CompanyId) AND @Level IN ('ALL', 'DELETE')
    BEGIN RAISERROR('You belong to this company - sign in with a super admin of another company to remove it.', 16, 1); RETURN; END

    DECLARE @Co INT = @CompanyId, @all BIT = CASE WHEN @Level IN ('ALL', 'DELETE') THEN 1 ELSE 0 END;

    -- ── keys read before anything is deleted ──
    CREATE TABLE #br  (Id INT PRIMARY KEY);
    CREATE TABLE #lo  (Id INT PRIMARY KEY);
    CREATE TABLE #ops (Id INT PRIMARY KEY);
    CREATE TABLE #inv (Id INT PRIMARY KEY);
    CREATE TABLE #tpl (Id INT PRIMARY KEY);
    IF @isBr = 1 INSERT #br VALUES (@BranchId);
    ELSE INSERT #br SELECT BranchID FROM dbo.Branchmaster WHERE CompanyId = @Co;
    INSERT #lo  SELECT LabOrderId FROM dbo.LabOrder WHERE BranchId IN (SELECT Id FROM #br);
    INSERT #ops SELECT OPDServiceId FROM dbo.PatientOPDService
                 WHERE BranchId IN (SELECT Id FROM #br) OR (@isBr = 0 AND ISNULL(BranchId, 0) = 0 AND CompanyId = @Co);
    IF @all = 1
    BEGIN
        INSERT #inv SELECT Test_ID FROM dbo.LabInvestigationMaster WHERE CompanyId = @Co;
        INSERT #tpl SELECT TemplateId FROM dbo.PrintTemplate WHERE CompanyId = @Co;
    END

    -- ── shared by all companies: never deleted ──
    DECLARE @global TABLE (T SYSNAME PRIMARY KEY);
    INSERT @global VALUES ('CompanyMaster'), ('roles'), ('RolePermission'), ('MenuMaster'), ('PageMaster'), ('PageControlMaster'),
        ('PageEndpointMap'), ('PermissionAuditLog'), ('PermissionControlVocabulary'), ('DoctorSpecialityMaster'), ('DoctorSubSpecialityMaster'),
        ('DepartmentMaster'), ('LabUnitMaster'), ('PaymentMethodMaster'), ('HelpAskLog'), ('HelpFeedback'), ('HelpLearned'), ('HelpSignalLog'),
        ('HelpArticle'), ('HelpLearningRun'), ('DataProtectionKeys'), ('__EFMigrationsHistory');

    -- ── transactions (level TRANSACTIONS; ALL takes every company table anyway) ──
    DECLARE @txn TABLE (T SYSNAME PRIMARY KEY);
    INSERT @txn VALUES ('Acc_Attachment'), ('Acc_LedgerTransaction'), ('Acc_PettyExpense'), ('Acc_Voucher'), ('Acc_VoucherSequence'),
        ('ApiRefreshToken'), ('ApprovalRequest'), ('AuditLogs'), ('AuthorizationDecisionLog'), ('B2BInvoice'), ('Campaign'), ('CampaignOptOut'),
        ('CancellationSequence'), ('CashClosing'), ('Doctor_IP_Commission_Hdr'), ('Doctor_IP_Commission_RunLog'), ('DoctorBillingAdjustment'),
        ('DoctorDisbursal'), ('DoctorIpAccessLog'), ('DoctorSettlement'), ('EmailLogs'), ('EmrPatientConsultation'), ('IqcRun'),
        ('LabAiSuggestionFeedback'), ('LabBarcodeSequence'), ('LabCriticalCommunication'), ('LabFranchiseWalletTransaction'), ('LabOrder'),
        ('LabOutsourceTracking'), ('LabReflexRecommendation'), ('LabReportApproval'), ('LabReportEmailLog'), ('LabReportWhatsAppLog'),
        ('LabSampleStatusLog'), ('MembershipCard'), ('MembershipLedger'), ('MembershipPointsWhatsAppLog'), ('MembershipRedeemOtp'),
        ('OPDBillSequence'), ('OPDTokenSequence'), ('PatientCodeCounter'), ('PatientMaster'), ('PatientOPDService'), ('PatientOPDServiceItem'),
        ('PatientVitals'), ('PaymentDetail'), ('PaymentHeader'), ('PaymentLineItem'), ('QcCapa'), ('QcConsumption'), ('ReceiptSequence'),
        ('SampleCollection'), ('tbl_VideoConsultation'), ('UserNotification'), ('WhatsAppLog'), ('UserBranchLastLogin');

    -- ── the plan: table + the rows to delete ──
    DECLARE @plan TABLE (Seq INT IDENTITY PRIMARY KEY, Sch SYSNAME DEFAULT 'dbo', Tbl SYSNAME, Pred NVARCHAR(MAX), Done BIT DEFAULT 0, Rows INT DEFAULT 0, Err NVARCHAR(2048));

    -- company / branch tables
    INSERT @plan (Sch, Tbl, Pred)
    SELECT SCHEMA_NAME(t.schema_id), t.name,
           CASE WHEN @isBr = 1 THEN QUOTENAME(b.name) + N' IN (SELECT Id FROM #br)'   -- a branch: only rows of that branch
                WHEN b.name IS NOT NULL AND co.name IS NOT NULL
                    THEN N'(' + QUOTENAME(b.name) + N' IN (SELECT Id FROM #br) OR (ISNULL(' + QUOTENAME(b.name) + N', 0) = 0 AND CompanyId = @Co))'
                WHEN b.name IS NOT NULL THEN QUOTENAME(b.name) + N' IN (SELECT Id FROM #br)'
                ELSE N'CompanyId = @Co' END
           + CASE WHEN t.name = 'Users' THEN N' AND Id <> ISNULL(@UserId, 0)' ELSE N'' END
      FROM sys.tables t
      OUTER APPLY (SELECT TOP 1 c.name FROM sys.columns c WHERE c.object_id = t.object_id AND c.name IN ('BranchId', 'BranchID', 'Branch_ID')) b
      OUTER APPLY (SELECT TOP 1 c.name FROM sys.columns c WHERE c.object_id = t.object_id AND c.name = 'CompanyId') co
     WHERE (b.name IS NOT NULL OR (co.name IS NOT NULL AND @isBr = 0))
       AND t.name NOT IN (SELECT T FROM @global)
       AND (@all = 1 OR @isBr = 1 OR t.name IN (SELECT T FROM @txn));
    -- a removed branch's own role grants go with it (the grants of every other branch stay)
    IF @isBr = 1 INSERT @plan (Tbl, Pred) VALUES ('RolePermission', N'Branch_ID IN (SELECT Id FROM #br)');

    -- links without a foreign key (keys read above)
    INSERT @plan (Tbl, Pred) VALUES
        ('LabReportTestRemarks', N'LabOrderId IN (SELECT Id FROM #lo)'),
        ('LabReportUnapproval',  N'LabOrderId IN (SELECT Id FROM #lo)'),
        ('SampleTransferAudit',  N'LabOrderId IN (SELECT Id FROM #lo)'),
        ('QcConsumptionLog',     N'LabOrderId IN (SELECT Id FROM #lo)'),
        ('OPDTokenStatusLog',    N'OPDServiceId IN (SELECT Id FROM #ops)'),
        ('BillingSubmission',    N'(ModuleCode = ''LAB'' AND ModuleRefId IN (SELECT Id FROM #lo)) OR (ModuleCode = ''OPD'' AND ModuleRefId IN (SELECT Id FROM #ops))'),
        ('BillRefund',           N'(ModuleCode = ''LAB'' AND ModuleRefId IN (SELECT Id FROM #lo)) OR (ModuleCode = ''OPD'' AND ModuleRefId IN (SELECT Id FROM #ops))'),
        ('BillCancellation',     N'(ModuleCode = ''LAB'' AND ModuleRefId IN (SELECT Id FROM #lo)) OR (ModuleCode = ''OPD'' AND ModuleRefId IN (SELECT Id FROM #ops))'),
        ('Acc_PettyCashClosing', N'CounterId IN (SELECT CounterId FROM dbo.Acc_PettyCashCounter WHERE ' + CASE WHEN @isBr = 1 THEN N'BranchId IN (SELECT Id FROM #br)' ELSE N'CompanyId = @Co' END + N')'),
        ('Acc_PettyCashFloat',   N'CounterId IN (SELECT CounterId FROM dbo.Acc_PettyCashCounter WHERE ' + CASE WHEN @isBr = 1 THEN N'BranchId IN (SELECT Id FROM #br)' ELSE N'CompanyId = @Co' END + N')');
    IF @all = 1
        INSERT @plan (Sch, Tbl, Pred) VALUES
            ('Terminology', 'MappingAudit', N'InvestigationId IN (SELECT Id FROM #inv)'),
            ('dbo', 'PrintTemplateVersion', N'TemplateId IN (SELECT Id FROM #tpl)');

    -- child tables through foreign keys (only tables without their own company / branch; repeated for grandchildren)
    DECLARE @added INT = 1, @depth INT = 0;
    WHILE @added > 0 AND @depth < 8
    BEGIN
        INSERT @plan (Sch, Tbl, Pred)
        SELECT DISTINCT SCHEMA_NAME(ch.schema_id), ch.name,
               QUOTENAME(cc.name) + N' IN (SELECT ' + QUOTENAME(pc.name) + N' FROM ' + QUOTENAME(p.Sch) + N'.' + QUOTENAME(p.Tbl) + N' WHERE ' + p.Pred + N')'
          FROM @plan p
          JOIN sys.tables pt ON pt.name = p.Tbl AND SCHEMA_NAME(pt.schema_id) = p.Sch
          JOIN sys.foreign_keys fk ON fk.referenced_object_id = pt.object_id
          JOIN sys.foreign_key_columns k ON k.constraint_object_id = fk.object_id
          JOIN sys.tables ch ON ch.object_id = fk.parent_object_id
          JOIN sys.columns cc ON cc.object_id = k.parent_object_id AND cc.column_id = k.parent_column_id
          JOIN sys.columns pc ON pc.object_id = k.referenced_object_id AND pc.column_id = k.referenced_column_id
         WHERE (SELECT COUNT(*) FROM sys.foreign_key_columns x WHERE x.constraint_object_id = fk.object_id) = 1
           AND ch.object_id <> pt.object_id
           AND ch.name NOT IN (SELECT T FROM @global)
           -- a child with its own branch is judged by that branch (another company's row stops the run); a child with only a
           -- CompanyId follows its parent (that stamp was often left at the default 1)
           AND NOT EXISTS (SELECT 1 FROM sys.columns x WHERE x.object_id = ch.object_id AND x.name IN ('BranchId', 'BranchID', 'Branch_ID'))
           AND NOT EXISTS (SELECT 1 FROM @plan q WHERE q.Tbl = ch.name
                             AND q.Pred = QUOTENAME(cc.name) + N' IN (SELECT ' + QUOTENAME(pc.name) + N' FROM ' + QUOTENAME(p.Sch) + N'.' + QUOTENAME(p.Tbl) + N' WHERE ' + p.Pred + N')');
        SET @added = @@ROWCOUNT;
        SET @depth += 1;
    END

    -- children first: a table's level is one more than the deepest of its children in the plan (so rows a cascading
    -- foreign key would remove are deleted - and counted - before their parent)
    CREATE TABLE #lvl (Sch SYSNAME, Tbl SYSNAME, L INT NOT NULL DEFAULT 0, PRIMARY KEY (Sch, Tbl));
    INSERT #lvl (Sch, Tbl) SELECT DISTINCT Sch, Tbl FROM @plan;
    DECLARE @lv INT = 0;
    WHILE @lv < 25
    BEGIN
        UPDATE p SET L = x.mx + 1
          FROM #lvl p
         CROSS APPLY (SELECT MAX(c.L) AS mx
                        FROM sys.foreign_keys fk
                        JOIN #lvl c ON fk.parent_object_id = OBJECT_ID(QUOTENAME(c.Sch) + '.' + QUOTENAME(c.Tbl))
                       WHERE fk.referenced_object_id = OBJECT_ID(QUOTENAME(p.Sch) + '.' + QUOTENAME(p.Tbl))
                         AND fk.parent_object_id <> fk.referenced_object_id) x
         WHERE x.mx IS NOT NULL AND p.L < x.mx + 1 AND x.mx < 25;
        IF @@ROWCOUNT = 0 BREAK;
        SET @lv += 1;
    END

    DECLARE @seq INT, @sch SYSNAME, @tbl SYSNAME, @pred NVARCHAR(MAX), @sql NVARCHAR(MAX), @progress BIT = 1, @pass INT = 0, @n INT;

    BEGIN TRY
    BEGIN TRANSACTION;

    -- transactions removed: franchise barcodes used by them are free again, wallets restart at zero
    UPDATE dbo.LabFranchiseBarcodePool
       SET Status = 1, LabOrderId = NULL, SamplecollectionID = NULL, InvestigationId = NULL, UsedDate = NULL, UsedBy = NULL
     WHERE LabOrderId IN (SELECT Id FROM #lo);
    -- a branch: company-wide records that only point at it move to the Head Office (patients still used elsewhere or on a
    -- membership card, doctors created there, franchises under it, cards issued there)
    IF @isBr = 1
    BEGIN
        DECLARE @mv INT, @ps NVARCHAR(MAX) = N'';
        UPDATE dbo.DoctorMaster SET CreatedBranchId = @HO WHERE CreatedBranchId = @BranchId;
        SET @mv = @@ROWCOUNT; IF @mv > 0 INSERT @plan (Tbl, Pred, Done, Rows) VALUES (N'DoctorMaster (moved to Head Office)', N'', 1, @mv);
        UPDATE dbo.LabFranchiseMaster SET Parent_Branch_ID = @HO WHERE Parent_Branch_ID = @BranchId;
        SET @mv = @@ROWCOUNT; IF @mv > 0 INSERT @plan (Tbl, Pred, Done, Rows) VALUES (N'LabFranchiseMaster (moved to Head Office)', N'', 1, @mv);
        UPDATE dbo.MembershipCard SET IssueBranchId = @HO WHERE IssueBranchId = @BranchId;
        SET @mv = @@ROWCOUNT; IF @mv > 0 INSERT @plan (Tbl, Pred, Done, Rows) VALUES (N'MembershipCard (moved to Head Office)', N'', 1, @mv);
        -- patients of this branch that another branch's rows (any table with a branch and a PatientId) or a card still use
        CREATE TABLE #keepPat (Id INT PRIMARY KEY);
        SELECT @ps = @ps + N' UNION SELECT x.' + QUOTENAME(pc.name) + N' FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
                   + N' x WHERE ISNULL(x.' + QUOTENAME(bc.name) + N', 0) <> @B AND x.' + QUOTENAME(pc.name) + N' IS NOT NULL'
          FROM sys.tables t
          CROSS APPLY (SELECT TOP 1 c.name FROM sys.columns c WHERE c.object_id = t.object_id AND c.name IN ('PatientId', 'PatientID')) pc
          CROSS APPLY (SELECT TOP 1 c.name FROM sys.columns c WHERE c.object_id = t.object_id AND c.name IN ('BranchId', 'BranchID', 'Branch_ID')) bc
         WHERE t.name <> 'PatientMaster';
        SET @ps = N'INSERT #keepPat SELECT p.PatientId FROM dbo.PatientMaster p WHERE p.BranchId = @B AND p.PatientId IN (SELECT PatientId FROM dbo.MembershipCardMember'
                + @ps + N')';
        EXEC sp_executesql @ps, N'@B INT', @BranchId;
        UPDATE dbo.PatientMaster SET BranchId = @HO WHERE PatientId IN (SELECT Id FROM #keepPat);
        SET @mv = @@ROWCOUNT; IF @mv > 0 INSERT @plan (Tbl, Pred, Done, Rows) VALUES (N'PatientMaster (moved to Head Office)', N'', 1, @mv);
    END

    IF @all = 0 AND @isBr = 0
        UPDATE w SET CurrentBalance = 0, LastUpdatedDate = GETDATE()
          FROM dbo.LabFranchiseWallet w JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = w.Franchise_ID WHERE f.CompanyId = @Co;

    -- delete until nothing more can go: a table whose rows are still referenced waits for its children
    WHILE @progress = 1 AND @pass < 30
    BEGIN
        SET @progress = 0; SET @pass += 1;
        DECLARE pc CURSOR LOCAL STATIC FOR SELECT p.Seq, p.Sch, p.Tbl, p.Pred FROM @plan p JOIN #lvl l ON l.Sch = p.Sch AND l.Tbl = p.Tbl WHERE p.Done = 0 ORDER BY l.L, p.Seq;
        OPEN pc; FETCH NEXT FROM pc INTO @seq, @sch, @tbl, @pred;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @sql = N'DELETE FROM ' + QUOTENAME(@sch) + N'.' + QUOTENAME(@tbl) + N' WHERE ' + @pred + N'; SET @n = @@ROWCOUNT;';
            BEGIN TRY
                EXEC sp_executesql @sql, N'@Co INT, @UserId INT, @n INT OUTPUT', @Co, @UserId, @n OUTPUT;
                UPDATE @plan SET Done = 1, Rows = Rows + @n, Err = NULL WHERE Seq = @seq;
                SET @progress = 1;
            END TRY
            BEGIN CATCH
                IF ERROR_NUMBER() <> 547 OR XACT_STATE() <> 1 THROW;    -- only "still referenced" is retried
                UPDATE @plan SET Err = ERROR_MESSAGE() WHERE Seq = @seq;
            END CATCH
            FETCH NEXT FROM pc INTO @seq, @sch, @tbl, @pred;
        END
        CLOSE pc; DEALLOCATE pc;
    END

    IF EXISTS (SELECT 1 FROM @plan WHERE Done = 0)
    BEGIN
        DECLARE @blocked NVARCHAR(2000) = (SELECT STRING_AGG(Tbl, ', ') FROM (SELECT DISTINCT TOP 10 Tbl FROM @plan WHERE Done = 0) x);
        DECLARE @why NVARCHAR(2048) = (SELECT TOP 1 Err FROM @plan WHERE Done = 0 AND Err IS NOT NULL ORDER BY Seq);
        ROLLBACK TRANSACTION;
        RAISERROR('Nothing was removed: rows of %s are still used by data outside this company. %s', 16, 1, @blocked, @why);
        RETURN;
    END

    IF @Level = 'DELETE'
    BEGIN
        DELETE FROM dbo.CompanyMaster WHERE CompanyId = @Co;
        INSERT @plan (Tbl, Pred, Done, Rows) VALUES ('CompanyMaster', N'CompanyId = @Co', 1, @@ROWCOUNT);
    END

    IF @Preview = 1 ROLLBACK TRANSACTION; ELSE COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    -- what was (or would be) removed, per table
    SELECT Tbl AS TableName, SUM(Rows) AS Rows
      FROM @plan GROUP BY Tbl HAVING SUM(Rows) > 0 ORDER BY Tbl;
END
GO

PRINT 'Script 2338 applied: Company > Remove Branch.';
GO
