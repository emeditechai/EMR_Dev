using System.Text.Json;
using EMR.Web.ApiClients;

namespace EMR.Web.Services;

/// <summary>One sales channel of the pharmacy: POS (walk-in), DIRECT (patient / credit customer) or IPD (admitted patients).</summary>
public class PhSalesChannel
{
    public string Channel { get; set; } = "";
    public string Label { get; set; } = "";
    public int Bills { get; set; }
    public decimal Gross { get; set; }
    public int ReturnCount { get; set; }
    public decimal Returns { get; set; }
    public decimal Net { get; set; }
    public decimal Cost { get; set; }
    public decimal Paid { get; set; }
    public decimal Due { get; set; }
    public decimal Discount { get; set; }
    public int Buyers { get; set; }
    public decimal PrevNet { get; set; }
    public int PrevBills { get; set; }

    public decimal Margin => Net - Cost;
    public decimal MarginPct => Net == 0 ? 0 : Margin * 100 / Net;
    public decimal AvgBill => Bills == 0 ? 0 : Gross / Bills;
    /// <summary>Change of net sales against the same length of time just before; null when there was nothing to compare.</summary>
    public decimal? Delta => PrevNet == 0 ? null : (Net - PrevNet) * 100 / Math.Abs(PrevNet);
}

public class PhSalesDay { public DateTime Day { get; set; } public decimal Pos { get; set; } public decimal Direct { get; set; } public decimal Ipd { get; set; } }
public class PhSalesMode { public string Mode { get; set; } = ""; public decimal Pos { get; set; } public decimal Direct { get; set; } }
public class PhSalesItem { public string ItemName { get; set; } = ""; public decimal Qty { get; set; } public decimal Value { get; set; } public decimal Pos { get; set; } public decimal Direct { get; set; } public decimal Ipd { get; set; } }

/// <summary>A document in the list: a pharmacy bill (POS / Direct) or an IPD issue.</summary>
public class PhSalesDoc
{
    public string Channel { get; set; } = "";
    public int DocId { get; set; }
    public int? RefId { get; set; }          // PatientId of a bill, AdmissionId of an IPD issue
    public string? DocNo { get; set; }
    public DateTime DocAt { get; set; }
    public string? Party { get; set; }
    public string? PartyRef { get; set; }    // UHID / IP number / "Credit customer"
    public string? Mobile { get; set; }
    public string? Doctor { get; set; }
    public int Items { get; set; }
    public decimal Amount { get; set; }
    public decimal Returned { get; set; }
    public decimal Net { get; set; }
    public decimal Paid { get; set; }
    public decimal Due { get; set; }
    public string Status { get; set; } = "";
    public string? CreatedBy { get; set; }
}

public class PhSalesDocTotals
{
    public int TotalRows { get; set; }
    public decimal Amount { get; set; }
    public decimal Returned { get; set; }
    public decimal Net { get; set; }
    public decimal Paid { get; set; }
    public decimal Due { get; set; }
    public int Cancelled { get; set; }
}

public class PhSalesDashboard
{
    public DateTime From { get; set; }
    public DateTime To { get; set; }
    public string? Channel { get; set; }
    public string? Search { get; set; }
    public string? Range { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 25;

    public List<PhSalesChannel> Channels { get; set; } = [];
    public List<PhSalesDay> Days { get; set; } = [];
    public List<PhSalesMode> Modes { get; set; } = [];
    public List<PhSalesItem> TopItems { get; set; } = [];
    public List<PhSalesDoc> Docs { get; set; } = [];
    public PhSalesDocTotals Totals { get; set; } = new();

    public PhSalesChannel Of(string channel) => Channels.FirstOrDefault(c => c.Channel == channel) ?? new PhSalesChannel { Channel = channel, Label = channel };
    public decimal TotalNet => Channels.Sum(c => c.Net);
    public decimal TotalPrevNet => Channels.Sum(c => c.PrevNet);
    public int TotalBills => Channels.Sum(c => c.Bills);
    public decimal TotalReturns => Channels.Sum(c => c.Returns);
    public decimal TotalMargin => Channels.Sum(c => c.Margin);
    public decimal TotalDue => Channels.Sum(c => c.Due);
    public int Pages => PageSize <= 0 ? 1 : Math.Max(1, (int)Math.Ceiling(Totals.TotalRows / (double)PageSize));
}

public interface IPharmacySalesDashboardService
{
    Task<PhSalesDashboard> GetAsync(int companyId, int branchId, DateTime from, DateTime to, string? channel, string? search, int page, int pageSize);
}

/// <summary>Pharmacy > Sales > Sales Dashboard through EMR.Api (api/pharmacy/sales-dashboard, SQLScripts/2568).</summary>
public class PharmacySalesDashboardService(PharmacyApiClient api) : IPharmacySalesDashboardService
{
    private static T Row<T>(JsonElement e) => e.Deserialize<T>(PharmacyApiClient.Json)!;

    public async Task<PhSalesDashboard> GetAsync(int companyId, int branchId, DateTime from, DateTime to, string? channel, string? search, int page, int pageSize)
    {
        var sets = await api.GetAsync<List<List<JsonElement>>>("api/pharmacy/sales-dashboard" + PharmacyApiClient.Q(
            ("companyId", companyId), ("branchId", branchId), ("from", from), ("to", to), ("channel", channel), ("search", search),
            ("page", page), ("pageSize", pageSize)));
        return new PhSalesDashboard
        {
            From = from, To = to, Channel = channel, Search = search, Page = page, PageSize = pageSize,
            Channels = sets[0].Select(Row<PhSalesChannel>).ToList(),
            Days = sets[1].Select(Row<PhSalesDay>).ToList(),
            Modes = sets[2].Select(Row<PhSalesMode>).ToList(),
            TopItems = sets[3].Select(Row<PhSalesItem>).ToList(),
            Docs = sets[4].Select(Row<PhSalesDoc>).ToList(),
            Totals = sets[5].Count > 0 ? Row<PhSalesDocTotals>(sets[5][0]) : new()
        };
    }
}
