using System.Text.RegularExpressions;
using EMR.Api.Models;

namespace EMR.Api.Services.BulkUpload;

public class FranchiseBulkHandler(ILabFranchiseService service, LabBulkLookups lookups) : ILabBulkUploadHandler
{
    private const string CCode = "Franchise Code";
    private const string CName = "Franchise Name";
    private const string CMobile = "Mobile No";
    private const string CEmail = "Email";
    private const string CType = "Franchise Type";
    private const string CBranch = "Parent Branch";
    private const string COnboarding = "Onboarding Date";
    private const string CGoLive = "Go Live Date";
    private const string CAgrFrom = "Agreement Valid From";
    private const string CAgrTo = "Agreement Valid To";
    private const string CActive = "Is Active";
    private const string CNotify = "Notification Required";
    private const string CBarcode = "Preprinted Barcode";
    private const string CCreditType = "Credit Facility Type";
    private const string CCreditLimit = "Credit Limit";
    private const string CCreditDays = "Credit Days";
    private const string CGrace = "Grace Days";
    private const string CDeposit = "Security Deposit Amount";
    private const string CDepositOn = "Security Deposit Received On";
    private const string CInterest = "Interest On Overdue %";

    private const string RefBranch = "REF_Branch";

    private static readonly string[] FranchiseTypes = ["Collection Center", "Franchise Lab", "Pickup Point", "Marketing"];
    private static readonly string[] CreditTypes = ["Prepaid (Wallet)", "Postpaid (Credit)", "Hybrid"];
    private static readonly Regex MobileRegex = new(@"^[0-9]{10}$", RegexOptions.Compiled);
    private static readonly Regex EmailRegex = new(@"^[^@\s]+@[^@\s]+\.[^@\s]+$", RegexOptions.Compiled);

    public string Module => "franchise";
    public string Title => "Franchise";

    public async Task<BulkTemplate> BuildTemplateAsync(BulkContext ctx, bool withData)
    {
        var branches = await lookups.BranchesAsync(ctx.CompanyId);
        var t = new BulkTemplate
        {
            SheetName = "Franchise",
            Columns =
            [
                new() { Header = CCode, Note = "Leave blank to create a new franchise (code generated, e.g. FRN0003). Fill with an existing code to update it.", Width = 14 },
                new() { Header = CName, Required = true, Note = "Unique. Max 100 characters.", Width = 30 },
                new() { Header = CMobile, Required = true, Note = "Exactly 10 digits.", Width = 15 },
                new() { Header = CEmail, AllowNone = true, Note = "Optional. Max 200 characters.", Width = 26 },
                new() { Header = CType, Required = true, Options = FranchiseTypes, Width = 18 },
                new() { Header = CBranch, Required = true, RefSheet = RefBranch, Note = "Servicing / parent branch.", Width = 22 },
                new() { Header = COnboarding, AllowNone = true, Kind = BulkColumnKind.Date, Width = 14 },
                new() { Header = CGoLive, AllowNone = true, Kind = BulkColumnKind.Date, Width = 14 },
                new() { Header = CAgrFrom, AllowNone = true, Kind = BulkColumnKind.Date, Width = 14 },
                new() { Header = CAgrTo, AllowNone = true, Kind = BulkColumnKind.Date, Note = "Must be on or after Agreement Valid From.", Width = 14 },
                new() { Header = CActive, Options = BulkValues.YesNoOptions, Note = "Default Yes.", Width = 10 },
                new() { Header = CNotify, Options = BulkValues.YesNoOptions, Note = "Send notifications to the patient. Default No.", Width = 12 },
                new() { Header = CBarcode, Options = BulkValues.YesNoOptions, Note = "Default Yes.", Width = 12 },
                new() { Header = CCreditType, Options = CreditTypes, Note = "Default Prepaid (Wallet).", Width = 18 },
                new() { Header = CCreditLimit, Kind = BulkColumnKind.Decimal, Max = 99999999, Note = "0–9,99,99,999. Default 0.", Width = 12 },
                new() { Header = CCreditDays, AllowNone = true, Kind = BulkColumnKind.Integer, Max = 365, Note = "0–365.", Width = 11 },
                new() { Header = CGrace, Kind = BulkColumnKind.Integer, Max = 365, Note = "0–365. Default 0.", Width = 11 },
                new() { Header = CDeposit, AllowNone = true, Kind = BulkColumnKind.Decimal, Max = 99999999, Note = "0–9,99,99,999.", Width = 14 },
                new() { Header = CDepositOn, AllowNone = true, Kind = BulkColumnKind.Date, Width = 14 },
                new() { Header = CInterest, AllowNone = true, Kind = BulkColumnKind.Decimal, Max = 100, Note = "0 – 100.", Width = 12 }
            ],
            RefSheets =
            [
                new() { Name = RefBranch, Headers = ["Select Value", "Branch Code", "Branch Name", "Head Office"],
                        Rows = branches.Items.Select(b => new object?[] { branches.Pick(b), b.Code, b.Name, BulkValues.YesNo(b.IsHO) }).ToList() }
            ],
            Notes = ["Agreement document and suspension are managed on the Franchise screen and are not changed by bulk upload."]
        };

        if (withData)
        {
            var list = await service.GetListAsync(companyId: ctx.CompanyId);
            foreach (var summary in list.OrderBy(f => f.Franchise_Name))
            {
                var f = await service.GetByIdAsync(summary.Franchise_ID) ?? summary;
                var branch = branches.ById(f.Parent_Branch_ID);
                t.DataRows.Add(
                [
                    f.Franchise_Code, f.Franchise_Name, f.Mobile_No, f.Email, TypeName(FranchiseTypes, f.Franchise_Type),
                    branch != null ? branches.Pick(branch) : f.Parent_Branch_Name,
                    f.Onboarding_Date, f.Go_Live_Date, f.Agreement_Valid_From, f.Agreement_Valid_To,
                    BulkValues.YesNo(f.IsActive), BulkValues.YesNo(f.IsNotificationRequired), BulkValues.YesNo(f.PreprintedBarcode),
                    TypeName(CreditTypes, f.Credit_Facility_Type), f.Credit_Limit, f.Credit_Days, f.Grace_Days,
                    f.Security_Deposit_Amount, f.Security_Deposit_Received_On, f.Interest_On_Overdue_Percent
                ]);
            }
        }
        return t;
    }

    private static string? TypeName(string[] names, int value) => value >= 1 && value <= names.Length ? names[value - 1] : null;
    private static int? TypeValue(string[] names, string? name) => name == null ? null : Array.IndexOf(names, name) + 1;

    public async Task ImportAsync(IReadOnlyList<BulkRow> rows, BulkContext ctx, LabBulkUploadResult result)
    {
        var branches = await lookups.BranchesAsync(ctx.CompanyId);
        var existing = (await service.GetListAsync(companyId: ctx.CompanyId)).ToList();
        var byCode = existing.GroupBy(f => f.Franchise_Code, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
        var seenCodes = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var seenNames = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

        foreach (var row in rows)
        {
            var r = new RowReader(row);
            var code = r.Text(CCode);
            LabFranchiseModel? current = null;
            if (code != null)
            {
                if (!byCode.TryGetValue(code, out var summary))
                    r.Fail(CCode, LabBulkUploadRules.NotFound, $"Franchise Code '{code}' does not exist. Leave it blank to create a new franchise.");
                else if (!seenCodes.TryAdd(code, r.RowNo))
                    r.Fail(CCode, LabBulkUploadRules.DuplicateInFile, $"Franchise Code '{code}' is already used in row {seenCodes[code]}.");
                else
                    current = await service.GetByIdAsync(summary.Franchise_ID) ?? summary;
            }
            var isInsert = code == null;

            var name = r.Text(CName, required: isInsert, maxLength: 100);
            var mobile = r.Text(CMobile, required: isInsert, maxLength: 20);
            var email = r.Text(CEmail, maxLength: 200);
            var type = TypeValue(FranchiseTypes, r.Option(CType, FranchiseTypes, required: isInsert));
            var branch = r.Ref(CBranch, branches, required: isInsert, master: "Branch", current: current?.Parent_Branch_Name);
            var onboarding = r.Date(COnboarding);
            var goLive = r.Date(CGoLive);
            var agrFrom = r.Date(CAgrFrom);
            var agrTo = r.Date(CAgrTo);
            var active = r.YesNo(CActive);
            var notify = r.YesNo(CNotify);
            var barcode = r.YesNo(CBarcode);
            var creditType = TypeValue(CreditTypes, r.Option(CCreditType, CreditTypes));
            var creditLimit = r.Decimal(CCreditLimit, max: 99999999);
            var creditDays = r.Int(CCreditDays, min: 0, max: 365);
            var grace = r.Int(CGrace, min: 0, max: 365);
            var deposit = r.Decimal(CDeposit, max: 99999999);
            var depositOn = r.Date(CDepositOn);
            var interest = r.Decimal(CInterest, max: 100);
            r.RecordKey = code ?? name ?? string.Empty;

            if (mobile != null && !MobileRegex.IsMatch(mobile.Replace(" ", "")))
                r.Fail(CMobile, LabBulkUploadRules.InvalidValue, $"Mobile No '{mobile}' must be exactly 10 digits.");
            if (email != null && !EmailRegex.IsMatch(email))
                r.Fail(CEmail, LabBulkUploadRules.InvalidValue, $"Email '{email}' is not a valid email address.");

            if (r.HasErrors || (!isInsert && current == null))
            {
                result.AddFailure(r);
                continue;
            }

            var req = current != null ? ToUpdate(current) : new LabFranchiseUpdateRequestModel { IsActive = true, PreprintedBarcode = true, Credit_Facility_Type = 1 };
            var before = current != null ? ToUpdate(current) : null;
            req.Franchise_Name = name ?? req.Franchise_Name;
            req.Mobile_No = mobile?.Replace(" ", "") ?? req.Mobile_No;
            req.Email = r.IsNone(CEmail) ? null : email ?? req.Email;
            req.Franchise_Type = type ?? req.Franchise_Type;
            req.Parent_Branch_ID = branch?.Id ?? req.Parent_Branch_ID;
            req.Onboarding_Date = r.IsNone(COnboarding) ? null : onboarding ?? req.Onboarding_Date;
            req.Go_Live_Date = r.IsNone(CGoLive) ? null : goLive ?? req.Go_Live_Date;
            req.Agreement_Valid_From = r.IsNone(CAgrFrom) ? null : agrFrom ?? req.Agreement_Valid_From;
            req.Agreement_Valid_To = r.IsNone(CAgrTo) ? null : agrTo ?? req.Agreement_Valid_To;
            req.IsActive = active ?? req.IsActive;
            req.IsNotificationRequired = notify ?? req.IsNotificationRequired;
            req.PreprintedBarcode = barcode ?? req.PreprintedBarcode;
            req.Credit_Facility_Type = creditType ?? req.Credit_Facility_Type;
            req.Credit_Limit = creditLimit ?? req.Credit_Limit;
            req.Credit_Days = r.IsNone(CCreditDays) ? null : creditDays ?? req.Credit_Days;
            req.Grace_Days = grace ?? req.Grace_Days;
            req.Security_Deposit_Amount = r.IsNone(CDeposit) ? null : deposit ?? req.Security_Deposit_Amount;
            req.Security_Deposit_Received_On = r.IsNone(CDepositOn) ? null : depositOn ?? req.Security_Deposit_Received_On;
            req.Interest_On_Overdue_Percent = r.IsNone(CInterest) ? null : interest ?? req.Interest_On_Overdue_Percent;

            if (req.Agreement_Valid_From.HasValue && req.Agreement_Valid_To.HasValue && req.Agreement_Valid_To < req.Agreement_Valid_From)
                r.Fail(CAgrTo, LabBulkUploadRules.InvalidValue, "Agreement Valid To must be on or after Agreement Valid From.");

            var key = req.Franchise_Name.Trim();
            if (seenNames.TryGetValue(key, out var firstRow))
                r.Fail(CName, LabBulkUploadRules.DuplicateInFile, $"Franchise '{key}' is already in row {firstRow}.");
            var clash = existing.FirstOrDefault(f => f.Franchise_ID != current?.Franchise_ID
                && string.Equals(f.Franchise_Name.Trim(), key, StringComparison.OrdinalIgnoreCase));
            if (clash != null)
                r.Fail(CName, LabBulkUploadRules.AlreadyExists, $"Franchise '{key}' already exists with code {clash.Franchise_Code}. Put that code in '{CCode}' to update it.");

            if (r.HasErrors)
            {
                result.AddFailure(r);
                continue;
            }

            seenNames[key] = r.RowNo; // only rows that will be saved claim the name
            if (isInsert)
            {
                await result.SaveRowAsync(r, ctx, true, () => service.CreateAsync(ToCreate(req, ctx)));
            }
            else
            {
                if (BulkValues.SameJson(before, req)) { result.Unchanged++; continue; }
                req.UserId = ctx.UserId;
                await result.SaveRowAsync(r, ctx, false, () => service.UpdateAsync(req));
            }
        }
    }

    private static LabFranchiseUpdateRequestModel ToUpdate(LabFranchiseModel f) => new()
    {
        Franchise_ID = f.Franchise_ID, Franchise_Name = f.Franchise_Name, Mobile_No = f.Mobile_No, Email = f.Email,
        Franchise_Type = f.Franchise_Type, Parent_Branch_ID = f.Parent_Branch_ID, Onboarding_Date = f.Onboarding_Date, Go_Live_Date = f.Go_Live_Date,
        Agreement_Doc_Path = f.Agreement_Doc_Path, Agreement_Valid_From = f.Agreement_Valid_From, Agreement_Valid_To = f.Agreement_Valid_To,
        Status = f.Status, IsActive = f.IsActive, IsNotificationRequired = f.IsNotificationRequired, PreprintedBarcode = f.PreprintedBarcode,
        Credit_Facility_Type = f.Credit_Facility_Type == 0 ? 1 : f.Credit_Facility_Type, Credit_Limit = f.Credit_Limit, Credit_Days = f.Credit_Days,
        Grace_Days = f.Grace_Days, Security_Deposit_Amount = f.Security_Deposit_Amount, Security_Deposit_Received_On = f.Security_Deposit_Received_On,
        Interest_On_Overdue_Percent = f.Interest_On_Overdue_Percent, Temporary_Limit_Increase = f.Temporary_Limit_Increase, Temp_Limit_Valid_Till = f.Temp_Limit_Valid_Till
    };

    private static LabFranchiseCreateRequestModel ToCreate(LabFranchiseUpdateRequestModel u, BulkContext ctx) => new()
    {
        CompanyId = ctx.CompanyId, Franchise_Name = u.Franchise_Name, Mobile_No = u.Mobile_No, Email = u.Email, Franchise_Type = u.Franchise_Type,
        Parent_Branch_ID = u.Parent_Branch_ID, Onboarding_Date = u.Onboarding_Date, Go_Live_Date = u.Go_Live_Date,
        Agreement_Valid_From = u.Agreement_Valid_From, Agreement_Valid_To = u.Agreement_Valid_To, Status = false, IsActive = u.IsActive,
        IsNotificationRequired = u.IsNotificationRequired, PreprintedBarcode = u.PreprintedBarcode, Credit_Facility_Type = u.Credit_Facility_Type,
        Credit_Limit = u.Credit_Limit, Credit_Days = u.Credit_Days, Grace_Days = u.Grace_Days, Security_Deposit_Amount = u.Security_Deposit_Amount,
        Security_Deposit_Received_On = u.Security_Deposit_Received_On, Interest_On_Overdue_Percent = u.Interest_On_Overdue_Percent, UserId = ctx.UserId
    };
}
