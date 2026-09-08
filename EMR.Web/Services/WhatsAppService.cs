using System;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace EMR.Web.Services;

public class WhatsAppService(
    IServiceScopeFactory scopeFactory,
    IHttpClientFactory httpClientFactory,
    ILogger<WhatsAppService> logger) : IWhatsAppService
{
    // ── Global rate-limit gate: serialises ALL sends across every background task ──
    // WaSender Account Protection allows only 1 message / 5 seconds.
    private static readonly SemaphoreSlim _sendGate   = new SemaphoreSlim(1, 1);
    private static          DateTime      _lastSentUtc = DateTime.MinValue;
    private const           int           _minGapMs    = 5500;   // 5.5 s gap between sends
    private const           int           _maxRetries  = 10;     // retry up to 10× on rate-limit

    public async Task<WhatsAppConfiguration?> GetActiveConfigAsync(int branchId)
    {
        using var scope = scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();

        // 1. First look for branch-specific configuration
        var branchConfig = await db.WhatsAppConfigurations
            .AsNoTracking()
            .FirstOrDefaultAsync(c => c.BranchId == branchId && c.IsActive);

        if (branchConfig != null)
        {
            return branchConfig;
        }

        // 2. Fallback to default (HO) configuration only if this branch has no configuration entry at all
        var defaultConfig = await db.WhatsAppConfigurations
            .AsNoTracking()
            .FirstOrDefaultAsync(c => c.IsDefault && c.IsActive);

        return defaultConfig;
    }

    public async Task<string?> UploadMediaAsync(byte[] fileBytes, string mimeType, int branchId)
    {
        try
        {
            var config = await GetActiveConfigAsync(branchId);
            if (config == null || string.IsNullOrWhiteSpace(config.ApiKey))
            {
                return null;
            }

            var token = config.ApiKey.Trim();
            if (token.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            {
                token = token.Substring(7).Trim();
            }

            var uploadUrl = "https://wasenderapi.com/api/upload";
            if (!string.IsNullOrWhiteSpace(config.ApiUrl) && config.ApiUrl.Contains("/api/"))
            {
                uploadUrl = config.ApiUrl.Substring(0, config.ApiUrl.IndexOf("/api/")) + "/api/upload";
            }

            var client = httpClientFactory.CreateClient();
            client.Timeout = TimeSpan.FromSeconds(35);

            var uploadPayload = new
            {
                mimetype = mimeType,
                base64 = Convert.ToBase64String(fileBytes)
            };

            var request = new HttpRequestMessage(HttpMethod.Post, uploadUrl)
            {
                Content = new StringContent(JsonSerializer.Serialize(uploadPayload), Encoding.UTF8, "application/json")
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

            var response = await client.SendAsync(request);
            var json = await response.Content.ReadAsStringAsync();

            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.TryGetProperty("success", out var succ) && succ.ValueKind == JsonValueKind.True)
            {
                if (root.TryGetProperty("publicUrl", out var urlProp))
                {
                    return urlProp.GetString();
                }
            }
            logger.LogWarning("[WhatsApp] Media upload failed: {Response}", json);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[WhatsApp] Exception while uploading media");
        }

        return null;
    }

    public async Task<WhatsAppSendResult> SendTextMessageAsync(
        string to, string text, int branchId, string moduleCode = "TEST", int? moduleRefId = null, string? documentUrl = null, string? fileName = null)
    {
        var result = new WhatsAppSendResult();
        var config = await GetActiveConfigAsync(branchId);

        if (config == null || string.IsNullOrWhiteSpace(config.ApiKey))
        {
            result.Success = false;
            result.ErrorMessage = "No active WhatsApp configuration found or API Key is missing.";
            logger.LogWarning("[WhatsApp] Send failed: {Error} for Branch {BranchId}", result.ErrorMessage, branchId);
            return result;
        }

        var formattedPhone = FormatPhoneNumber(to, config.DefaultCountryCode);
        if (string.IsNullOrWhiteSpace(formattedPhone))
        {
            result.Success = false;
            result.ErrorMessage = $"Invalid recipient phone number: '{to}'.";
            logger.LogWarning("[WhatsApp] Send failed: {Error}", result.ErrorMessage);
            return result;
        }

        // Format token
        var token     = config.ApiKey.Trim();
        if (token.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            token = token.Substring(7).Trim();
        var headerKey = string.IsNullOrWhiteSpace(config.AuthHeaderKey) ? "Authorization" : config.AuthHeaderKey.Trim();

        // Serialize JSON payload once
        var jsonContent = string.IsNullOrWhiteSpace(documentUrl)
            ? JsonSerializer.Serialize(new { to = formattedPhone, text })
            : JsonSerializer.Serialize(new { to = formattedPhone, text, documentUrl, fileName = fileName ?? "document.pdf" });

        string rawResponse = string.Empty;

        // ── Acquire global send gate — ensures only 1 WA message at a time ────────
        await _sendGate.WaitAsync();
        try
        {
            // Enforce minimum 5.5 s gap between any two sends
            var elapsed = (DateTime.UtcNow - _lastSentUtc).TotalMilliseconds;
            if (elapsed < _minGapMs)
            {
                var delayMs = (int)(_minGapMs - elapsed);
                logger.LogInformation("[WhatsApp] Gap enforced: waiting {ms}ms before sending to {Phone}", delayMs, formattedPhone);
                await Task.Delay(delayMs);
            }

            // ── Retry loop: keep retrying on rate-limit until success or max retries ──
            for (int attempt = 1; attempt <= _maxRetries; attempt++)
            {
                HttpRequestMessage BuildReq() {
                    var req = new HttpRequestMessage(HttpMethod.Post, config.ApiUrl)
                    {
                        Content = new StringContent(jsonContent, Encoding.UTF8, "application/json")
                    };
                    if (headerKey.Equals("Authorization", StringComparison.OrdinalIgnoreCase))
                        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                    else
                        req.Headers.TryAddWithoutValidation(headerKey, "Bearer " + token);
                    return req;
                }

                try
                {
                    var httpClient = httpClientFactory.CreateClient();
                    httpClient.Timeout = TimeSpan.FromSeconds(25);

                    var response = await httpClient.SendAsync(BuildReq());
                    rawResponse  = await response.Content.ReadAsStringAsync();
                    _lastSentUtc = DateTime.UtcNow; // stamp after every actual send
                    result.RawResponse = rawResponse;

                    using var doc  = JsonDocument.Parse(rawResponse);
                    var       root = doc.RootElement;

                    bool isSuccess = root.TryGetProperty("success", out var sp) && sp.ValueKind == JsonValueKind.True;

                    if (isSuccess)
                    {
                        result.Success = true;
                        if (root.TryGetProperty("data", out var dp) && dp.ValueKind == JsonValueKind.Object)
                        {
                            if (dp.TryGetProperty("msgId",  out var mi)) result.MsgId  = mi.ToString();
                            if (dp.TryGetProperty("jid",    out var ji)) result.Jid    = ji.GetString();
                            if (dp.TryGetProperty("status", out var si)) result.Status = si.GetString();
                        }
                        logger.LogInformation("[WhatsApp] Sent to {Phone} on attempt {A}", formattedPhone, attempt);
                        break; // ✅ done
                    }

                    // Check if this is a rate-limit error
                    bool isRateLimit = root.TryGetProperty("retry_after", out var raProp);
                    if (!isRateLimit)
                    {
                        // Non-rate-limit error (wrong number, bad token, etc.) — do not retry
                        if (root.TryGetProperty("message", out var mp)) result.ErrorMessage = mp.GetString();
                        logger.LogWarning("[WhatsApp] Non-retryable error for {Phone}: {Err}", formattedPhone, result.ErrorMessage);
                        break;
                    }

                    if (attempt >= _maxRetries)
                    {
                        result.ErrorMessage = $"Rate limit persisted after {_maxRetries} retries.";
                        logger.LogError("[WhatsApp] Rate limit: max retries ({M}) exhausted for {Phone}", _maxRetries, formattedPhone);
                        break;
                    }

                    // Wait as instructed by WaSender and retry
                    int waitSec = Math.Max(raProp.GetInt32(), 5) + 1;
                    logger.LogWarning("[WhatsApp] Rate limited (attempt {A}/{M}). Retrying in {S}s for {Phone}...",
                        attempt, _maxRetries, waitSec, formattedPhone);
                    await Task.Delay(TimeSpan.FromSeconds(waitSec));
                }
                catch (Exception ex)
                {
                    result.Success      = false;
                    result.ErrorMessage = ex.Message;
                    logger.LogError(ex, "[WhatsApp] HTTP exception on attempt {A} for {Phone}", attempt, formattedPhone);
                    break; // network error — do not retry
                }
            }
        }
        finally
        {
            _sendGate.Release();
        }

        // ── Log result to DB ───────────────────────────────────────────────────────
        try
        {
            using var scope = scopeFactory.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();

            var logEntry = new WhatsAppLog
            {
                ConfigId       = config.Id,
                BranchId       = branchId,
                ModuleCode     = moduleCode,
                ModuleRefId    = moduleRefId,
                RecipientPhone = formattedPhone,
                MessageText    = text,
                IsSuccess      = result.Success,
                MsgId          = result.MsgId,
                Jid            = result.Jid,
                Status         = result.Status ?? (result.Success ? "sent" : "failed"),
                ApiResponse    = rawResponse,
                ErrorMessage   = result.ErrorMessage,
                SentDate       = DateTime.Now
            };

            db.WhatsAppLogs.Add(logEntry);

            if (moduleCode == "TEST")
            {
                var trackedConfig = await db.WhatsAppConfigurations.FindAsync(config.Id);
                if (trackedConfig != null)
                {
                    trackedConfig.LastTestedDate  = DateTime.Now;
                    trackedConfig.LastTestResult  = result.Success ? "Success: Message queued" : $"Failed: {result.ErrorMessage}";
                }
            }

            await db.SaveChangesAsync();
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[WhatsApp] Failed to save WhatsAppLog to database.");
        }

        return result;
    }

    public async Task TriggerOpdBillWhatsAppAsync(int branchId, int opdServiceId, string? pdfPath = null, string? hostUrl = null)
    {
        string? generatedTempPdf = null;
        try
        {
            using var scope = scopeFactory.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();

            // Wait briefly for token generation if needed (up to 5 attempts)
            PatientOPDService? booking = null;
            for (int i = 0; i < 5; i++)
            {
                booking = await db.PatientOPDServices.AsNoTracking().FirstOrDefaultAsync(b => b.OPDServiceId == opdServiceId);
                if (booking != null && (!string.IsNullOrWhiteSpace(booking.TokenNo) || booking.TotalAmount == 0))
                    break;

                await Task.Delay(2500);
            }

            if (booking == null)
            {
                logger.LogWarning("[WhatsApp] OPD Service ID {Id} not found.", opdServiceId);
                return;
            }

            // Ensure we use the branch ID from the booking record if available
            if (booking.BranchId.HasValue && booking.BranchId.Value > 0)
            {
                branchId = booking.BranchId.Value;
            }

            var config = await GetActiveConfigAsync(branchId);
            if (config == null || !config.IsEnabled || !config.OpdNotificationEnabled)
            {
                logger.LogInformation("[WhatsApp] OPD notification disabled or not configured for branch {BranchId}", branchId);
                return;
            }

            var patient = await db.Database.GetDbConnection().QueryFirstOrDefaultAsync<dynamic>(
                "SELECT FirstName, LastName, PhoneNumber FROM dbo.PatientMaster WHERE PatientId = @Id",
                new { Id = booking.PatientId });

            if (patient == null || string.IsNullOrWhiteSpace((string?)patient.PhoneNumber))
            {
                logger.LogInformation("[WhatsApp] Patient mobile number not found for PatientId {Id}", booking.PatientId);
                return;
            }

            string patientPhone = ((string)patient.PhoneNumber).Trim();
            string patientName = $"{patient.FirstName} {patient.LastName}".Trim();

            var hospital = await db.HospitalSettings.AsNoTracking().FirstOrDefaultAsync(h => h.BranchId == branchId);
            string hospitalName = hospital?.HospitalName ?? "Our Clinic";
            string rawBillNo = booking.OPDBillNo ?? $"OPD_{opdServiceId}";
            string safeBillNo = rawBillNo.Replace("/", "_").Replace("\\", "_");

            string doctorName = "Attending Physician";
            if (booking.ConsultingDoctorId.HasValue)
            {
                var doc = await db.Database.GetDbConnection().QueryFirstOrDefaultAsync<string>(
                    "SELECT FullName FROM dbo.DoctorMaster WHERE DoctorId = @DocId",
                    new { DocId = booking.ConsultingDoctorId.Value });
                if (!string.IsNullOrWhiteSpace(doc)) doctorName = doc;
            }

            // Handle bill PDF attachment
            string? documentUrl = null;
            string? fileName = null;

            // If pdfPath not passed or doesn't exist, try to generate it if hostUrl is provided
            if ((string.IsNullOrWhiteSpace(pdfPath) || !File.Exists(pdfPath)) && !string.IsNullOrWhiteSpace(hostUrl))
            {
                try
                {
                    generatedTempPdf = Path.Combine(Path.GetTempPath(), $"OPD_Bill_{safeBillNo}_{Guid.NewGuid():N}.pdf");
                    var secret = Convert.ToBase64String(Encoding.UTF8.GetBytes($"bill-{opdServiceId}-emr"));
                    var billUrl = $"{hostUrl}/OPD/PrintBillAnonymous?id={opdServiceId}&secret={Uri.EscapeDataString(secret)}";
                    var chromeArgs = $"--headless --disable-gpu --ignore-certificate-errors --print-to-pdf=\"{generatedTempPdf}\" \"{billUrl}\"";

                    using var process = new System.Diagnostics.Process();
                    process.StartInfo.FileName = OperatingSystem.IsWindows() ? "chrome" : "google-chrome";
                    if (OperatingSystem.IsMacOS()) process.StartInfo.FileName = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
                    process.StartInfo.Arguments = chromeArgs;
                    process.StartInfo.UseShellExecute = true;
                    process.Start();
                    await process.WaitForExitAsync();

                    if (File.Exists(generatedTempPdf))
                    {
                        pdfPath = generatedTempPdf;
                    }
                }
                catch (Exception ex)
                {
                    logger.LogWarning(ex, "[WhatsApp] Failed generating OPD bill PDF on-demand for OPDServiceId {Id}", opdServiceId);
                }
            }

            // Upload PDF if available
            if (!string.IsNullOrWhiteSpace(pdfPath) && File.Exists(pdfPath))
            {
                try
                {
                    var pdfBytes = await File.ReadAllBytesAsync(pdfPath);
                    if (pdfBytes != null && pdfBytes.Length > 0)
                    {
                        logger.LogInformation("[WhatsApp] Uploading OPD bill PDF ({Bytes} bytes) for OPDServiceId {Id}", pdfBytes.Length, opdServiceId);
                        documentUrl = await UploadMediaAsync(pdfBytes, "application/pdf", branchId);
                        if (!string.IsNullOrWhiteSpace(documentUrl))
                        {
                            fileName = $"OPD_Bill_{safeBillNo}.pdf";
                            logger.LogInformation("[WhatsApp] OPD bill PDF uploaded successfully: {Url}", documentUrl);
                        }
                    }
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "[WhatsApp] Error uploading OPD bill PDF for OPDServiceId {Id}", opdServiceId);
                }
            }

            // Build Message from Template
            string messageTemplate = config.OpdMessageTemplate;
            if (string.IsNullOrWhiteSpace(messageTemplate))
            {
                messageTemplate = "Dear {PatientName}, thank you for visiting {HospitalName}. Your OPD Bill {BillNo} of Rs. {Amount} has been generated. Token: {TokenNo}, Doctor: {DoctorName}. Please find your bill attached. Wish you a speedy recovery!";
            }

            string message = messageTemplate
                .Replace("{PatientName}", patientName)
                .Replace("{HospitalName}", hospitalName)
                .Replace("{BillNo}", booking.OPDBillNo ?? string.Empty)
                .Replace("{TokenNo}", booking.TokenNo ?? "—")
                .Replace("{DoctorName}", doctorName)
                .Replace("{Amount}", (booking.TotalAmount ?? 0m).ToString("N2"))
                .Trim();

            await SendTextMessageAsync(patientPhone, message, branchId, "OPD", opdServiceId, documentUrl, fileName);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[WhatsApp] Error executing TriggerOpdBillWhatsAppAsync for OPDServiceId {Id}", opdServiceId);
        }
        finally
        {
            if (!string.IsNullOrWhiteSpace(generatedTempPdf) && File.Exists(generatedTempPdf))
            {
                try { File.Delete(generatedTempPdf); } catch { }
            }
        }
    }

    public async Task TriggerLabBillWhatsAppAsync(int branchId, int labOrderId, string? pdfPath = null, string? hostUrl = null)
    {
        string? generatedTempPdf = null;
        try
        {
            using var scope = scopeFactory.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();

            var labOrder = await db.Database.GetDbConnection().QueryFirstOrDefaultAsync<dynamic>(
                "SELECT LabOrderId, BranchId, PatientId, BillNo, TokenNo, TotalAmount FROM dbo.LabOrder WHERE LabOrderId = @Id",
                new { Id = labOrderId });

        if (labOrder == null)
        {
            logger.LogWarning("[WhatsApp] LabOrderId {Id} not found.", labOrderId);
            return;
        }

        if (labOrder.BranchId != null && (int)labOrder.BranchId > 0)
        {
            branchId = (int)labOrder.BranchId;
        }

        var config = await GetActiveConfigAsync(branchId);
        if (config == null || !config.IsEnabled || !config.LabNotificationEnabled)
        {
            logger.LogInformation("[WhatsApp] LAB notification disabled or not configured for branch {BranchId}", branchId);
            return;
        }

            int patientId = (int)labOrder.PatientId;
            var patient = await db.Database.GetDbConnection().QueryFirstOrDefaultAsync<dynamic>(
                "SELECT FirstName, LastName, PhoneNumber FROM dbo.PatientMaster WHERE PatientId = @Id",
                new { Id = patientId });

            if (patient == null || string.IsNullOrWhiteSpace((string?)patient.PhoneNumber))
            {
                logger.LogInformation("[WhatsApp] Patient mobile number not found for Lab Order PatientId {Id}", patientId);
                return;
            }

            string patientPhone = ((string)patient.PhoneNumber).Trim();
            string patientName = $"{patient.FirstName} {patient.LastName}".Trim();

            var hospital = await db.HospitalSettings.AsNoTracking().FirstOrDefaultAsync(h => h.BranchId == branchId);
            string hospitalName = hospital?.HospitalName ?? "Our Diagnostic Lab";
            string rawBillNo = (string?)labOrder.BillNo ?? $"Bill_{labOrderId}";
            string safeBillNo = rawBillNo.Replace("/", "_").Replace("\\", "_");

            // Handle bill PDF attachment
            string? documentUrl = null;
            string? fileName = null;

            // If pdfPath not passed or doesn't exist, try to generate it if hostUrl is provided
            if ((string.IsNullOrWhiteSpace(pdfPath) || !File.Exists(pdfPath)) && !string.IsNullOrWhiteSpace(hostUrl))
            {
                try
                {
                    generatedTempPdf = Path.Combine(Path.GetTempPath(), $"Lab_Bill_{safeBillNo}_{Guid.NewGuid():N}.pdf");
                    var secret = "lab_print_" + labOrderId.ToString();
                    var billUrl = $"{hostUrl}/LabOrderBooking/PrintBillAnonymous?labOrderId={labOrderId}&secret={Uri.EscapeDataString(secret)}";
                    var chromeArgs = $"--headless --disable-gpu --ignore-certificate-errors --print-to-pdf=\"{generatedTempPdf}\" \"{billUrl}\"";

                    using var process = new System.Diagnostics.Process();
                    process.StartInfo.FileName = OperatingSystem.IsWindows() ? "chrome" : "google-chrome";
                    if (OperatingSystem.IsMacOS()) process.StartInfo.FileName = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
                    process.StartInfo.Arguments = chromeArgs;
                    process.StartInfo.UseShellExecute = true;
                    process.Start();
                    await process.WaitForExitAsync();

                    if (File.Exists(generatedTempPdf))
                    {
                        pdfPath = generatedTempPdf;
                    }
                }
                catch (Exception ex)
                {
                    logger.LogWarning(ex, "[WhatsApp] Failed generating bill PDF on-demand for LabOrderId {Id}", labOrderId);
                }
            }

            // Upload PDF if available
            if (!string.IsNullOrWhiteSpace(pdfPath) && File.Exists(pdfPath))
            {
                try
                {
                    var pdfBytes = await File.ReadAllBytesAsync(pdfPath);
                    if (pdfBytes != null && pdfBytes.Length > 0)
                    {
                        logger.LogInformation("[WhatsApp] Uploading Lab bill PDF ({Bytes} bytes) for LabOrderId {Id}", pdfBytes.Length, labOrderId);
                        documentUrl = await UploadMediaAsync(pdfBytes, "application/pdf", branchId);
                        if (!string.IsNullOrWhiteSpace(documentUrl))
                        {
                            fileName = $"Lab_Bill_{safeBillNo}.pdf";
                            logger.LogInformation("[WhatsApp] Lab bill PDF uploaded successfully: {Url}", documentUrl);
                        }
                    }
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "[WhatsApp] Error uploading bill PDF for LabOrderId {Id}", labOrderId);
                }
            }

            // Build Message from Template (Exclude test details as requested)
            string messageTemplate = config.LabMessageTemplate;
            if (string.IsNullOrWhiteSpace(messageTemplate))
            {
                messageTemplate = "Dear {PatientName}, thank you for choosing {HospitalName}. Your Lab Order {BillNo} of Rs. {Amount} has been registered. Token: {TokenNo}. Please find your bill attached. Thank you!";
            }

            // Remove any investigation/test listings from template to fulfill request cleanly
            messageTemplate = Regex.Replace(messageTemplate, @"Investigations:\s*\{TestNames\}\.?\s*", "", RegexOptions.IgnoreCase);
            messageTemplate = messageTemplate.Replace("{TestNames}", "").Trim();

            decimal totalAmount = (decimal)(labOrder.TotalAmount ?? 0m);
            string message = messageTemplate
                .Replace("{PatientName}", patientName)
                .Replace("{HospitalName}", hospitalName)
                .Replace("{BillNo}", (string?)labOrder.BillNo ?? string.Empty)
                .Replace("{TokenNo}", (string?)labOrder.TokenNo ?? "—")
                .Replace("{Amount}", totalAmount.ToString("N2"))
                .Trim();

            await SendTextMessageAsync(patientPhone, message, branchId, "LAB", labOrderId, documentUrl, fileName);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[WhatsApp] Error executing TriggerLabBillWhatsAppAsync for LabOrderId {Id}", labOrderId);
        }
        finally
        {
            if (!string.IsNullOrWhiteSpace(generatedTempPdf) && File.Exists(generatedTempPdf))
            {
                try { File.Delete(generatedTempPdf); } catch { }
            }
        }
    }

    public async Task TriggerVideoConsultationWhatsAppAsync(int branchId, int opdServiceId, string patientPhone, string doctorPhone, string patientName, string doctorName, string date, string time, string patientLink, string doctorLink)
    {
        try
        {
            var config = await GetActiveConfigAsync(branchId);
            if (config == null || !config.IsEnabled || !config.VideoNotificationEnabled)
            {
                logger.LogInformation("[WhatsApp] Video notification disabled or not configured for branch {BranchId}", branchId);
                return;
            }

            // 1. Send Patient Message
            if (!string.IsNullOrWhiteSpace(patientPhone))
            {
                string patientTemplate = config.VideoPatientMessageTemplate;
                if (string.IsNullOrWhiteSpace(patientTemplate))
                    patientTemplate = "Dear {PatientName}, your Video Consultation with Dr. {DoctorName} on {Date} at {Time} is confirmed. Join using: {Link}";

                string patientMessage = patientTemplate
                    .Replace("{PatientName}", patientName)
                    .Replace("{DoctorName}", doctorName)
                    .Replace("{Date}", date)
                    .Replace("{Time}", time)
                    .Replace("{Link}", patientLink)
                    .Trim();

                await SendTextMessageAsync(patientPhone, patientMessage, branchId, "VIDEO", opdServiceId);
            }

            // ── Rate-limit guard: WaSender allows 1 message/5 sec ────────────
            await Task.Delay(6000);

            // 2. Send Doctor Message
            if (!string.IsNullOrWhiteSpace(doctorPhone))
            {
                string doctorTemplate = config.VideoDoctorMessageTemplate;
                if (string.IsNullOrWhiteSpace(doctorTemplate))
                    doctorTemplate = "Dear Dr. {DoctorName}, you have a Video Consultation scheduled with {PatientName} on {Date} at {Time}. Start using: {Link}";

                string doctorMessage = doctorTemplate
                    .Replace("{DoctorName}", doctorName)
                    .Replace("{PatientName}", patientName)
                    .Replace("{Date}", date)
                    .Replace("{Time}", time)
                    .Replace("{Link}", doctorLink)
                    .Trim();

                await SendTextMessageAsync(doctorPhone, doctorMessage, branchId, "VIDEO", opdServiceId);
            }
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[WhatsApp] Error executing TriggerVideoConsultationWhatsAppAsync for OPDServiceId {Id}", opdServiceId);
        }
    }

    private static string FormatPhoneNumber(string rawPhone, string defaultCountryCode)
    {
        if (string.IsNullOrWhiteSpace(rawPhone)) return string.Empty;

        // Strip non-digit characters except leading plus
        var digits = Regex.Replace(rawPhone.Trim(), @"[^\d+]", "");
        if (string.IsNullOrWhiteSpace(digits)) return string.Empty;

        if (digits.StartsWith("+"))
        {
            return digits;
        }

        // If standard 10 digit phone number (e.g. 9007524092)
        var cc = string.IsNullOrWhiteSpace(defaultCountryCode) ? "+91" : defaultCountryCode.Trim();
        if (!cc.StartsWith("+")) cc = "+" + cc;

        if (digits.Length == 10)
        {
            // Strip leading zero if present (e.g. 0987654321 → 987654321 → +91987654321)
            var stripped = digits.TrimStart('0');
            return cc + stripped;
        }

        // If it starts without plus but already has country code (e.g. 919007524092)
        // Also handle leading zero case e.g. 0919007524092
        return "+" + digits.TrimStart('0');
    }
}
