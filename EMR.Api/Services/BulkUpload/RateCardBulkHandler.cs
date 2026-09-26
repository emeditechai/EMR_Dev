using EMR.Api.Models;

namespace EMR.Api.Services.BulkUpload;

/// <summary>
/// Rate list upload for B2C (Rate_Type 'B2C') and B2B (Rate_Type 'Franchise', B2CIdentity_ID = Franchise_ID).
/// Rows are grouped into rate cards; a group is merged into the existing card it names (Rate Card ID) or
/// overlaps (same branch / franchise and overlapping effective period), otherwise a new card is created.
/// Items already on a card but not in the file are kept.
/// </summary>
public class RateCardBulkHandler(ILabRateCardService service, LabBulkLookups lookups, string rateType) : ILabBulkUploadHandler
{
    public const string B2C = "B2C";
    public const string Franchise = "Franchise";

    private const string CCard = "Rate Card ID";
    private const string CBranch = "Branch";
    private const string CFranchise = "Franchise";
    private const string CFrom = "Effective From";
    private const string CTo = "Effective To";
    private const string CItem = "Test / Profile / Package";
    private const string CType = "Item Type";
    private const string CMrp = "MRP";
    private const string CRate = "Rate";
    private const string CDisc = "Discount Allowed";
    private const string CStatus = "Status";

    private const string RefBranch = "REF_Branch";
    private const string RefFranchise = "REF_Franchise";
    private const string RefItem = "REF_Item";
    private static readonly string[] ItemTypes = ["Test", "Profile", "Package"];

    private static readonly DateTime MaxDate = new(2099, 12, 31);
    private bool IsB2B => rateType == Franchise;
    public string Module => IsB2B ? "b2b-rate" : "b2c-rate";
    public string Title => IsB2B ? "B2B (Franchise) Test Rate" : "B2C Test Rate";

    private sealed class ParsedRate
    {
        public required RowReader R { get; init; }
        public int? CardId { get; init; }
        public int BranchId { get; init; }
        public int? FranchiseId { get; init; }
        public DateTime From { get; init; }
        public DateTime To { get; init; }
        public required LabItemModel Item { get; init; }
        public decimal Rate { get; init; }
        public bool? Discount { get; init; }
        public bool? Status { get; init; }
        public bool Billable { get; init; }
        /// <summary>Item Type as given in the file (or the item's own type).</summary>
        public required string RowType { get; init; }
    }

    private List<LabItemModel> _items = [];
    private HashSet<string> _billable = [];

    private static bool IsInvestigation(string itemType) => itemType is "Test" or "Profile";
    private static string ItemKey(string itemType, int itemId) => $"{(IsInvestigation(itemType) ? "Test" : itemType)}|{itemId}";

    public async Task<BulkTemplate> BuildTemplateAsync(BulkContext ctx, bool withData)
    {
        var branches = await AllowedBranchesAsync(ctx);
        var franchises = await lookups.FranchisesAsync(ctx.CompanyId);
        var items = (await service.GetAllItemsAsync(ctx.CompanyId)).ToList();

        var columns = new List<BulkColumn>
        {
            new() { Header = CCard, Kind = BulkColumnKind.Integer, Note = "Leave blank: rows are added to the card of the same branch" + (IsB2B ? " + franchise" : "") + " whose period overlaps the dates, or a new card is created. Fill to update that specific card.", Width = 12 },
            new() { Header = CBranch, Required = true, RefSheet = RefBranch, Width = 22 }
        };
        if (IsB2B) columns.Add(new() { Header = CFranchise, Required = true, RefSheet = RefFranchise, Width = 28 });
        columns.AddRange(
        [
            new() { Header = CFrom, Required = true, Kind = BulkColumnKind.Date, Note = "Same for all rows of one rate card.", Width = 14 },
            new() { Header = CTo, Required = true, Kind = BulkColumnKind.Date, Note = "On or after Effective From, up to 31-12-2099.", Width = 14 },
            new() { Header = CItem, Required = true, RefSheet = RefItem, Note = "Active, billable investigation / profile / package.", Width = 40 },
            new() { Header = CType, Options = ItemTypes, Note = "Optional. Only needed if the same code exists as a test and a package.", Width = 11 },
            new() { Header = CMrp, Kind = BulkColumnKind.Decimal, ReadOnly = true, Note = "Information only (current MRP). Ignored on upload.", Width = 10 },
            new() { Header = CRate, Required = true, Kind = BulkColumnKind.Decimal, Note = (IsB2B ? "Franchise (B2B)" : "Patient (B2C)") + " rate, 0 or more.", Width = 11 },
            new() { Header = CDisc, Options = BulkValues.YesNoOptions, Note = "Default Yes for new items.", Width = 12 },
            new() { Header = CStatus, Options = BulkValues.StatusOptions, Note = "Default Active for new items.", Width = 11 }
        ]);

        var refs = new List<BulkRefSheet>
        {
            new() { Name = RefBranch, Headers = ["Select Value", "Branch Code", "Branch Name"],
                    Rows = branches.Items.Select(b => new object?[] { branches.Pick(b), b.Code, b.Name }).ToList() }
        };
        if (IsB2B)
            refs.Add(new() { Name = RefFranchise, Headers = ["Select Value", "Franchise Code", "Franchise Name", "Parent Branch"],
                             Rows = franchises.Items.Select(f => new object?[] { franchises.Pick(f), f.Code, f.Name, f.ParentBranchName }).ToList() });
        refs.Add(new() { Name = RefItem, Headers = ["Select Value", "Item Code", "Item Name", "Item Type", "MRP"],
                         Rows = items.Select(i => new object?[] { ItemPick(i), i.Item_Code, i.Item_Name, i.Item_Type, i.Default_Rate }).ToList() });

        var t = new BulkTemplate
        {
            SheetName = IsB2B ? "B2BRate" : "B2CRate",
            Columns = columns,
            RefSheets = refs,
            Notes =
            [
                "One row per item. All rows with the same Branch" + (IsB2B ? ", Franchise" : "") + " and Effective From / To form one rate card.",
                "When the rows go into an existing card, that card's effective dates are set to the dates in the file, and items not in the file stay on the card unchanged.",
                "If saving a rate card fails, all rows of that card are reported as failed."
            ]
        };

        if (withData)
        {
            foreach (var card in (await ExistingCardsAsync(ctx)).OrderBy(c => c.Branch_Name).ThenBy(c => c.Entity_Name).ThenByDescending(c => c.Effective_From))
            {
                var full = await service.GetByIdAsync(card.RateCard_ID);
                if (full == null) continue;
                var branch = branches.ById(card.Branch_ID);
                var franchise = franchises.ById(card.B2CIdentity_ID);
                foreach (var d in full.Details)
                {
                    var row = new List<object?>
                    {
                        card.RateCard_ID,
                        branch != null ? branches.Pick(branch) : card.Branch_Name
                    };
                    if (IsB2B) row.Add(franchise != null ? franchises.Pick(franchise) : card.Entity_Name);
                    row.AddRange([card.Effective_From, card.Effective_To, BulkValues.Pick(d.Item_Name, d.Item_Code), d.Item_Type,
                                  d.Default_Rate, d.Rate, BulkValues.YesNo(d.Is_Discount_Allowed), BulkValues.Status(d.Status)]);
                    t.DataRows.Add(row.ToArray());
                }
            }
        }
        return t;
    }

    private static string ItemPick(LabItemModel i) => BulkValues.Pick(i.Item_Name, i.Item_Code);

    private async Task<BulkLookup<RefBranch>> AllowedBranchesAsync(BulkContext ctx)
    {
        var all = await lookups.BranchesAsync(ctx.CompanyId);
        return ctx.IsHO || !ctx.BranchId.HasValue
            ? all
            : new BulkLookup<RefBranch>(all.Items.Where(b => b.Id == ctx.BranchId), b => b.Id, b => b.Code, b => b.Name);
    }

    private async Task<List<LabRateCardHeaderModel>> ExistingCardsAsync(BulkContext ctx) =>
        (await service.GetListAsync(rateType, ctx.IsHO ? null : ctx.BranchId, null, ctx.CompanyId))
            .Where(c => c.Rate_Type == rateType).ToList();

    private LabItemModel? ResolveItem(RowReader r, string? itemType)
    {
        var raw = r.Text(CItem, required: true);
        if (raw == null) return null;
        var code = BulkValues.ExtractCode(raw);
        var matches = _items.Where(i => string.Equals(i.Item_Code, code ?? raw, StringComparison.OrdinalIgnoreCase)).ToList();
        if (matches.Count == 0)
            matches = _items.Where(i => string.Equals(i.Item_Name, raw, StringComparison.OrdinalIgnoreCase)).ToList();
        if (itemType != null)
            matches = matches.Where(i => i.Item_Type == itemType || (IsInvestigation(i.Item_Type) && IsInvestigation(itemType))).ToList();

        if (matches.Count == 1) return matches[0];
        r.Fail(CItem, LabBulkUploadRules.InvalidRef, matches.Count == 0
            ? $"Item '{raw}' does not exist. Pick a value from the dropdown / REF_Item sheet."
            : $"Item '{raw}' matches more than one item; set '{CType}' to Test, Profile or Package.");
        return null;
    }

    public async Task ImportAsync(IReadOnlyList<BulkRow> rows, BulkContext ctx, LabBulkUploadResult result)
    {
        var branches = await lookups.BranchesAsync(ctx.CompanyId);
        var franchises = await lookups.FranchisesAsync(ctx.CompanyId);
        _items = await lookups.AllRateItemsAsync(ctx.CompanyId);
        _billable = (await service.GetAllItemsAsync(ctx.CompanyId)).Select(i => ItemKey(i.Item_Type, i.Item_ID)).ToHashSet();
        var cards = await ExistingCardsAsync(ctx);
        var cardsById = cards.ToDictionary(c => c.RateCard_ID);

        // 1. Row validation
        var parsed = new List<ParsedRate>();
        foreach (var row in rows)
        {
            var r = new RowReader(row);
            var cardId = r.Int(CCard, min: 1);
            LabRateCardHeaderModel? card = null;
            if (cardId.HasValue && !cardsById.TryGetValue(cardId.Value, out card))
                r.Fail(CCard, LabBulkUploadRules.NotFound, $"Rate Card ID {cardId} does not exist in the {Title} list" + (ctx.IsHO ? "." : " of your branch."));

            var branch = r.Ref(CBranch, branches, required: card == null, master: "Branch");
            var franchise = IsB2B ? r.Ref(CFranchise, franchises, required: card == null, master: "Franchise") : null;
            var from = r.Date(CFrom, required: card == null);
            var to = r.Date(CTo, required: card == null);
            var itemType = r.Option(CType, ItemTypes);
            var item = ResolveItem(r, itemType);
            var rate = r.Decimal(CRate, required: true);
            var discount = r.YesNo(CDisc);
            var status = r.Status(CStatus);
            r.RecordKey = item != null ? $"{item.Item_Code} {item.Item_Name}" : r.Text(CItem) ?? string.Empty;

            if (r.HasErrors)
            {
                result.AddFailure(r);
                continue;
            }

            var p = new ParsedRate
            {
                R = r,
                CardId = cardId,
                BranchId = branch?.Id ?? card!.Branch_ID ?? 0,
                FranchiseId = IsB2B ? franchise?.Id ?? card!.B2CIdentity_ID : null,
                From = from ?? card!.Effective_From.Date,
                To = to ?? card!.Effective_To.Date,
                Item = item!,
                Rate = rate!.Value,
                Discount = discount,
                Status = status,
                Billable = _billable.Contains(ItemKey(item!.Item_Type, item.Item_ID)),
                RowType = itemType ?? item.Item_Type
            };

            if (!ctx.IsHO && ctx.BranchId.HasValue && p.BranchId != ctx.BranchId)
                r.Fail(CBranch, LabBulkUploadRules.AccessDenied, "You can upload rates only for your own branch.");
            if (p.From > MaxDate || p.To > MaxDate)
                r.Fail(p.To > MaxDate ? CTo : CFrom, LabBulkUploadRules.InvalidValue, $"Effective dates cannot be after {MaxDate:dd-MM-yyyy}.");
            if (p.To < p.From)
                r.Fail(CTo, LabBulkUploadRules.InvalidValue, $"Effective To ({p.To:dd-MM-yyyy}) is before Effective From ({p.From:dd-MM-yyyy}).");

            if (r.HasErrors) result.AddFailure(r);
            else parsed.Add(p);
        }

        // 2. Group rows into rate cards
        var groups = parsed
            .GroupBy(p => p.CardId.HasValue ? $"C{p.CardId}" : $"N|{p.BranchId}|{p.FranchiseId}|{p.From:yyyyMMdd}|{p.To:yyyyMMdd}")
            .ToList();
        var claimedCards = new Dictionary<int, int>();
        var newCards = new List<ParsedRate>();

        foreach (var group in groups)
        {
            var first = group.First();
            var members = new List<ParsedRate>();
            foreach (var p in group)
            {
                if (p != first && (p.BranchId != first.BranchId || p.FranchiseId != first.FranchiseId || p.From != first.From || p.To != first.To))
                {
                    p.R.Fail(CFrom, LabBulkUploadRules.InvalidValue, $"Branch{(IsB2B ? " / Franchise" : "")} / dates differ from row {first.R.RowNo} of the same Rate Card ID.");
                    result.AddFailure(p.R);
                }
                else members.Add(p);
            }

            var target = first.CardId.HasValue
                ? cardsById[first.CardId.Value]
                : cards.Where(c => c.Branch_ID == first.BranchId && (!IsB2B || c.B2CIdentity_ID == first.FranchiseId)
                                   && c.Effective_From.Date <= first.To && c.Effective_To.Date >= first.From)
                       .OrderByDescending(c => c.Effective_From).FirstOrDefault();

            string? groupError = null;
            if (target != null && !claimedCards.TryAdd(target.RateCard_ID, first.R.RowNo))
                groupError = $"These rows go to rate card #{target.RateCard_ID}, which the rows starting at row {claimedCards[target.RateCard_ID]} already update. Use the same dates for one rate card.";
            if (target == null)
            {
                var overlap = newCards.FirstOrDefault(n => n.BranchId == first.BranchId && n.FranchiseId == first.FranchiseId && n.From <= first.To && n.To >= first.From);
                if (overlap != null)
                    groupError = $"Effective period overlaps the new rate card starting at row {overlap.R.RowNo}. Use the same dates for one rate card.";
                else newCards.Add(first);
            }
            if (groupError != null)
            {
                foreach (var p in members)
                {
                    p.R.Fail(CFrom, LabBulkUploadRules.DuplicateInFile, groupError);
                    result.AddFailure(p.R);
                }
                continue;
            }

            await SaveGroupAsync(members, target, ctx, result);
        }
    }

    private async Task SaveGroupAsync(List<ParsedRate> members, LabRateCardHeaderModel? target, BulkContext ctx, LabBulkUploadResult result)
    {
        var first = members[0];
        var details = new Dictionary<string, LabRateCardDetailModel>();
        if (target != null)
        {
            var full = await service.GetByIdAsync(target.RateCard_ID);
            foreach (var d in full?.Details ?? [])
                details[$"{d.Item_Type}|{d.Item_ID}"] = d;
        }

        var seen = new Dictionary<string, int>();
        var inserted = new List<ParsedRate>();
        var updated = new List<ParsedRate>();
        var unchanged = new List<ParsedRate>();
        foreach (var p in members)
        {
            var key = $"{p.RowType}|{p.Item.Item_ID}";
            if (!seen.TryAdd(key, p.R.RowNo))
            {
                p.R.Fail(CItem, LabBulkUploadRules.DuplicateInFile, $"'{p.Item.Item_Name}' is already in row {seen[key]} for the same rate card.");
                result.AddFailure(p.R);
                continue;
            }

            // A test may sit on a card as 'Test' or 'Profile' (its profile flag can change after it was priced).
            var altKey = IsInvestigation(p.RowType) ? $"{(p.RowType == "Test" ? "Profile" : "Test")}|{p.Item.Item_ID}" : null;
            if (details.TryGetValue(key, out var d) || (altKey != null && !seen.ContainsKey(altKey) && details.TryGetValue(altKey, out d)))
            {
                var disc = p.Discount ?? d.Is_Discount_Allowed;
                var status = p.Status ?? d.Status;
                if (d.Rate == p.Rate && d.Is_Discount_Allowed == disc && d.Status == status) { unchanged.Add(p); continue; }
                d.Rate = p.Rate;
                d.Is_Discount_Allowed = disc;
                d.Status = status;
                updated.Add(p);
            }
            else if (!p.Billable)
            {
                p.R.Fail(CItem, LabBulkUploadRules.InvalidRef, $"'{p.Item.Item_Name}' is inactive or not billable, so it cannot be added to a rate card.");
                result.AddFailure(p.R);
            }
            else
            {
                details[$"{p.Item.Item_Type}|{p.Item.Item_ID}"] = new LabRateCardDetailModel
                {
                    Item_Type = p.Item.Item_Type, Item_ID = p.Item.Item_ID, Rate = p.Rate,
                    Is_Discount_Allowed = p.Discount ?? true, Status = p.Status ?? true
                };
                inserted.Add(p);
            }
        }

        var headerChanged = target != null && (target.Effective_From.Date != first.From || target.Effective_To.Date != first.To
                                               || target.Branch_ID != first.BranchId || (IsB2B && target.B2CIdentity_ID != first.FranchiseId));
        if (headerChanged)
        {
            updated.AddRange(unchanged);
            unchanged.Clear();
        }

        if (inserted.Count == 0 && updated.Count == 0)
        {
            result.Unchanged += unchanged.Count;
            return;
        }

        if (!ctx.DryRun)
        {
            try
            {
                await service.SaveAsync(new LabRateCardSaveRequest
                {
                    RateCard_ID = target?.RateCard_ID,
                    CompanyId = ctx.CompanyId,
                    Branch_ID = first.BranchId,
                    B2CIdentity_ID = IsB2B ? first.FranchiseId : null,
                    Rate_Type = rateType,
                    Effective_From = first.From,
                    Effective_To = first.To,
                    Status = target?.Status ?? true,
                    UserId = ctx.UserId,
                    Details = details.Values.ToList()
                });
            }
            catch (Exception ex)
            {
                foreach (var p in inserted.Concat(updated).Concat(unchanged))
                {
                    p.R.Fail(string.Empty, LabBulkUploadRules.SaveFailed, $"Rate card could not be saved: {ex.Message}");
                    result.AddFailure(p.R);
                }
                return;
            }
        }

        result.Inserted += inserted.Count;
        result.Updated += updated.Count;
        result.Unchanged += unchanged.Count;
    }
}
