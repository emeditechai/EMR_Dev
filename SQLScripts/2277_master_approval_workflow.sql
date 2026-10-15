/* =====================================================================================================
   2277 - Master approval workflow (maker / checker) for Franchise Setup, Corporate Master and
          Investigation Profile / Package.

   - ApprovalModule          : the masters that can be put under approval
   - ApprovalMatrix          : per company and module, either company-wise (Scope 'C', approved in the
                               head-office branch) or branch-wise (Scope 'B', approved in that branch)
   - ApprovalMatrixApprover  : who approves - system users (User_Type U) holding a Manager role;
                               branch-wise approvers must also work in that branch (UserBranches)
   - ApprovalRequest         : one row per submitted change, with the old and new values
                               Status P = pending, A = approved, S = sent back, X = replaced by a newer submission

   With no active matrix for a module, saving works as before (no approval).
   A new record under approval is saved inactive and becomes active only on approval, so it is not
   offered in B2B rates or billing before that. A change to an approved record is held in the request
   and applied only on approval.

   Pages: Settings > Approval Matrix (SETTINGS.APPROVALMATRIX), Utility > Approval Dashboard
   (UTILITY.APPROVALDASHBOARD, granted to Manager roles).
   ===================================================================================================== */
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.ApprovalModule', 'U') IS NULL
CREATE TABLE dbo.ApprovalModule
(
    Module_Code  VARCHAR(40)   NOT NULL CONSTRAINT PK_ApprovalModule PRIMARY KEY,
    Module_Name  NVARCHAR(100) NOT NULL,
    Sort_Order   INT           NOT NULL CONSTRAINT DF_ApprovalModule_Sort DEFAULT (0),
    IsActive     BIT           NOT NULL CONSTRAINT DF_ApprovalModule_IsActive DEFAULT (1)
);
GO

MERGE dbo.ApprovalModule AS t
USING (VALUES ('LAB.FRANCHISE',    N'Franchise Setup',                  10),
              ('MASTER.CORPORATE', N'Corporate Master',                 20),
              ('LAB.PACKAGE',      N'Investigation Profile / Package',  30)) AS s (Module_Code, Module_Name, Sort_Order)
   ON t.Module_Code = s.Module_Code
WHEN MATCHED THEN UPDATE SET Module_Name = s.Module_Name, Sort_Order = s.Sort_Order
WHEN NOT MATCHED THEN INSERT (Module_Code, Module_Name, Sort_Order) VALUES (s.Module_Code, s.Module_Name, s.Sort_Order);
GO

IF OBJECT_ID('dbo.ApprovalMatrix', 'U') IS NULL
CREATE TABLE dbo.ApprovalMatrix
(
    Matrix_ID     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ApprovalMatrix PRIMARY KEY,
    CompanyId     INT          NOT NULL,
    Module_Code   VARCHAR(40)  NOT NULL CONSTRAINT FK_ApprovalMatrix_Module REFERENCES dbo.ApprovalModule (Module_Code),
    Scope         CHAR(1)      NOT NULL CONSTRAINT CK_ApprovalMatrix_Scope CHECK (Scope IN ('C', 'B')),
    Branch_ID     INT          NULL,
    IsActive      BIT          NOT NULL CONSTRAINT DF_ApprovalMatrix_IsActive DEFAULT (1),
    CreatedBy     INT          NULL,
    CreatedDate   DATETIME     NOT NULL CONSTRAINT DF_ApprovalMatrix_Created DEFAULT (GETDATE()),
    ModifiedBy    INT          NULL,
    ModifiedDate  DATETIME     NULL,
    CONSTRAINT CK_ApprovalMatrix_Branch CHECK ((Scope = 'C' AND Branch_ID IS NULL) OR (Scope = 'B' AND Branch_ID IS NOT NULL))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_ApprovalMatrix_Active')
    CREATE UNIQUE INDEX UX_ApprovalMatrix_Active ON dbo.ApprovalMatrix (CompanyId, Module_Code, Scope, Branch_ID) WHERE IsActive = 1;
GO

IF OBJECT_ID('dbo.ApprovalMatrixApprover', 'U') IS NULL
CREATE TABLE dbo.ApprovalMatrixApprover
(
    Matrix_ID    INT      NOT NULL CONSTRAINT FK_ApprovalMatrixApprover_Matrix REFERENCES dbo.ApprovalMatrix (Matrix_ID),
    UserId       INT      NOT NULL,
    CreatedBy    INT      NULL,
    CreatedDate  DATETIME NOT NULL CONSTRAINT DF_ApprovalMatrixApprover_Created DEFAULT (GETDATE()),
    CONSTRAINT PK_ApprovalMatrixApprover PRIMARY KEY (Matrix_ID, UserId)
);
GO

IF OBJECT_ID('dbo.ApprovalRequest', 'U') IS NULL
CREATE TABLE dbo.ApprovalRequest
(
    Request_ID      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ApprovalRequest PRIMARY KEY,
    CompanyId       INT            NOT NULL,
    Branch_ID       INT            NOT NULL,          -- branch the record belongs to (branch-wise approval is shown there)
    Matrix_ID       INT            NOT NULL CONSTRAINT FK_ApprovalRequest_Matrix REFERENCES dbo.ApprovalMatrix (Matrix_ID),
    Scope           CHAR(1)        NOT NULL,          -- copied from the matrix when submitted
    Module_Code     VARCHAR(40)    NOT NULL,
    Entity_ID       INT            NOT NULL,
    Entity_Name     NVARCHAR(200)  NULL,
    Action_Type     VARCHAR(10)    NOT NULL CONSTRAINT CK_ApprovalRequest_Action CHECK (Action_Type IN ('CREATE', 'UPDATE')),
    Requested_Active BIT           NULL,              -- CREATE: the active flag to set on approval
    Old_Values      NVARCHAR(MAX)  NULL,              -- [{"Field":..,"Value":..}] for display
    New_Values      NVARCHAR(MAX)  NULL,
    Payload         NVARCHAR(MAX)  NULL,              -- UPDATE: the save request applied on approval
    Status          CHAR(1)        NOT NULL CONSTRAINT DF_ApprovalRequest_Status DEFAULT ('P')
                                   CONSTRAINT CK_ApprovalRequest_Status CHECK (Status IN ('P', 'A', 'S', 'X')),
    Requested_By    INT            NOT NULL,
    Requested_Date  DATETIME       NOT NULL CONSTRAINT DF_ApprovalRequest_Requested DEFAULT (GETDATE()),
    Actioned_By     INT            NULL,
    Actioned_Date   DATETIME       NULL,
    Remarks         NVARCHAR(500)  NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ApprovalRequest_Entity')
    CREATE INDEX IX_ApprovalRequest_Entity ON dbo.ApprovalRequest (Module_Code, Entity_ID, Status);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ApprovalRequest_Company')
    CREATE INDEX IX_ApprovalRequest_Company ON dbo.ApprovalRequest (CompanyId, Status, Requested_Date);
GO

-- ── Pages ───────────────────────────────────────────────────────────────────────────────────────────
DECLARE @co INT, @settings INT, @utility INT, @page INT, @p INT, @role INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @settings = NULL; SET @utility = NULL;
    SELECT @settings = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'SETTINGS' AND CompanyId = @co;
    SELECT @utility  = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'UTILITY'  AND CompanyId = @co;

    IF @settings IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @settings, @Page_Code = N'SETTINGS.APPROVALMATRIX', @Title = N'Approval Matrix',
             @Controller = N'ApprovalMatrix', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 61, @Icon = N'bi bi-ui-checks-grid me-2 text-primary',
             @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'ApprovalMatrix', @Action = N'Index',     @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'ApprovalMatrix', @Action = N'Approvers', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'ApprovalMatrix', @Action = N'Save',      @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'ApprovalMatrix', @Action = N'Remove',    @Source = 'SEED';
    END

    IF @utility IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @utility, @Page_Code = N'UTILITY.APPROVALDASHBOARD', @Title = N'Approval Dashboard',
             @Controller = N'ApprovalDashboard', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 46, @Icon = N'bi bi-clipboard-check me-2',
             @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'ApprovalDashboard', @Action = N'Index',    @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'ApprovalDashboard', @Action = N'Data',     @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'ApprovalDashboard', @Action = N'Detail',   @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'ApprovalDashboard', @Action = N'Approve',  @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'ApprovalDashboard', @Action = N'SendBack', @Source = 'SEED';

        -- every Manager role may open the dashboard (the approver list decides what they can act on)
        DECLARE rr CURSOR LOCAL FAST_FORWARD FOR
            SELECT Id FROM dbo.Roles WHERE Name LIKE N'%Manager%' AND ISNULL(CompanyId, @co) = @co;
        OPEN rr; FETCH NEXT FROM rr INTO @role;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_RolePermission_Upsert @Role_ID = @role, @Page_ID = @page, @Permission = 'A', @CompanyId = @co,
                 @Reason = N'Approvers act on master changes (script 2277)';
            FETCH NEXT FROM rr INTO @role;
        END
        CLOSE rr; DEALLOCATE rr;
    END

    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
