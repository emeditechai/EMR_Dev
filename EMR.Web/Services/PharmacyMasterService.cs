using System.Data;
using System.Globalization;
using System.Text.RegularExpressions;
using Dapper;
using EMR.Web.Data;
using Microsoft.Data.SqlClient;

namespace EMR.Web.Services;

// Master > Pharmacy Master (SQLScripts/2343). Company-wise masters; Number Series is branch-wise; Drug Schedule is statutory.
// The simple masters are described once (PharmacyMasterDefs) and share one list + dialog page; the Item Master has its own page.

public record PhOption(string Value, string Text);

public class PhField
{
    public string Name { get; init; } = "";
    public string Label { get; init; } = "";
    public string Kind { get; init; } = "text";        // text | number | decimal | bool | select | date | textarea | readonly
    public bool Required { get; init; }
    public int Max { get; init; } = 150;
    public int Col { get; init; } = 6;
    public bool InList { get; init; } = true;
    public string? Lookup { get; init; }               // key into the lookups for select fields
    public PhOption[]? Options { get; init; }
    public string? Pattern { get; init; }              // regex the value must match (when filled)
    public string? PatternMessage { get; init; }
    public string? Placeholder { get; init; }
    public string? Help { get; init; }
    public bool Upper { get; init; }
    public object? Default { get; init; }
}

public class PhMasterDef
{
    public string Key { get; init; } = "";
    public string PageCode { get; init; } = "";
    public string Title { get; init; } = "";
    public string Singular { get; init; } = "";
    public string Icon { get; init; } = "";
    public string Description { get; init; } = "";
    public string Table { get; init; } = "";
    public string IdCol { get; init; } = "";
    public string OrderBy { get; init; } = "";
    public string SaveAction { get; init; } = "";
    public bool BranchScoped { get; init; }
    public bool ReadOnly { get; init; }
    public bool NoAdd { get; init; }
    public PhField[] Fields { get; init; } = [];
}

public static class PharmacyMasterDefs
{
    public static readonly PhOption[] PatientTypes =
    [
        new("WALKIN", "Walk-in (counter sale)"), new("IPD_CASH", "IPD - Cash"), new("IPD_INSURANCE", "IPD - Insurance / TPA"),
        new("IPD_CORPORATE", "IPD - Corporate"), new("IPD_SCHEME", "IPD - Govt. scheme"), new("STAFF", "Staff")
    ];
    public static readonly PhOption[] CustomerTypes = [new("REGULAR", "Regular"), new("STAFF", "Staff"), new("CORPORATE", "Corporate"), new("DOCTOR", "Doctor")];
    public static readonly PhOption[] ReasonTypes =
    [
        new("SALE_RETURN", "Sale return"), new("IPD_RETURN", "IPD / ward return"), new("PURCHASE_RETURN", "Purchase return"),
        new("ADJUSTMENT", "Stock adjustment / write-off"), new("CANCEL", "Bill cancellation")
    ];

    private const string GstinRx = "^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$";

    public static readonly PhMasterDef[] All =
    [
        new()
        {
            Key = "generics", PageCode = "MASTER.PH_GENERICS", Title = "Generic / Molecule", Singular = "generic", Icon = "bi-diagram-3", SaveAction = "SaveGeneric",
            Description = "Salt / composition of a medicine. Items of the same generic are offered as substitutes at sale and IPD issue.",
            Table = "PhGeneric", IdCol = "GenericId", OrderBy = "GenericName",
            Fields =
            [
                new() { Name = "GenericName", Label = "Generic name / composition", Required = true, Max = 250, Col = 8, Placeholder = "e.g. Amoxicillin 500 mg + Clavulanic Acid 125 mg" },
                new() { Name = "TherapeuticClass", Label = "Therapeutic class", Max = 100, Col = 4, Placeholder = "e.g. Penicillin antibiotic" }
            ]
        },
        new()
        {
            Key = "manufacturers", PageCode = "MASTER.PH_MANUFACTURERS", Title = "Manufacturer", Singular = "manufacturer", Icon = "bi-building-gear", SaveAction = "SaveManufacturer",
            Description = "Company that makes or markets the product (printed on the pack).",
            Table = "PhManufacturer", IdCol = "ManufacturerId", OrderBy = "ManufacturerName",
            Fields =
            [
                new() { Name = "ManufacturerName", Label = "Manufacturer name", Required = true, Col = 8 },
                new() { Name = "ShortCode", Label = "Short code", Max = 20, Col = 4, Upper = true },
                new() { Name = "Address", Label = "Address", Kind = "textarea", Max = 300, Col = 12, InList = false }
            ]
        },
        new()
        {
            Key = "suppliers", PageCode = "MASTER.PH_SUPPLIERS", Title = "Supplier / Distributor", Singular = "supplier", Icon = "bi-truck", SaveAction = "SaveSupplier",
            Description = "Distributors you buy from. GSTIN state decides CGST + SGST or IGST on purchase; a GRN warns when the supplier's drug licence has expired.",
            Table = "PhSupplier", IdCol = "SupplierId", OrderBy = "SupplierName",
            Fields =
            [
                new() { Name = "SupplierCode", Label = "Code", Max = 20, Col = 3, Upper = true, Placeholder = "auto", Help = "Leave empty to number automatically." },
                new() { Name = "SupplierName", Label = "Supplier name", Required = true, Col = 9 },
                new() { Name = "ContactPerson", Label = "Contact person", Max = 100, Col = 4, InList = false },
                new() { Name = "Phone", Label = "Phone", Max = 30, Col = 4, Pattern = "^[0-9+\\- ]{6,30}$", PatternMessage = "Phone: digits, +, - and spaces only." },
                new() { Name = "Email", Label = "E-mail", Max = 150, Col = 4, InList = false, Pattern = "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", PatternMessage = "E-mail is not valid." },
                new() { Name = "Address", Label = "Address", Kind = "textarea", Max = 300, Col = 12, InList = false },
                new() { Name = "City", Label = "City", Max = 80, Col = 4 },
                new() { Name = "StateId", Label = "State", Kind = "select", Lookup = "states", Col = 4 },
                new() { Name = "Pincode", Label = "Pincode", Max = 10, Col = 4, InList = false, Pattern = "^[0-9]{6}$", PatternMessage = "Pincode: 6 digits." },
                new() { Name = "Gstin", Label = "GSTIN", Max = 15, Col = 4, Upper = true, Pattern = GstinRx, PatternMessage = "GSTIN is not in the 15-character format." },
                new() { Name = "Pan", Label = "PAN", Max = 10, Col = 4, Upper = true, InList = false, Pattern = "^[A-Z]{5}[0-9]{4}[A-Z]$", PatternMessage = "PAN is not valid (ABCDE1234F)." },
                new() { Name = "CreditDays", Label = "Credit days", Kind = "number", Col = 4, Default = 30 },
                new() { Name = "DrugLicenceNo", Label = "Drug licence no(s). (20B / 21B)", Max = 100, Col = 8 },
                new() { Name = "DrugLicenceValidTo", Label = "Licence valid to", Kind = "date", Col = 4 },
                new() { Name = "BankName", Label = "Bank", Max = 100, Col = 4, InList = false },
                new() { Name = "BankAccountNo", Label = "Account no.", Max = 30, Col = 4, InList = false },
                new() { Name = "BankIfsc", Label = "IFSC", Max = 15, Col = 4, Upper = true, InList = false, Pattern = "^[A-Z]{4}0[A-Z0-9]{6}$", PatternMessage = "IFSC is not valid." },
                new() { Name = "Remarks", Label = "Remarks", Kind = "textarea", Max = 300, Col = 12, InList = false }
            ]
        },
        new()
        {
            Key = "categories", PageCode = "MASTER.PH_CATEGORIES", Title = "Item Category", Singular = "category", Icon = "bi-tags", SaveAction = "SaveCategory",
            Description = "Main categories (Drugs, Surgical, Consumables ...) and their sub-categories. Used in price rules, discounts and reports.",
            Table = "PhCategory", IdCol = "CategoryId", OrderBy = "ISNULL(ParentCategoryId, CategoryId), ParentCategoryId, SortOrder, CategoryName",
            Fields =
            [
                new() { Name = "CategoryName", Label = "Category name", Required = true, Max = 100, Col = 6 },
                new() { Name = "ParentCategoryId", Label = "Under (main category)", Kind = "select", Lookup = "mainCategories", Col = 4, Help = "Empty = this is a main category." },
                new() { Name = "SortOrder", Label = "Order", Kind = "number", Col = 2, Default = 100 }
            ]
        },
        new()
        {
            Key = "dosageforms", PageCode = "MASTER.PH_DOSAGEFORMS", Title = "Dosage Form", Singular = "dosage form", Icon = "bi-prescription2", SaveAction = "SaveDosageForm",
            Description = "Tablet, capsule, syrup, injection ... The short name prints before the item on bills and labels (TAB DOLO 650).",
            Table = "PhDosageForm", IdCol = "DosageFormId", OrderBy = "SortOrder, DosageFormName",
            Fields =
            [
                new() { Name = "DosageFormName", Label = "Dosage form", Required = true, Max = 60, Col = 6 },
                new() { Name = "ShortName", Label = "Short name", Max = 10, Col = 3, Upper = true },
                new() { Name = "SortOrder", Label = "Order", Kind = "number", Col = 3, Default = 100 }
            ]
        },
        new()
        {
            Key = "units", PageCode = "MASTER.PH_UOMS", Title = "Unit of Measure", Singular = "unit", Icon = "bi-rulers", SaveAction = "SaveUnit",
            Description = "Purchase units (strip, box, bottle) and sale units (tablet, nos). The Item Master says how many sale units are in one purchase unit.",
            Table = "PhUom", IdCol = "UomId", OrderBy = "SortOrder, UomCode",
            Fields =
            [
                new() { Name = "UomCode", Label = "Code", Required = true, Max = 10, Col = 3, Upper = true },
                new() { Name = "UomName", Label = "Unit name", Required = true, Max = 50, Col = 6 },
                new() { Name = "SortOrder", Label = "Order", Kind = "number", Col = 3, Default = 100 }
            ]
        },
        new()
        {
            Key = "hsn", PageCode = "MASTER.PH_HSN", Title = "HSN & GST Rate", Singular = "HSN code", Icon = "bi-percent", SaveAction = "SaveHsn",
            Description = "GST rate by HSN code (CGST = SGST = half; IGST = full). A rate change keeps the old rate in history, effective from the date you give.",
            Table = "PhHsn", IdCol = "HsnId", OrderBy = "HsnCode",
            Fields =
            [
                new() { Name = "HsnCode", Label = "HSN code", Required = true, Max = 10, Col = 3, Pattern = "^[0-9]{4,8}$", PatternMessage = "HSN code: 4 to 8 digits." },
                new() { Name = "Description", Label = "Description", Required = true, Max = 200, Col = 9 },
                new() { Name = "GstPercent", Label = "GST %", Kind = "select", Required = true, Col = 3, Options = [new("0", "0%"), new("5", "5%"), new("12", "12%"), new("18", "18%"), new("28", "28%")] },
                new() { Name = "CessPercent", Label = "Cess %", Kind = "decimal", Col = 3, Default = 0 },
                new() { Name = "EffectiveFrom", Label = "Rate effective from", Kind = "date", Required = true, Col = 4 }
            ]
        },
        new()
        {
            Key = "schedules", PageCode = "MASTER.PH_SCHEDULES", Title = "Drug Schedule", Singular = "schedule", Icon = "bi-shield-exclamation", ReadOnly = true,
            Description = "Statutory schedules (Drugs & Cosmetics Rules, 1945 and NDPS Act). They decide whether a prescription is needed, whether a register entry is made and the warning printed on the bill.",
            Table = "PhDrugSchedule", IdCol = "ScheduleCode", OrderBy = "SortOrder",
            Fields =
            [
                new() { Name = "ScheduleCode", Label = "Code" },
                new() { Name = "ScheduleName", Label = "Schedule" },
                new() { Name = "RxRequired", Label = "Prescription needed", Kind = "bool" },
                new() { Name = "RegisterRequired", Label = "Register entry", Kind = "bool" },
                new() { Name = "IsNarcotic", Label = "Narcotic control", Kind = "bool" },
                new() { Name = "LabelWarning", Label = "Warning printed" }
            ]
        },
        new()
        {
            Key = "pricerules", PageCode = "MASTER.PH_PRICERULES", Title = "Price Rule", Singular = "price rule", Icon = "bi-currency-rupee", SaveAction = "SavePriceRule",
            Description = "How the selling price is worked out for each patient type. The price is never above the MRP printed on the pack.",
            Table = "PhPriceRule", IdCol = "PriceRuleId", OrderBy = "PatientType, Priority, RuleName",
            Fields =
            [
                new() { Name = "RuleName", Label = "Rule name", Required = true, Max = 100, Col = 6 },
                new() { Name = "PatientType", Label = "Patient type", Kind = "select", Required = true, Options = PatientTypes, Col = 6 },
                new() { Name = "CategoryId", Label = "Item category", Kind = "select", Lookup = "categories", Col = 6, Help = "Empty = all categories." },
                new() { Name = "PriceBasis", Label = "Price basis", Kind = "select", Required = true, Col = 3,
                        Options = [new("MRP", "MRP"), new("MRP_LESS", "MRP less %"), new("COST_PLUS", "Cost plus %")] },
                new() { Name = "RatePercent", Label = "%", Kind = "decimal", Col = 3, Default = 0 },
                new() { Name = "Priority", Label = "Priority", Kind = "number", Col = 3, Default = 100, Help = "Lower wins when several rules match." }
            ]
        },
        new()
        {
            Key = "discounts", PageCode = "MASTER.PH_DISCOUNTS", Title = "Discount Scheme", Singular = "discount scheme", Icon = "bi-ticket-perforated", SaveAction = "SaveDiscount",
            Description = "Discounts the counter can apply. A manual discount above the branch limit (Hospital Settings > MED) needs approval.",
            Table = "PhDiscountScheme", IdCol = "SchemeId", OrderBy = "SchemeName",
            Fields =
            [
                new() { Name = "SchemeName", Label = "Scheme name", Required = true, Max = 100, Col = 6 },
                new() { Name = "DiscountType", Label = "Type", Kind = "select", Required = true, Col = 3, Options = [new("PERCENT", "Percent"), new("FLAT", "Flat amount")] },
                new() { Name = "DiscountValue", Label = "Value", Kind = "decimal", Required = true, Col = 3 },
                new() { Name = "AppliesTo", Label = "Applies to", Kind = "select", Required = true, Col = 4,
                        Options = [new("ALL", "All items / customers"), new("CATEGORY", "One item category"), new("CUSTOMER_TYPE", "One customer type")] },
                new() { Name = "CategoryId", Label = "Category", Kind = "select", Lookup = "categories", Col = 4 },
                new() { Name = "CustomerType", Label = "Customer type", Kind = "select", Options = CustomerTypes, Col = 4 },
                new() { Name = "MinBillAmount", Label = "Min. bill amount", Kind = "decimal", Col = 4, Default = 0 },
                new() { Name = "ValidFrom", Label = "Valid from", Kind = "date", Col = 4 },
                new() { Name = "ValidTo", Label = "Valid to", Kind = "date", Col = 4 }
            ]
        },
        new()
        {
            Key = "customers", PageCode = "MASTER.PH_CUSTOMERS", Title = "Pharmacy Customer", Singular = "customer", Icon = "bi-person-vcard", SaveAction = "SaveCustomer",
            Description = "Regular walk-in buyers (for credit sale, a fixed discount or a GST invoice). Hospital patients are picked by UHID and need no entry here.",
            Table = "PhCustomer", IdCol = "CustomerId", OrderBy = "CustomerName",
            Fields =
            [
                new() { Name = "CustomerName", Label = "Customer name", Required = true, Col = 6 },
                new() { Name = "Mobile", Label = "Mobile", Required = true, Max = 15, Col = 3, Pattern = "^[6-9][0-9]{9}$", PatternMessage = "Mobile: 10 digits starting 6-9." },
                new() { Name = "CustomerType", Label = "Type", Kind = "select", Required = true, Options = CustomerTypes, Col = 3 },
                new() { Name = "Email", Label = "E-mail", Max = 150, Col = 6, InList = false, Pattern = "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", PatternMessage = "E-mail is not valid." },
                new() { Name = "Gstin", Label = "GSTIN (B2B invoice)", Max = 15, Col = 6, Upper = true, InList = false, Pattern = GstinRx, PatternMessage = "GSTIN is not in the 15-character format." },
                new() { Name = "Address", Label = "Address", Kind = "textarea", Max = 300, Col = 12, InList = false },
                new() { Name = "CreditAllowed", Label = "Credit sale allowed", Kind = "bool", Col = 4 },
                new() { Name = "CreditLimit", Label = "Credit limit", Kind = "decimal", Col = 4, Default = 0 },
                new() { Name = "SchemeId", Label = "Discount scheme", Kind = "select", Lookup = "schemes", Col = 4 }
            ]
        },
        new()
        {
            Key = "reasons", PageCode = "MASTER.PH_REASONS", Title = "Return / Adjust Reason", Singular = "reason", Icon = "bi-chat-left-text", SaveAction = "SaveReason",
            Description = "Reasons picked (and required) on returns, stock adjustments, write-offs and cancellations.",
            Table = "PhReason", IdCol = "ReasonId", OrderBy = "ReasonType, SortOrder, ReasonName",
            Fields =
            [
                new() { Name = "ReasonType", Label = "Used on", Kind = "select", Required = true, Options = ReasonTypes, Col = 4 },
                new() { Name = "ReasonName", Label = "Reason", Required = true, Col = 6 },
                new() { Name = "SortOrder", Label = "Order", Kind = "number", Col = 2, Default = 100 }
            ]
        },
        new()
        {
            Key = "numberseries", PageCode = "MASTER.PH_NUMBERSERIES", Title = "Document Number Series", Singular = "number series", Icon = "bi-123", SaveAction = "SaveNumberSeries",
            Description = "Numbering of pharmacy documents for this branch: PREFIX / BRANCH CODE / FINANCIAL YEAR / serial, e.g. PS/HO/2627/000001.",
            Table = "PhNumberSeries", IdCol = "SeriesId", OrderBy = "SeriesId", BranchScoped = true, NoAdd = true,
            Fields =
            [
                new() { Name = "DocName", Label = "Document", Kind = "readonly", Col = 6 },
                new() { Name = "DocType", Label = "Type", Kind = "readonly", Col = 6 },
                new() { Name = "Prefix", Label = "Prefix", Required = true, Max = 10, Col = 4, Upper = true, Pattern = "^[A-Z0-9]{1,10}$", PatternMessage = "Prefix: letters and digits only." },
                new() { Name = "Padding", Label = "Digits", Kind = "number", Required = true, Col = 4, Default = 6 },
                new() { Name = "ResetYearly", Label = "Restart every financial year", Kind = "bool", Col = 4, Default = true }
            ]
        }
    ];

    public static PhMasterDef Get(string key) => All.First(d => d.Key == key);
}

public record PhHeader(string Title, string Icon, string Description, int? Total, int? Active, string? Heading = null, string? Crumb = null, string? ListUrl = null,
    IReadOnlyList<KeyValuePair<string, int>>? Stats = null, string Section = "Master", string Group = "Pharmacy Master");

public record PhItemFilter(string? Search, int? CategoryId, string? Schedule, int? ManufacturerId, bool? Active, int Page);

public class PhItemListRow
{
    public int ItemId { get; set; }
    public string ItemCode { get; set; } = "";
    public string ItemName { get; set; } = "";
    public string? FormShort { get; set; }
    public string? Strength { get; set; }
    public string? PackSize { get; set; }
    public string? GenericName { get; set; }
    public string? ManufacturerName { get; set; }
    public string? CategoryName { get; set; }
    public string ScheduleCode { get; set; } = "";
    public string HsnCode { get; set; } = "";
    public decimal GstPercent { get; set; }
    public string PurchaseUom { get; set; } = "";
    public string SaleUom { get; set; } = "";
    public int ConversionQty { get; set; }
    public bool IsColdChain { get; set; }
    public bool IsHighAlert { get; set; }
    public bool IsLasa { get; set; }
    public string? RackNo { get; set; }
    public bool IsActive { get; set; }
    public int TotalCount { get; set; }
}

public class PhItemForm
{
    public int ItemId { get; set; }
    public string? ItemCode { get; set; }
    public string ItemName { get; set; } = "";
    public int? GenericId { get; set; }
    public int? ManufacturerId { get; set; }
    public int CategoryId { get; set; }
    public int? DosageFormId { get; set; }
    public string? Strength { get; set; }
    public string? PackSize { get; set; }
    public string ScheduleCode { get; set; } = "H";
    public int HsnId { get; set; }
    public int PurchaseUomId { get; set; }
    public int SaleUomId { get; set; }
    public int ConversionQty { get; set; } = 1;
    public bool AllowLooseSale { get; set; } = true;
    public bool IsColdChain { get; set; }
    public bool IsHighAlert { get; set; }
    public bool IsLasa { get; set; }
    public bool IsReturnable { get; set; } = true;
    public bool IsDiscountAllowed { get; set; } = true;
    public string? Barcode { get; set; }
    public decimal ReorderLevel { get; set; }
    public decimal MinQty { get; set; }
    public decimal MaxQty { get; set; }
    public int LeadDays { get; set; } = 2;
    public string? Remarks { get; set; }
    public bool IsActive { get; set; } = true;
    // this branch (PhItemBranch)
    public string? RackNo { get; set; }
    public decimal? BranchReorderLevel { get; set; }
    public decimal? BranchMinQty { get; set; }
    public decimal? BranchMaxQty { get; set; }
    public bool IsStocked { get; set; } = true;
}

public class PhItemLookups
{
    public List<PhOption> Generics { get; set; } = [];
    public List<PhOption> Manufacturers { get; set; } = [];
    public List<PhOption> Categories { get; set; } = [];
    public List<PhOption> DosageForms { get; set; } = [];
    public List<PhOption> Uoms { get; set; } = [];
    public List<(int Id, string Code, string Description, decimal Gst)> Hsn { get; set; } = [];
    public List<(string Code, string Name, string? Warning, bool Rx)> Schedules { get; set; } = [];
}

public interface IPharmacyMasterService
{
    Task EnsureMastersAsync(int companyId, int branchId);
    Task<string> BranchCodeAsync(int branchId);
    Task<List<IDictionary<string, object?>>> ListAsync(PhMasterDef def, int companyId, int branchId);
    Task<Dictionary<string, List<PhOption>>> LookupsAsync(PhMasterDef def, int companyId);
    Task<string?> SaveAsync(PhMasterDef def, int companyId, int branchId, IFormCollection form, int userId);
    Task<List<PhItemListRow>> ItemsAsync(int companyId, int branchId, string? search, int? categoryId, string? schedule, int? manufacturerId, bool? active, int page, int pageSize);
    Task<PhItemForm?> ItemAsync(int companyId, int branchId, int itemId);
    Task<PhItemLookups> ItemLookupsAsync(int companyId);
    Task<(int Total, int Active)> ItemCountsAsync(int companyId);
    Task<List<PhItemListRow>> SubstitutesAsync(int companyId, int itemId);
    Task<List<PhItemListRow>> SearchItemsAsync(int companyId, string q, int take = 15);
    Task<(int Id, string? Error)> SaveItemAsync(int companyId, int branchId, PhItemForm f, int userId);
}

public class PharmacyMasterService(IDbConnectionFactory db) : IPharmacyMasterService
{
    public async Task EnsureMastersAsync(int companyId, int branchId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("dbo.usp_Pharmacy_EnsureMasters", new { CompanyId = companyId, BranchId = branchId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<string> BranchCodeAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<string?>("SELECT BranchCode FROM dbo.BranchMaster WHERE BranchID = @branchId", new { branchId }) ?? branchId.ToString();
    }

    public async Task<List<IDictionary<string, object?>>> ListAsync(PhMasterDef def, int companyId, int branchId)
    {
        // Table and column names come only from PharmacyMasterDefs, never from the request.
        var cols = string.Join(", ", def.Fields.Select(f => f.Name).Where(n => n != def.IdCol));
        var sql = def.ReadOnly
            ? $"SELECT {def.IdCol}, {cols}, CAST(1 AS BIT) AS IsActive FROM dbo.{def.Table} ORDER BY {def.OrderBy}"
            : $"SELECT {def.IdCol}, {cols}, IsActive FROM dbo.{def.Table} WHERE CompanyId = @companyId{(def.BranchScoped ? " AND BranchId = @branchId" : "")} ORDER BY {def.OrderBy}";
        using var con = db.CreateConnection();
        var rows = await con.QueryAsync(sql, new { companyId, branchId });
        return rows.Select(r => (IDictionary<string, object?>)(IDictionary<string, object>)r).ToList();
    }

    public async Task<Dictionary<string, List<PhOption>>> LookupsAsync(PhMasterDef def, int companyId)
    {
        var result = new Dictionary<string, List<PhOption>>();
        using var con = db.CreateConnection();
        foreach (var key in def.Fields.Where(f => f.Lookup != null).Select(f => f.Lookup!).Distinct())
        {
            var sql = key switch
            {
                "states" => "SELECT CAST(StateId AS VARCHAR(10)) AS Value, StateName AS Text FROM dbo.StateMaster WHERE IsActive = 1 ORDER BY StateName",
                "mainCategories" => "SELECT CAST(CategoryId AS VARCHAR(10)) AS Value, CategoryName AS Text FROM dbo.PhCategory WHERE CompanyId = @companyId AND ParentCategoryId IS NULL ORDER BY SortOrder, CategoryName",
                "categories" => CategorySql,
                "schemes" => "SELECT CAST(SchemeId AS VARCHAR(10)) AS Value, SchemeName AS Text FROM dbo.PhDiscountScheme WHERE CompanyId = @companyId AND IsActive = 1 ORDER BY SchemeName",
                _ => throw new InvalidOperationException("Unknown lookup " + key)
            };
            result[key] = (await con.QueryAsync<PhOption>(sql, new { companyId })).ToList();
        }
        return result;
    }

    private const string CategorySql =
        @"SELECT CAST(c.CategoryId AS VARCHAR(10)) AS Value, CASE WHEN p.CategoryId IS NULL THEN c.CategoryName ELSE p.CategoryName + N' › ' + c.CategoryName END AS Text
          FROM dbo.PhCategory c LEFT JOIN dbo.PhCategory p ON p.CategoryId = c.ParentCategoryId
          WHERE c.CompanyId = @companyId AND c.IsActive = 1 ORDER BY ISNULL(p.SortOrder, c.SortOrder), ISNULL(p.CategoryName, c.CategoryName), c.ParentCategoryId, c.SortOrder";

    public async Task<string?> SaveAsync(PhMasterDef def, int companyId, int branchId, IFormCollection form, int userId)
    {
        if (def.ReadOnly) return "This list cannot be changed.";
        int.TryParse(form[def.IdCol], out var id);
        if (id == 0 && def.NoAdd) return "New entries cannot be added here.";

        var p = new DynamicParameters();
        p.Add("id", id); p.Add("companyId", companyId); p.Add("branchId", branchId); p.Add("userId", userId);
        p.Add("IsActive", IsChecked(form["IsActive"]));
        var editable = def.Fields.Where(f => f.Kind != "readonly").ToList();
        foreach (var f in editable)
        {
            var (value, error) = Parse(f, form[f.Name].FirstOrDefault(v => v != "false") ?? form[f.Name].FirstOrDefault());
            if (error != null) return error;
            p.Add(f.Name, value);
        }

        var extra = ValidateSpecial(def.Key, p, id);
        if (extra != null) return extra;

        using var con = db.CreateConnection();
        if (con.State != ConnectionState.Open) con.Open();
        using var tx = con.BeginTransaction();
        try
        {
            if (def.Key == "suppliers" && string.IsNullOrWhiteSpace(p.Get<object?>("SupplierCode") as string))
                p.Add("SupplierCode", await con.ExecuteScalarAsync<string>(
                    "SELECT 'SUP' + RIGHT('0000' + CAST(ISNULL(MAX(SupplierId), 0) + 1 AS VARCHAR(10)), 4) FROM dbo.PhSupplier WITH (UPDLOCK, HOLDLOCK)", transaction: tx));

            decimal? oldGst = null, oldCess = null; DateTime? oldFrom = null;
            if (def.Key == "hsn" && id > 0)
            {
                var old = await con.QuerySingleOrDefaultAsync<(decimal Gst, decimal Cess, DateTime From)>(
                    "SELECT GstPercent, CessPercent, EffectiveFrom FROM dbo.PhHsn WHERE HsnId = @id AND CompanyId = @companyId", p, tx);
                oldGst = old.Gst; oldCess = old.Cess; oldFrom = old.From;
            }

            var names = editable.Select(f => f.Name).ToList();
            if (id == 0)
            {
                var scope = def.BranchScoped ? "CompanyId, BranchId" : "CompanyId";
                var scopeVals = def.BranchScoped ? "@companyId, @branchId" : "@companyId";
                id = await con.ExecuteScalarAsync<int>(
                    $"INSERT dbo.{def.Table} ({scope}, {string.Join(", ", names)}, IsActive, CreatedBy) VALUES ({scopeVals}, {string.Join(", ", names.Select(n => "@" + n))}, @IsActive, @userId); SELECT CAST(SCOPE_IDENTITY() AS INT);", p, tx);
                p.Add("id", id);
            }
            else
            {
                var n = await con.ExecuteAsync(
                    $"UPDATE dbo.{def.Table} SET {string.Join(", ", names.Select(c => $"{c} = @{c}"))}, IsActive = @IsActive, ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE {def.IdCol} = @id AND CompanyId = @companyId{(def.BranchScoped ? " AND BranchId = @branchId" : "")}", p, tx);
                if (n == 0) { tx.Rollback(); return "Record not found."; }
            }

            if (def.Key == "hsn")
            {
                var gst = p.Get<object?>("GstPercent") as decimal? ?? 0; var cess = p.Get<object?>("CessPercent") as decimal? ?? 0; var from = (DateTime)p.Get<object?>("EffectiveFrom")!;
                if (oldGst == null || oldGst != gst || oldCess != cess || oldFrom != from)
                    await con.ExecuteAsync("INSERT dbo.PhHsnRateHistory (HsnId, GstPercent, CessPercent, EffectiveFrom, CreatedBy) VALUES (@id, @gst, @cess, @from, @userId)",
                        new { id, gst, cess, from, userId }, tx);
            }
            tx.Commit();
            return null;
        }
        catch (SqlException ex) when (ex.Number is 2627 or 2601)
        {
            tx.Rollback();
            return $"This {def.Singular} already exists.";
        }
    }

    private static string? ValidateSpecial(string key, DynamicParameters p, int id)
    {
        switch (key)
        {
            case "categories":
                if (id > 0 && p.Get<object?>("ParentCategoryId") is int parent && parent == id) return "A category cannot be under itself.";
                break;
            case "pricerules":
                var basis = p.Get<object?>("PriceBasis") as string; var pct = p.Get<object?>("RatePercent") as decimal? ?? 0;
                if (pct < 0 || pct > 100) return "Percent must be between 0 and 100.";
                if (basis == "MRP" && pct != 0) return "Price basis MRP takes no percent; use 'MRP less %'.";
                break;
            case "discounts":
                var type = p.Get<object?>("DiscountType") as string; var val = p.Get<object?>("DiscountValue") as decimal? ?? 0;
                if (val <= 0) return "Discount value must be more than zero.";
                if (type == "PERCENT" && val > 100) return "Discount percent cannot be above 100.";
                var applies = p.Get<object?>("AppliesTo") as string;
                if (applies == "CATEGORY" && p.Get<object?>("CategoryId") == null) return "Pick the category the scheme applies to.";
                if (applies == "CUSTOMER_TYPE" && p.Get<object?>("CustomerType") == null) return "Pick the customer type the scheme applies to.";
                if (applies != "CATEGORY") p.Add("CategoryId", null);
                if (applies != "CUSTOMER_TYPE") p.Add("CustomerType", null);
                if (p.Get<object?>("ValidFrom") is DateTime vf && p.Get<object?>("ValidTo") is DateTime vt && vt < vf) return "Valid to is before valid from.";
                break;
            case "customers":
                if (p.Get<object?>("CreditAllowed") is false) p.Add("CreditLimit", 0m);
                else if ((p.Get<object?>("CreditLimit") as decimal? ?? 0) <= 0) return "Give a credit limit, or untick credit sale.";
                break;
            case "numberseries":
                var pad = p.Get<object?>("Padding") as int? ?? 0;
                if (pad is < 3 or > 10) return "Digits must be between 3 and 10.";
                break;
            case "suppliers":
                if (p.Get<object?>("CreditDays") is int cd && (cd < 0 || cd > 365)) return "Credit days must be between 0 and 365.";
                break;
        }
        return null;
    }

    private static bool IsChecked(Microsoft.Extensions.Primitives.StringValues v) => v.Any(x => x == "true" || x == "on");

    private static (object? Value, string? Error) Parse(PhField f, string? raw)
    {
        raw = raw?.Trim();
        if (f.Kind == "bool") return (raw == "true" || raw == "on", null);
        if (string.IsNullOrEmpty(raw))
        {
            if (f.Required) return (null, $"{f.Label} is required.");
            return (f.Default is not null && f.Kind is "number" or "decimal" ? f.Default : null, null);
        }
        if (f.Upper) raw = raw.ToUpperInvariant();
        switch (f.Kind)
        {
            case "number":
                return int.TryParse(raw, out var i) ? (i, null) : (null, $"{f.Label}: enter a whole number.");
            case "decimal":
                return decimal.TryParse(raw, NumberStyles.Number, CultureInfo.InvariantCulture, out var d) && d >= 0 ? (d, null) : (null, $"{f.Label}: enter a valid amount.");
            case "date":
                return DateTime.TryParseExact(raw, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var dt) ? (dt, null) : (null, $"{f.Label}: enter a valid date.");
            case "select":
                if (f.Options != null)
                {
                    if (!f.Options.Any(o => o.Value == raw)) return (null, $"{f.Label}: pick from the list.");
                    return decimal.TryParse(raw, NumberStyles.Number, CultureInfo.InvariantCulture, out var sd) && f.Name.EndsWith("Percent") ? (sd, null) : (raw, null);
                }
                return int.TryParse(raw, out var sid) ? (sid, null) : (null, $"{f.Label}: pick from the list.");
            default:
                if (raw.Length > f.Max) return (null, $"{f.Label}: up to {f.Max} characters.");
                if (f.Pattern != null && !Regex.IsMatch(raw, f.Pattern)) return (null, f.PatternMessage ?? $"{f.Label} is not valid.");
                return (raw, null);
        }
    }

    // ── Item Master ──────────────────────────────────────────────────────────────────────────────────────
    private const string ItemSelect = @"
        SELECT i.ItemId, i.ItemCode, i.ItemName, df.ShortName AS FormShort, i.Strength, i.PackSize, g.GenericName, m.ManufacturerName,
               CASE WHEN pc.CategoryId IS NULL THEN c.CategoryName ELSE pc.CategoryName + N' › ' + c.CategoryName END AS CategoryName,
               i.ScheduleCode, h.HsnCode, h.GstPercent, pu.UomCode AS PurchaseUom, su.UomCode AS SaleUom, i.ConversionQty,
               i.IsColdChain, i.IsHighAlert, i.IsLasa, ib.RackNo, i.IsActive";
    private const string ItemFrom = @"
        FROM dbo.PhItem i
        JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId LEFT JOIN dbo.PhCategory pc ON pc.CategoryId = c.ParentCategoryId
        JOIN dbo.PhHsn h ON h.HsnId = i.HsnId
        JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
        LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId
        LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
        LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId";

    public async Task<List<PhItemListRow>> ItemsAsync(int companyId, int branchId, string? search, int? categoryId, string? schedule, int? manufacturerId, bool? active, int page, int pageSize)
    {
        using var con = db.CreateConnection();
        var sql = ItemSelect + ", COUNT(*) OVER () AS TotalCount" + ItemFrom + @"
            LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @branchId
            WHERE i.CompanyId = @companyId
              AND (@search IS NULL OR i.ItemName LIKE @like OR i.ItemCode LIKE @like OR g.GenericName LIKE @like OR i.Barcode = @search)
              AND (@categoryId IS NULL OR i.CategoryId = @categoryId OR c.ParentCategoryId = @categoryId)
              AND (@schedule IS NULL OR i.ScheduleCode = @schedule)
              AND (@manufacturerId IS NULL OR i.ManufacturerId = @manufacturerId)
              AND (@active IS NULL OR i.IsActive = @active)
            ORDER BY i.ItemName OFFSET @skip ROWS FETCH NEXT @pageSize ROWS ONLY";
        search = string.IsNullOrWhiteSpace(search) ? null : search.Trim();
        return (await con.QueryAsync<PhItemListRow>(sql, new
        {
            companyId, branchId, search, like = search == null ? null : "%" + search + "%", categoryId, schedule, manufacturerId, active,
            skip = (Math.Max(page, 1) - 1) * pageSize, pageSize
        })).ToList();
    }

    public async Task<List<PhItemListRow>> SearchItemsAsync(int companyId, string q, int take = 15)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhItemListRow>($"SELECT TOP (@take) {ItemSelect[ItemSelect.IndexOf("i.ItemId", StringComparison.Ordinal)..]}" + ItemFrom +
            @" LEFT JOIN dbo.PhItemBranch ib ON 1 = 0
               WHERE i.CompanyId = @companyId AND (i.ItemName LIKE @like OR g.GenericName LIKE @like OR i.ItemCode = @q OR i.Barcode = @q)
               ORDER BY CASE WHEN i.ItemName LIKE @starts THEN 0 ELSE 1 END, i.ItemName",
            new { companyId, q, take, like = "%" + q + "%", starts = q + "%" })).ToList();
    }

    public async Task<List<PhItemListRow>> SubstitutesAsync(int companyId, int itemId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<PhItemListRow>(ItemSelect + ItemFrom +
            @" LEFT JOIN dbo.PhItemBranch ib ON 1 = 0
               WHERE i.CompanyId = @companyId AND i.ItemId <> @itemId AND i.GenericId IS NOT NULL
                 AND i.GenericId = (SELECT GenericId FROM dbo.PhItem WHERE ItemId = @itemId) ORDER BY i.ItemName", new { companyId, itemId })).ToList();
    }

    public async Task<PhItemForm?> ItemAsync(int companyId, int branchId, int itemId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<PhItemForm>(@"
            SELECT i.*, ib.RackNo, ib.ReorderLevel AS BranchReorderLevel, ib.MinQty AS BranchMinQty, ib.MaxQty AS BranchMaxQty, ISNULL(ib.IsStocked, 1) AS IsStocked
            FROM dbo.PhItem i LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @branchId
            WHERE i.ItemId = @itemId AND i.CompanyId = @companyId", new { companyId, branchId, itemId });
    }

    public async Task<(int Total, int Active)> ItemCountsAsync(int companyId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<(int, int)>("SELECT COUNT(*), ISNULL(SUM(CASE WHEN IsActive = 1 THEN 1 ELSE 0 END), 0) FROM dbo.PhItem WHERE CompanyId = @companyId", new { companyId });
    }

    public async Task<PhItemLookups> ItemLookupsAsync(int companyId)
    {
        using var con = db.CreateConnection();
        var p = new { companyId };
        // Inactive entries stay in the lists (marked) so an item that already uses one still shows it.
        return new PhItemLookups
        {
            Generics = (await con.QueryAsync<PhOption>("SELECT CAST(GenericId AS VARCHAR(10)) Value, GenericName + CASE WHEN IsActive = 0 THEN N' (inactive)' ELSE N'' END Text FROM dbo.PhGeneric WHERE CompanyId = @companyId ORDER BY GenericName", p)).ToList(),
            Manufacturers = (await con.QueryAsync<PhOption>("SELECT CAST(ManufacturerId AS VARCHAR(10)) Value, ManufacturerName + CASE WHEN IsActive = 0 THEN N' (inactive)' ELSE N'' END Text FROM dbo.PhManufacturer WHERE CompanyId = @companyId ORDER BY ManufacturerName", p)).ToList(),
            Categories = (await con.QueryAsync<PhOption>(CategorySql, p)).ToList(),
            DosageForms = (await con.QueryAsync<PhOption>("SELECT CAST(DosageFormId AS VARCHAR(10)) Value, DosageFormName + ISNULL(N' (' + ShortName + N')', N'') Text FROM dbo.PhDosageForm WHERE CompanyId = @companyId AND IsActive = 1 ORDER BY SortOrder, DosageFormName", p)).ToList(),
            Uoms = (await con.QueryAsync<PhOption>("SELECT CAST(UomId AS VARCHAR(10)) Value, UomName + N' (' + UomCode + N')' Text FROM dbo.PhUom WHERE CompanyId = @companyId AND IsActive = 1 ORDER BY SortOrder, UomCode", p)).ToList(),
            Hsn = (await con.QueryAsync<(int, string, string, decimal)>("SELECT HsnId, HsnCode, Description, GstPercent FROM dbo.PhHsn WHERE CompanyId = @companyId AND IsActive = 1 ORDER BY HsnCode", p)).ToList(),
            Schedules = (await con.QueryAsync<(string, string, string?, bool)>("SELECT ScheduleCode, ScheduleName, LabelWarning, RxRequired FROM dbo.PhDrugSchedule ORDER BY SortOrder")).ToList()
        };
    }

    public async Task<(int Id, string? Error)> SaveItemAsync(int companyId, int branchId, PhItemForm f, int userId)
    {
        f.ItemName = f.ItemName?.Trim() ?? "";
        f.ItemCode = string.IsNullOrWhiteSpace(f.ItemCode) ? null : f.ItemCode.Trim().ToUpperInvariant();
        f.Barcode = string.IsNullOrWhiteSpace(f.Barcode) ? null : f.Barcode.Trim();
        if (f.ItemName.Length is 0 or > 200) return (0, "Item name is required (up to 200 characters).");
        if (f.CategoryId == 0 || f.HsnId == 0 || f.PurchaseUomId == 0 || f.SaleUomId == 0) return (0, "Category, HSN, purchase unit and sale unit are required.");
        if (f.ConversionQty < 1 || f.ConversionQty > 10000) return (0, "Sale units per purchase unit must be between 1 and 10000.");
        if (f.PurchaseUomId == f.SaleUomId && f.ConversionQty != 1) return (0, "Purchase and sale unit are the same, so the conversion must be 1.");
        if (f.MinQty < 0 || f.ReorderLevel < 0 || f.MaxQty < 0) return (0, "Stock levels cannot be negative.");
        if (f.MaxQty > 0 && (f.MinQty > f.MaxQty || f.ReorderLevel > f.MaxQty)) return (0, "Minimum and reorder level must not be above the maximum.");
        if (f.ScheduleCode is "X" or "NDPS") f.IsReturnable = false;   // controlled drugs are never taken back over the counter

        using var con = db.CreateConnection();
        if (con.State != ConnectionState.Open) con.Open();
        using var tx = con.BeginTransaction();
        try
        {
            var dup = await con.ExecuteScalarAsync<string?>(@"SELECT TOP 1 ItemCode FROM dbo.PhItem WHERE CompanyId = @companyId AND ItemId <> @ItemId
                AND ItemName = @ItemName AND ISNULL(ManufacturerId, 0) = ISNULL(@ManufacturerId, 0) AND ISNULL(DosageFormId, 0) = ISNULL(@DosageFormId, 0)",
                new { companyId, f.ItemId, f.ItemName, f.ManufacturerId, f.DosageFormId }, tx);
            if (dup != null) { tx.Rollback(); return (0, $"The same item of this manufacturer and form already exists ({dup})."); }

            f.ItemCode ??= await con.ExecuteScalarAsync<string>(
                "SELECT 'PH' + RIGHT('00000' + CAST(ISNULL(MAX(ItemId), 0) + 1 AS VARCHAR(10)), 5) FROM dbo.PhItem WITH (UPDLOCK, HOLDLOCK)", transaction: tx);
            var p = new DynamicParameters(f);
            p.Add("companyId", companyId); p.Add("branchId", branchId); p.Add("userId", userId);
            const string cols = "ItemCode, ItemName, GenericId, ManufacturerId, CategoryId, DosageFormId, Strength, PackSize, ScheduleCode, HsnId, PurchaseUomId, SaleUomId, ConversionQty, AllowLooseSale, IsColdChain, IsHighAlert, IsLasa, IsReturnable, IsDiscountAllowed, Barcode, ReorderLevel, MinQty, MaxQty, LeadDays, Remarks, IsActive";
            if (f.ItemId == 0)
                f.ItemId = await con.ExecuteScalarAsync<int>($"INSERT dbo.PhItem (CompanyId, {cols}, CreatedBy) VALUES (@companyId, {string.Join(", ", cols.Split(", ").Select(c => "@" + c))}, @userId); SELECT CAST(SCOPE_IDENTITY() AS INT);", p, tx);
            else if (await con.ExecuteAsync($"UPDATE dbo.PhItem SET {string.Join(", ", cols.Split(", ").Select(c => $"{c} = @{c}"))}, ModifiedBy = @userId, ModifiedDate = GETDATE() WHERE ItemId = @ItemId AND CompanyId = @companyId", p, tx) == 0)
            { tx.Rollback(); return (0, "Item not found."); }

            p.Add("ItemId", f.ItemId);
            await con.ExecuteAsync(@"
                MERGE dbo.PhItemBranch AS t USING (SELECT @ItemId AS ItemId, @branchId AS BranchId) AS s ON t.ItemId = s.ItemId AND t.BranchId = s.BranchId
                WHEN MATCHED THEN UPDATE SET RackNo = @RackNo, ReorderLevel = @BranchReorderLevel, MinQty = @BranchMinQty, MaxQty = @BranchMaxQty, IsStocked = @IsStocked, ModifiedBy = @userId, ModifiedDate = GETDATE()
                WHEN NOT MATCHED THEN INSERT (ItemId, BranchId, RackNo, ReorderLevel, MinQty, MaxQty, IsStocked, ModifiedBy, ModifiedDate)
                     VALUES (@ItemId, @branchId, @RackNo, @BranchReorderLevel, @BranchMinQty, @BranchMaxQty, @IsStocked, @userId, GETDATE());", p, tx);
            tx.Commit();
            return (f.ItemId, null);
        }
        catch (SqlException ex) when (ex.Number is 2627 or 2601)
        {
            tx.Rollback();
            return (0, ex.Message.Contains("Barcode") ? "Another item already has this barcode." : "Another item already has this item code.");
        }
    }
}
