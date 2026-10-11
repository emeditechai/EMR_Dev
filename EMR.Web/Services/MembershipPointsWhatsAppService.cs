using System.Data;
using Dapper;
using EMR.Web.Data;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// WhatsAppConfig > Notification Trigger Settings > "Membership Points Earned Notification" (SQLScripts/2243): when a
/// B2C LAB bill earns membership points (usp_Membership_SyncBill, once the bill is fully paid), the card holder is sent
/// the branch's configured message. Each EARN entry is sent once (send log with a unique entry id). Runs in the
/// background after the payment / cancellation is saved, so a slow or failing WhatsApp send never blocks billing.
/// </summary>
public interface IMembershipPointsWhatsAppService
{
    /// <summary>Queues the check-and-send for the points this bill (payment header) has earned; returns immediately.</summary>
    void QueueForPayment(int paymentHeaderId, int? userId);

    /// <summary>Sends now; returns how many messages were sent.</summary>
    Task<int> SendForPaymentAsync(int paymentHeaderId, int? userId);
}

public class MembershipPointsWhatsAppService(
    IServiceScopeFactory scopeFactory,
    IDbConnectionFactory db,
    ApplicationDbContext dbContext,
    IWhatsAppService whatsAppService,
    ILogger<MembershipPointsWhatsAppService> logger) : IMembershipPointsWhatsAppService
{
    public const string DefaultTemplate =
        "Dear {CardHolderName}, {PointsEarned} points (worth Rs. {PointsValue}) have been added to your {HospitalName} membership card {CardNo} for Bill {BillNo}. Your balance is now {PointsBalance} points (Rs. {BalanceValue}). These points are valid till {ExpiryDate}. Thank you!";

    private sealed class Pending
    {
        public long LedgerId { get; set; }
        public int CardId { get; set; }
        public int? PaymentHeaderId { get; set; }
        public int BranchId { get; set; }
        public string? CardNo { get; set; }
        public string? PlanName { get; set; }
        public decimal PointsEarned { get; set; }
        public decimal PointsValue { get; set; }
        public decimal PointsBalance { get; set; }
        public decimal BalanceValue { get; set; }
        public DateTime? ExpiresOn { get; set; }
        public string? BillNo { get; set; }
        public string? PatientName { get; set; }
        public string? CardHolderName { get; set; }
        public string? Phone { get; set; }
    }

    public void QueueForPayment(int paymentHeaderId, int? userId)
    {
        if (paymentHeaderId <= 0) return;
        _ = Task.Run(async () =>
        {
            try
            {
                using var scope = scopeFactory.CreateScope();
                var svc = scope.ServiceProvider.GetRequiredService<IMembershipPointsWhatsAppService>();
                await svc.SendForPaymentAsync(paymentHeaderId, userId);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "[MEM-POINTS-WHATSAPP] Unexpected error for PaymentHeaderId {Id}", paymentHeaderId);
            }
        });
    }

    public async Task<int> SendForPaymentAsync(int paymentHeaderId, int? userId)
    {
        List<Pending> rows;
        using (var con = db.CreateConnection())
            rows = (await con.QueryAsync<Pending>("dbo.usp_MembershipPointsWhatsApp_Pending",
                new { PaymentHeaderId = paymentHeaderId }, commandType: CommandType.StoredProcedure)).ToList();
        if (rows.Count == 0) return 0;

        int sent = 0;
        foreach (var r in rows)
        {
            // the branch's trigger switch (and the master switch) decide; nothing is claimed while it is off
            var config = await whatsAppService.GetActiveConfigAsync(r.BranchId);
            if (config == null || !config.IsEnabled || !config.MembershipPointsNotificationEnabled) continue;

            var phone = r.Phone?.Trim();
            int? logId;
            using (var con = db.CreateConnection())
                logId = await con.QueryFirstOrDefaultAsync<int?>("dbo.usp_MembershipPointsWhatsApp_Claim",
                    new { r.LedgerId, r.CardId, r.PaymentHeaderId, r.BranchId, RecipientPhone = phone, UserId = userId },
                    commandType: CommandType.StoredProcedure);
            if (logId is not > 0) continue;   // already sent / being sent

            if (string.IsNullOrWhiteSpace(phone))
            {
                await CompleteAsync(logId.Value, "Skipped", "The card holder has no mobile number.");
                continue;
            }

            try
            {
                var hospitalName = await dbContext.HospitalSettings.AsNoTracking()
                    .Where(s => s.BranchId == r.BranchId && s.IsActive)
                    .OrderByDescending(s => s.Id).Select(s => s.HospitalName).FirstOrDefaultAsync() ?? string.Empty;
                var template = string.IsNullOrWhiteSpace(config.MembershipPointsMessageTemplate) ? DefaultTemplate : config.MembershipPointsMessageTemplate;
                var message = template
                    .Replace("{CardHolderName}", r.CardHolderName ?? r.PatientName ?? string.Empty)
                    .Replace("{PatientName}", r.PatientName ?? string.Empty)
                    .Replace("{HospitalName}", hospitalName)
                    .Replace("{CardNo}", r.CardNo ?? string.Empty)
                    .Replace("{PlanName}", r.PlanName ?? string.Empty)
                    .Replace("{BillNo}", r.BillNo ?? string.Empty)
                    .Replace("{PointsEarned}", r.PointsEarned.ToString("0.##"))
                    .Replace("{PointsValue}", r.PointsValue.ToString("N2"))
                    .Replace("{PointsBalance}", r.PointsBalance.ToString("0.##"))
                    .Replace("{BalanceValue}", r.BalanceValue.ToString("N2"))
                    .Replace("{ExpiryDate}", r.ExpiresOn?.ToString("dd MMM yyyy") ?? "-")
                    .Trim();

                var result = await whatsAppService.SendTextMessageAsync(phone, message, r.BranchId, "MEM_POINTS", (int)r.LedgerId);
                if (result.Success) { sent++; await CompleteAsync(logId.Value, "Sent", $"Sent to {phone}."); }
                else await CompleteAsync(logId.Value, "Failed", result.ErrorMessage ?? "WhatsApp send failed.");
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "[MEM-POINTS-WHATSAPP] Failed for ledger entry {LedgerId}", r.LedgerId);
                await CompleteAsync(logId.Value, "Failed", ex.Message);
            }
        }
        return sent;
    }

    private async Task CompleteAsync(int logId, string status, string message)
    {
        try
        {
            using var con = db.CreateConnection();
            await con.ExecuteAsync("dbo.usp_MembershipPointsWhatsApp_Complete", new { LogId = logId, Status = status, Message = message },
                commandType: CommandType.StoredProcedure);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[MEM-POINTS-WHATSAPP] Could not record status {Status} for log {LogId}", status, logId);
        }
    }
}
