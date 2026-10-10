using System.Net;
using System.Net.Mail;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>Outcome of sending a card on one channel: Sent, Skipped (switched off / nothing to send to) or Failed.</summary>
public record MembershipCardSendOutcome(string Channel, string Status, string Message);

public interface IMembershipCardDeliveryService
{
    /// <summary>Which channels Hospital Settings has switched on for the branch.</summary>
    Task<(bool WhatsApp, bool Email, bool AutoSendOnIssue)> GetChannelsAsync(int branchId);

    /// <summary>The card as a PDF (front and back), with the branch's name, logo and contact.</summary>
    Task<byte[]> BuildPdfAsync(MembershipCardDetailViewModel card, int branchId);

    /// <summary>
    /// Sends the card PDF to the primary member on every channel switched on in Hospital Settings:
    /// WhatsApp through the branch's WhatsApp configuration, email through its SMTP configuration.
    /// </summary>
    Task<List<MembershipCardSendOutcome>> SendAsync(MembershipCardDetailViewModel card, int branchId);
}

public class MembershipCardDeliveryService(
    ApplicationDbContext db,
    IWhatsAppService whatsAppService,
    IEmailService emailService,
    ILabReportPdfService pdfService,
    IMembershipApiClient apiClient,
    ILogger<MembershipCardDeliveryService> logger) : IMembershipCardDeliveryService
{
    public async Task<(bool WhatsApp, bool Email, bool AutoSendOnIssue)> GetChannelsAsync(int branchId)
    {
        var s = await GetSettingsAsync(branchId);
        return s == null ? (false, false, false) : (s.MembershipCardWhatsAppRequired, s.MembershipCardEmailRequired, s.MembershipCardAutoSendOnIssue);
    }

    public async Task<byte[]> BuildPdfAsync(MembershipCardDetailViewModel card, int branchId)
    {
        var s = await GetSettingsAsync(branchId);
        return MembershipCardPdfDocument.Generate(card, new MembershipCardIssuer
        {
            Name = string.IsNullOrWhiteSpace(s?.HospitalName) ? "Membership" : s!.HospitalName!,
            Contact = s?.ContactNumber1,
            Website = s?.Website,
            Logo = pdfService.LoadLogo(s?.LogoPath)
        });
    }

    public async Task<List<MembershipCardSendOutcome>> SendAsync(MembershipCardDetailViewModel card, int branchId)
    {
        var outcomes = new List<MembershipCardSendOutcome>();
        var settings = await GetSettingsAsync(branchId);
        bool whatsApp = settings?.MembershipCardWhatsAppRequired ?? false;
        bool email = settings?.MembershipCardEmailRequired ?? false;

        if (!whatsApp && !email)
        {
            outcomes.Add(new("Card", "Skipped", "Sending the card by WhatsApp and by email is switched off in Hospital Settings."));
            return outcomes;
        }

        byte[] pdf;
        try
        {
            pdf = await BuildPdfAsync(card, branchId);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[Membership] Card PDF failed for CardId {CardId}", card.CardId);
            outcomes.Add(new("Card", "Failed", "The card PDF could not be generated."));
            return outcomes;
        }

        string hospitalName = string.IsNullOrWhiteSpace(settings?.HospitalName) ? "our lab" : settings!.HospitalName!;
        string template = string.IsNullOrWhiteSpace(settings?.MembershipCardMessageTemplate)
            ? HospitalSettings.DefaultMembershipCardMessage
            : settings!.MembershipCardMessageTemplate;
        string message = template
            .Replace("{PatientName}", card.PatientName)
            .Replace("{HospitalName}", hospitalName)
            .Replace("{PlanName}", card.PlanName)
            .Replace("{CardNo}", card.CardNo)
            .Replace("{ValidFrom}", card.ValidFrom.ToString("dd MMM yyyy"))
            .Replace("{ValidTo}", card.ValidTo.ToString("dd MMM yyyy"))
            .Trim();
        string fileName = $"Membership_Card_{card.CardNo}.pdf";

        if (whatsApp) outcomes.Add(await SendWhatsAppAsync(card, branchId, pdf, message, fileName));
        if (email) outcomes.Add(await SendEmailAsync(card, branchId, pdf, message, fileName, hospitalName));
        return outcomes;
    }

    private async Task<MembershipCardSendOutcome> SendWhatsAppAsync(MembershipCardDetailViewModel card, int branchId, byte[] pdf, string message, string fileName)
    {
        const string channel = "WhatsApp";
        try
        {
            if (string.IsNullOrWhiteSpace(card.PhoneNumber))
                return new(channel, "Skipped", "The primary member has no mobile number.");

            var config = await whatsAppService.GetActiveConfigAsync(branchId);
            if (config == null || !config.IsEnabled)
                return new(channel, "Skipped", "WhatsApp is not configured or is switched off for this branch.");

            var documentUrl = await whatsAppService.UploadMediaAsync(pdf, "application/pdf", branchId);
            if (string.IsNullOrWhiteSpace(documentUrl))
                return new(channel, "Failed", "The card PDF could not be uploaded to WhatsApp.");

            var result = await whatsAppService.SendTextMessageAsync(card.PhoneNumber.Trim(), message, branchId, "MEM", card.CardId, documentUrl, fileName);
            if (!result.Success)
                return new(channel, "Failed", string.IsNullOrWhiteSpace(result.ErrorMessage) ? "WhatsApp did not accept the message." : result.ErrorMessage!);

            await apiClient.MarkSentAsync(card.CardId, card.CompanyId, channel);
            return new(channel, "Sent", $"Sent to {card.PhoneNumber.Trim()}.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[Membership] WhatsApp send failed for CardId {CardId}", card.CardId);
            return new(channel, "Failed", "WhatsApp send failed.");
        }
    }

    private async Task<MembershipCardSendOutcome> SendEmailAsync(MembershipCardDetailViewModel card, int branchId, byte[] pdf, string message, string fileName, string hospitalName)
    {
        const string channel = "Email";
        try
        {
            if (string.IsNullOrWhiteSpace(card.EmailId))
                return new(channel, "Skipped", "The primary member has no email address.");

            string body = $"<p>{WebUtility.HtmlEncode(message).Replace("\n", "<br/>")}</p>"
                        + $"<p style=\"color:#475569;font-size:13px\">Card No: <b>{WebUtility.HtmlEncode(card.CardNo)}</b><br/>"
                        + $"Plan: {WebUtility.HtmlEncode(card.PlanName)}<br/>"
                        + $"Valid: {card.ValidFrom:dd MMM yyyy} to {card.ValidTo:dd MMM yyyy}</p>";

            using var stream = new MemoryStream(pdf);
            using var attachment = new Attachment(stream, fileName, "application/pdf");
            var (success, text) = await emailService.SendEmailAsync(branchId, card.EmailId.Trim(),
                $"Your {card.PlanName} membership card - {hospitalName}", body, [attachment]);
            if (!success)
                return new(channel, text.Contains("No active SMTP", StringComparison.OrdinalIgnoreCase) ? "Skipped" : "Failed", text);

            await apiClient.MarkSentAsync(card.CardId, card.CompanyId, channel);
            return new(channel, "Sent", $"Sent to {card.EmailId.Trim()}.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[Membership] Email send failed for CardId {CardId}", card.CardId);
            return new(channel, "Failed", "Email send failed.");
        }
    }

    private Task<HospitalSettings?> GetSettingsAsync(int branchId) =>
        db.HospitalSettings.AsNoTracking().FirstOrDefaultAsync(h => h.BranchId == branchId);
}
