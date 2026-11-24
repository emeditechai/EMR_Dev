using EMR.Web.Extensions;
using EMR.Web.Services.Notifications;

namespace EMR.Web.Services;

/// <summary>
/// Pharmacy auto indent (SQLScripts/2538): after an auto indent run, tells the Approval Matrix approvers of
/// PHARMACY.PURCHASEINDENT (by branch) that a system-raised indent waits for them, with a link to it.
/// Used by <see cref="PharmacyAutoIndentWorker"/> and the page's "Run now". Never throws.
/// </summary>
public interface IPharmacyAutoIndentNotifier
{
    Task NotifyAsync(int companyId, int branchId, PhAutoIndentRunResult result, int? actorUserId);
}

public class PharmacyAutoIndentNotifier(IPharmacyInventoryService inventory, INotificationService notifications,
    IQueryStringEncryptionService encryption, ILogger<PharmacyAutoIndentNotifier> logger) : IPharmacyAutoIndentNotifier
{
    private const string Module = "PHARMACY.PURCHASEINDENT";

    public async Task NotifyAsync(int companyId, int branchId, PhAutoIndentRunResult result, int? actorUserId)
    {
        if (result.IsError || result.Indents.Count == 0) return;
        try
        {
            var approvers = (await inventory.MatrixApproversAsync(companyId, Module, branchId)).Where(u => u != actorUserId).ToList();
            if (approvers.Count == 0) return;   // no matrix: anyone with the page's APPROVE control approves it from the indent list
            foreach (var i in result.Indents)
            {
                var link = QueryStringEncryptionExtensions.AppendEncrypted("/PhPurchaseIndents/Form", encryption, new { id = i.IndentId });
                var title = i.IsNew ? "Auto purchase indent to approve" : "Items added to an auto purchase indent";
                var msg = i.IsNew
                    ? $"Auto indent {i.IndentNo} for {i.SupplierName}: {i.Lines} item(s) at or below the reorder level."
                    : $"{i.Lines} more item(s) reached the reorder level and were added to auto indent {i.IndentNo} ({i.SupplierName}).";
                await notifications.NotifyUsersAsync(approvers, "PHARMACY_APPROVAL", "INFO", title, msg, link, "PHARMACY", i.IndentId,
                    $"{Module}:AUTO:{i.IndentId}:{DateTime.Now:yyyyMMddHHmmss}", branchId, actorUserId);
            }
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[PH-AUTOINDENT] notifying approvers failed (branch {BranchId})", branchId);
        }
    }
}

/// <summary>
/// Pharmacy auto indent (SQLScripts/2538): every minute, for each branch with Hospital Settings > MED > Auto Indent on and at
/// least one active rule, checks the items that moved in the stock ledger since the last check (a sale, issue, transfer ...)
/// and raises / adds to the supplier's auto indent when an item is at or below its reorder level. The sale itself is
/// never touched: the check runs here, after it, through EMR.Api (usp_Api_PhAutoIndent_Run).
/// </summary>
public sealed class PharmacyAutoIndentWorker(IServiceScopeFactory scopeFactory, ILogger<PharmacyAutoIndentWorker> logger) : BackgroundService
{
    private static readonly TimeSpan Interval = TimeSpan.FromMinutes(1);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try { await Task.Delay(TimeSpan.FromMinutes(2), stoppingToken); } catch (OperationCanceledException) { return; }
        while (!stoppingToken.IsCancellationRequested)
        {
            try { await RunOnceAsync(stoppingToken); }
            catch (Exception ex) when (!stoppingToken.IsCancellationRequested) { logger.LogError(ex, "[PH-AUTOINDENT] check failed"); }
            try { await Task.Delay(Interval, stoppingToken); } catch (OperationCanceledException) { return; }
        }
    }

    private async Task RunOnceAsync(CancellationToken ct)
    {
        using var scope = scopeFactory.CreateScope();
        var purchase = scope.ServiceProvider.GetRequiredService<IPharmacyPurchaseService>();
        var notifier = scope.ServiceProvider.GetRequiredService<IPharmacyAutoIndentNotifier>();
        foreach (var b in await purchase.AutoIndentBranchesAsync())
        {
            if (ct.IsCancellationRequested) return;
            try
            {
                var res = await purchase.AutoIndentRunAsync(b.CompanyId, b.BranchId, null, manual: false);
                if (res.IsError) logger.LogWarning("[PH-AUTOINDENT] branch {BranchId}: {Message}", b.BranchId, res.Message);
                else if (res.LinesRaised > 0)
                {
                    logger.LogInformation("[PH-AUTOINDENT] branch {BranchId}: {Message}", b.BranchId, res.Message);
                    await notifier.NotifyAsync(b.CompanyId, b.BranchId, res, null);
                }
            }
            catch (Exception ex) { logger.LogError(ex, "[PH-AUTOINDENT] branch {BranchId} failed", b.BranchId); }
        }
    }
}
