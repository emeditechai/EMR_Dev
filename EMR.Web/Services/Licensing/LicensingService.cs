using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;

namespace EMR.Web.Services.Licensing;

/// <summary>
/// eCare360 licence engine: the gate every request goes through, registration and hardware renewal with an OTP the
/// vendor approves, the banners and the Settings > Licence overview. The rules follow the vendor's licensing guide:
/// central (vendor) row is the truth, checked once a day, with a signed local copy deciding the skip in between.
/// </summary>
public interface ILicensingService
{
    bool Enabled { get; }
    string AppUrl(HttpContext http);
    Task<LicenseGateResult> EvaluateAccessAsync(HttpContext http, bool force = false);
    Task<(bool Ok, string Message)> StartRegistrationOtpAsync(HttpContext http, RegistrationRequest request);
    Task<(bool Ok, string Message)> VerifyRegistrationOtpAsync(HttpContext http, string otp);
    Task<(bool Ok, string Message)> StartRenewalOtpAsync(HttpContext http, string licenseKey);
    Task<(bool Ok, string Message)> VerifyRenewalOtpAsync(HttpContext http, string otp);
    Task<IReadOnlyList<LicenseBanner>> GetBannersAsync(HttpContext http);
    Task<LicenseOverview> GetOverviewAsync(HttpContext http);
    Task<LicenseLogEntry?> LastCheckAsync();
    MachineFingerprint Machine { get; }
    void ClearCaches(HttpContext http);
    Task<LicenseGateResult> RevalidateAsync(HttpContext http);
}

public sealed class LicensingService(
    IOptions<LicensingOptions> options,
    IMachineFingerprintProvider fingerprints,
    ICentralLicenseRepository central,
    ILocalLicenseRepository local,
    ILicenseCrypto crypto,
    ILicenseMailer mailer,
    IMemoryCache cache,
    ILogger<LicensingService> logger) : ILicensingService
{
    private const string OtpSessionKey = "eCare360.Licensing.Otp";
    private const string OtpSendsSessionKey = "eCare360.Licensing.OtpSends";
    private static readonly SemaphoreSlim SchemaGate = new(1, 1);
    private static bool _schemaReady;
    // one central check at a time: the first request of the day checks, the ones arriving with it wait and reuse it
    private static readonly SemaphoreSlim CentralGate = new(1, 1);
    // clock-tamper defences: time since the last central check is measured on the process's monotonic clock (not the
    // settable wall clock), and a server clock far from the licence server's makes every check go to central
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, long> LastCentralCheck = new();
    private static volatile bool _clockSuspect;
    private static readonly Queue<DateTime> ServerOtpSends = new();
    private readonly LicensingOptions _o = options.Value;

    public bool Enabled => _o.Enabled;
    public MachineFingerprint Machine => fingerprints.Current;

    /// <summary>scheme://host[:port] + PathBase: two applications on one host never share a URL.</summary>
    public string AppUrl(HttpContext http) => !string.IsNullOrWhiteSpace(_o.AppUrl)
        ? _o.AppUrl!
        : $"{http.Request.Scheme}://{http.Request.Host.Value}{http.Request.PathBase.Value}".TrimEnd('/').ToLowerInvariant();

    /// <summary>A central check is due on the first request after every application start, and again when 24 hours of
    /// uptime passed since the last one (wall-clock changes don't count). The daily skip adds "not yet today".</summary>
    private static bool CentralCheckDue(string url) =>
        !LastCentralCheck.TryGetValue(url, out var t) || System.Diagnostics.Stopwatch.GetElapsedTime(t) > TimeSpan.FromHours(24);

    private static string NormalizeUrl(string? url) => (url ?? string.Empty).Trim().TrimEnd('/').ToLowerInvariant();

    private static string CacheKey(string url) => $"LicenseGate:{url}:{DateTime.Today:yyyyMMdd}";
    private static DateTime NowToSecond() { var n = DateTime.Now; return n.AddTicks(-(n.Ticks % TimeSpan.TicksPerSecond)); }
    private static string? Ip(HttpContext http) => http.Connection.RemoteIpAddress?.ToString();

    private async Task EnsureSchemaAsync()
    {
        if (_schemaReady) return;
        await SchemaGate.WaitAsync();
        try { if (!_schemaReady) { await local.EnsureSchemaAsync(); _schemaReady = true; } }
        finally { SchemaGate.Release(); }
    }

    public void ClearCaches(HttpContext http)
    {
        cache.Remove(CacheKey(AppUrl(http)));
        cache.Remove($"LicenseBanners:{AppUrl(http)}");
        fingerprints.Reset();
    }

    // ── the gate ──────────────────────────────────────────────────────────────
    public async Task<LicenseGateResult> EvaluateAccessAsync(HttpContext http, bool force = false)
    {
        // a missing password or setting blocks every page (the application itself keeps running to say so)
        if (_o.ConfigurationProblem != null)
            return LicenseGateResult.Of(LicenseGateStatus.ConfigurationMissing, _o.ConfigurationProblem);

        await EnsureSchemaAsync();
        var url = AppUrl(http);
        var key = CacheKey(url);
        var fp = fingerprints.Current;

        if (force || CentralCheckDue(url)) cache.Remove(key);
        else if (cache.TryGetValue(key, out LicenseGateResult? cached) && cached != null
                 && (!cached.IsAllowed || await local.ExistsAsync(fp.Hash, url)))
            return cached;

        await CentralGate.WaitAsync();
        try
        {
            // a request that waited may find the answer the first one just cached
            if (!force && !CentralCheckDue(url) && cache.TryGetValue(key, out LicenseGateResult? fresh) && fresh != null) return fresh;
            var result = await EvaluateUncachedAsync(http, url, key, fp, force);
            // a refusal is remembered for 30 seconds, so a blocked server is not a way to flood the licence server;
            // a vendor fix still shows within 30 seconds, and Retry / Re-check always ask again
            if (!result.IsAllowed) cache.Set(key, result, TimeSpan.FromSeconds(30));
            return result;
        }
        finally { CentralGate.Release(); }
    }

    private async Task<LicenseGateResult> EvaluateUncachedAsync(HttpContext http, string url, string key, MachineFingerprint fp, bool force)
    {
        var (row, trusted) = await local.FindAsync(fp.Hash, url);
        if (row is null)
        {
            LicenseRecord? remoteByUrl;
            try { remoteByUrl = await central.FindByAppUrlAsync(url); }                                      // C1
            catch (Exception ex) { return await UnavailableAsync(null, false, fp, url, http, ex); }

            if (remoteByUrl != null && fp.Matches(remoteByUrl))
            {
                remoteByUrl.LastRemoteValidatedAt = null;                                                        // checked centrally below
                await local.UpsertAsync(remoteByUrl);
                (row, trusted) = await local.FindAsync(fp.Hash, url);
            }
            else if (remoteByUrl != null)
            {
                var why = fp.Describe(remoteByUrl);
                await local.LogAsync(remoteByUrl, fp.Hash, LicenseGateStatus.HardwareMismatch, false, false, true, false, why, Ip(http), url);
                return new LicenseGateResult { Status = LicenseGateStatus.HardwareMismatch, Reason = why, MovedClientCode = remoteByUrl.ClientCode };
            }
            else
            {
                LicenseRecord? moved = null;
                try { moved = await central.FindByHardwareAsync(fp, null); } catch { /* read-only hint only */ }   // C3 without URL
                return new LicenseGateResult
                {
                    Status = LicenseGateStatus.Unregistered, Reason = "No licence is registered for this server and URL.",
                    MovedClientCode = moved?.ClientCode, MovedAppUrl = moved?.AppUrl
                };
            }
            if (row is null) return LicenseGateResult.Of(LicenseGateStatus.UnknownError, "The local licence copy could not be saved.");
        }

        // signed row already validated centrally today: no central call (a forced check - Retry, Re-check - always asks central)
        if (!force && trusted && !_clockSuspect && !CentralCheckDue(url)
            && row.LastRemoteValidatedAt?.Date == DateTime.Today && DateTime.Now >= row.LastRemoteValidatedAt   // clock not moved back
            && fp.Matches(row) && row.IsActive && row.OtpVerified && row.ExpiryDate > DateTime.Now)
        {
            var ok = LicenseGateResult.Of(LicenseGateStatus.Valid);
            cache.Set(key, ok, DateTime.Today.AddDays(1));
            return ok;
        }

        LicenseRecord? remote;
        try { remote = await central.FindByKeyAsync(row.ClientCode, row.LicenseKey); }                         // C2
        catch (Exception ex) { return await UnavailableAsync(row, trusted, fp, url, http, ex); }

        LastCentralCheck[url] = System.Diagnostics.Stopwatch.GetTimestamp();
        LicenseGateStatus status;
        string? reason = null;
        var centralNow = remote?.CentralNow ?? DateTime.Now;
        if (remote?.CentralNow != null)
        {
            var skew = (remote.CentralNow.Value - DateTime.Now).Duration();
            _clockSuspect = skew > TimeSpan.FromHours(1);
            if (_clockSuspect) logger.LogWarning("This server's clock is {Skew} away from the licence server's; the licence is checked hourly until it is corrected.", skew);
        }
        if (remote is null) { status = LicenseGateStatus.RemoteNotFound; reason = "The licence no longer exists on the licence server."; }
        else if (!remote.OtpVerified) { status = LicenseGateStatus.PendingActivation; reason = "The licence is waiting for activation by the vendor."; }
        else if (!remote.IsActive) { status = LicenseGateStatus.Inactive; reason = "The licence has been deactivated by the vendor."; }
        else if (remote.ExpiryDate <= centralNow) { status = LicenseGateStatus.Expired; reason = $"The licence expired on {remote.ExpiryDate:dd MMM yyyy}."; }
        else if (!string.Equals(remote.LicenseKey, row.LicenseKey, StringComparison.OrdinalIgnoreCase)
                 || !string.Equals(remote.ClientName?.Trim(), row.ClientName?.Trim(), StringComparison.Ordinal))
        { status = LicenseGateStatus.DataMismatch; reason = "The local licence copy does not match the licence server."; }
        else if (NormalizeUrl(remote.AppUrl) != NormalizeUrl(url))
        { status = LicenseGateStatus.DataMismatch; reason = $"The licence is registered for {remote.AppUrl}, not for this address."; }
        else if (!fp.Matches(remote)) { status = LicenseGateStatus.HardwareMismatch; reason = fp.Describe(remote); }
        else status = LicenseGateStatus.Valid;

        var ip = Ip(http);
        try
        {
            if (remote != null)
            {
                await central.TouchAsync(remote.ClientCode, remote.LicenseKey, ip, status == LicenseGateStatus.Valid);   // C6
                // a failed check clears "validated today", so the daily skip cannot let the next request through
                remote.LastRemoteValidatedAt = status == LicenseGateStatus.Valid ? NowToSecond() : null;
                remote.PublicIPAddress = ip ?? remote.PublicIPAddress;
                await local.UpsertAsync(remote);                                                                // re-signs
            }
            else
            {
                row.LastRemoteValidatedAt = null;                                                               // RemoteNotFound
                await local.UpsertAsync(row);
            }
            await central.LogValidationAsync(row.ClientCode, row.LicenseKey, status == LicenseGateStatus.Valid,
                status == LicenseGateStatus.Valid ? null : $"{status}: {reason}", ip, fp.DeviceInfo(), url);   // C9
        }
        catch (Exception ex) { logger.LogWarning(ex, "Licence write-back after the central check failed."); }
        await local.LogAsync(remote ?? row, fp.Hash, status, fp.Matches(remote ?? row), status == LicenseGateStatus.Expired, true, false, reason, ip, url);

        var result = LicenseGateResult.Of(status, reason);
        if (status == LicenseGateStatus.Valid)
        {
            if (_clockSuspect) cache.Set(key, result, TimeSpan.FromHours(1));
            else cache.Set(key, result, DateTime.Today.AddDays(1));
        }
        return result;
    }

    /// <summary>
    /// Re-validate (login page, Blocked page): forget every cached answer and check every value with the licence server
    /// now. When the local copy no longer matches the server (data mismatch, licence not found), the copy is deleted and
    /// rebuilt from the licence server by this address, as on first start; that lands on Valid, on the registration
    /// form (vendor OTP) or on the hardware renewal (licence key + vendor OTP).
    /// </summary>
    public async Task<LicenseGateResult> RevalidateAsync(HttpContext http)
    {
        ClearCaches(http);
        var gate = await EvaluateAccessAsync(http, force: true);
        if (gate.Status is LicenseGateStatus.DataMismatch or LicenseGateStatus.RemoteNotFound)
        {
            var removed = await local.DeleteAsync(fingerprints.Current.Hash, AppUrl(http));
            logger.LogWarning("Licence re-validation: {Status}; removed {Rows} local licence copy row(s) to rebuild it from the licence server.", gate.Status, removed);
            ClearCaches(http);
            gate = await EvaluateAccessAsync(http, force: true);
        }
        return gate;
    }

    private async Task<LicenseGateResult> UnavailableAsync(LicenseRecord? row, bool trusted, MachineFingerprint fp, string url, HttpContext http, Exception ex)
    {
        logger.LogWarning(ex, "Licence server unreachable.");
        if (row != null && _o.OfflineGraceDays > 0 && trusted && row.LastRemoteValidatedAt.HasValue
            && DateTime.Now - row.LastRemoteValidatedAt.Value <= TimeSpan.FromDays(_o.OfflineGraceDays)
            && row.ExpiryDate > DateTime.Now && fp.Matches(row))
        {
            var left = Math.Max(0, _o.OfflineGraceDays - (int)(DateTime.Now - row.LastRemoteValidatedAt.Value).TotalDays);
            await local.LogAsync(row, fp.Hash, LicenseGateStatus.Valid, true, false, false, true, "Licence server unreachable: offline grace.", Ip(http), url);
            var grace = new LicenseGateResult { Status = LicenseGateStatus.Valid, OfflineGrace = true, OfflineGraceDaysLeft = left, Reason = ex.Message };
            cache.Set(CacheKey(url), grace, TimeSpan.FromHours(1));                                            // keep retrying central hourly
            return grace;
        }
        await local.LogAsync(row, fp.Hash, LicenseGateStatus.RemoteUnavailable, row != null && fp.Matches(row), false, false, false, ex.Message, Ip(http), url);
        return LicenseGateResult.Of(LicenseGateStatus.RemoteUnavailable, "The licence server could not be reached.");
    }

    // ── OTP challenges (kept in the server-side session) ─────────────────────
    private sealed class OtpChallenge
    {
        public string Kind { get; set; } = "REGISTER";            // REGISTER / RENEW
        public Guid ChallengeId { get; set; }
        public string OtpHash { get; set; } = string.Empty;
        public DateTime ExpiresAt { get; set; }
        public int Attempts { get; set; }
        public RegistrationRequest? Registration { get; set; }
        public string? LicenseKey { get; set; }
        public string? ClientCode { get; set; }
        public string AppUrl { get; set; } = string.Empty;
    }

    private static OtpChallenge? ReadChallenge(HttpContext http)
    {
        var json = http.Session.GetString(OtpSessionKey);
        return string.IsNullOrEmpty(json) ? null : JsonSerializer.Deserialize<OtpChallenge>(json);
    }

    private static void SaveChallenge(HttpContext http, OtpChallenge? c)
    {
        if (c is null) http.Session.Remove(OtpSessionKey);
        else http.Session.SetString(OtpSessionKey, JsonSerializer.Serialize(c));
    }

    /// <summary>Per-session (15 min) and per-server (1 h) caps on OTP e-mails, on top of the per-address rate limit.</summary>
    private string? OtpSendRefusal(HttpContext http)
    {
        var now = DateTime.UtcNow;
        var mine = (http.Session.GetString(OtpSendsSessionKey) ?? string.Empty)
            .Split(',', StringSplitOptions.RemoveEmptyEntries).Select(x => long.TryParse(x, out var t) ? new DateTime(t, DateTimeKind.Utc) : DateTime.MinValue)
            .Where(t => now - t < TimeSpan.FromMinutes(15)).ToList();
        if (mine.Count >= _o.OtpSendsPerSessionPer15Min) return "Too many OTP requests. Wait 15 minutes and try again.";
        lock (ServerOtpSends)
        {
            while (ServerOtpSends.Count > 0 && now - ServerOtpSends.Peek() > TimeSpan.FromHours(1)) ServerOtpSends.Dequeue();
            if (ServerOtpSends.Count >= _o.OtpSendsPerServerPerHour) return "Too many OTP requests on this server. Try again in an hour or contact the vendor.";
            ServerOtpSends.Enqueue(now);
        }
        mine.Add(now);
        http.Session.SetString(OtpSendsSessionKey, string.Join(",", mine.Select(t => t.Ticks)));
        return null;
    }

    private string NewOtp()
    {
        var digits = new char[_o.OtpLength];
        for (var i = 0; i < digits.Length; i++) digits[i] = (char)('0' + RandomNumberGenerator.GetInt32(10));
        return new string(digits);
    }

    /// <summary>Checks the OTP of the session's challenge of this kind; the challenge stays only while it can still succeed.</summary>
    private async Task<(OtpChallenge? Challenge, string? Error)> CheckOtpAsync(HttpContext http, string kind, string otp)
    {
        var c = ReadChallenge(http);
        if (c is null || c.Kind != kind || c.AppUrl != AppUrl(http)) return (null, "No OTP request is open. Request a new OTP.");
        if (DateTime.Now > c.ExpiresAt)
        {
            SaveChallenge(http, null);
            await SafeAsync(() => central.UpdateOtpChallengeAsync(c.ChallengeId, false, null, "OTP expired"));
            return (null, "The OTP has expired. Request a new OTP.");
        }
        var given = (otp ?? string.Empty).Trim();
        var ok = given.Length == _o.OtpLength && CryptographicOperations.FixedTimeEquals(
            Convert.FromHexString(crypto.HashOtp(given)), Convert.FromHexString(c.OtpHash));
        if (!ok)
        {
            c.Attempts++;
            if (c.Attempts >= _o.OtpMaxAttempts)
            {
                SaveChallenge(http, null);
                await SafeAsync(() => central.UpdateOtpChallengeAsync(c.ChallengeId, false, null, "Too many attempts"));
                return (null, "Too many wrong attempts. Request a new OTP.");
            }
            SaveChallenge(http, c);
            await SafeAsync(() => central.UpdateOtpChallengeAsync(c.ChallengeId, false, null, "Invalid OTP entered"));
            return (null, $"Wrong OTP. {_o.OtpMaxAttempts - c.Attempts} attempt(s) left.");
        }
        SaveChallenge(http, null);
        return (c, null);
    }

    private async Task SafeAsync(Func<Task> action)
    {
        try { await action(); } catch (Exception ex) { logger.LogWarning(ex, "Licence OTP history could not be updated."); }
    }

    // ── registration ─────────────────────────────────────────────────────────
    public async Task<(bool Ok, string Message)> StartRegistrationOtpAsync(HttpContext http, RegistrationRequest r)
    {
        if (!_o.Enabled) return (false, "Licensing is not enabled on this server.");
        var gate = await EvaluateAccessAsync(http, force: true);
        if (gate.Status != LicenseGateStatus.Unregistered) return (false, "This server already has a licence: registration is not needed.");
        if (gate.MovedClientCode != null) return (false, $"This server already holds licence {gate.MovedClientCode} for {gate.MovedAppUrl}. Contact the vendor.");

        r.ClientName = (r.ClientName ?? string.Empty).Trim();
        r.ContactNumber = new string((r.ContactNumber ?? string.Empty).Where(char.IsDigit).ToArray());
        r.EmailID = string.IsNullOrWhiteSpace(r.EmailID) ? null : r.EmailID.Trim();
        if (r.ClientName.Length is < 2 or > 100) return (false, "Enter the client (hospital) name, up to 100 characters.");
        if (r.ContactNumber.Length != 10) return (false, "Enter a 10-digit contact number.");
        if (r.EmailID != null && (r.EmailID.Length > 100 || !System.Net.Mail.MailAddress.TryCreate(r.EmailID, out _))) return (false, "Enter a valid e-mail address.");
        if (r.EndDate.Date <= DateTime.Today) return (false, "The licence end date must be after today.");
        if (r.EndDate.Date > DateTime.Today.AddDays(_o.MaxTermDays)) return (false, $"The licence end date can be at most {_o.MaxTermDays} days from today ({DateTime.Today.AddDays(_o.MaxTermDays):dd MMM yyyy}).");
        if (r.AmcDate.HasValue && r.AmcDate.Value.Date < DateTime.Today) return (false, "The AMC end date cannot be in the past.");
        if (OtpSendRefusal(http) is { } tooMany) return (false, tooMany);

        var fp = fingerprints.Current;
        var otp = NewOtp();
        var c = new OtpChallenge
        {
            Kind = "REGISTER", ChallengeId = Guid.NewGuid(), OtpHash = crypto.HashOtp(otp),
            ExpiresAt = DateTime.Now.AddSeconds(_o.OtpLifetimeSeconds), Registration = r, AppUrl = AppUrl(http)
        };
        try
        {
            await central.InsertOtpChallengeAsync(c.ChallengeId, r.ClientName, r.ContactNumber, r.EmailID, c.OtpHash, null, null, DateTime.Now, c.ExpiresAt, Ip(http)); // C10
            var (sent, message) = await mailer.SendRegistrationOtpAsync(r, fp, c.AppUrl, otp, c.ExpiresAt);
            if (!sent)
            {
                await SafeAsync(() => central.UpdateOtpChallengeAsync(c.ChallengeId, false, null, "OTP e-mail failed"));
                return (false, message);
            }
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Registration OTP could not be issued.");
            return (false, "The licence server could not be reached. Check the connection and try again.");
        }
        SaveChallenge(http, c);
        return (true, $"OTP sent to the vendor. Call the vendor to get it; it is valid for {_o.OtpLifetimeSeconds / 60.0:0.#} minute(s).");
    }

    public async Task<(bool Ok, string Message)> VerifyRegistrationOtpAsync(HttpContext http, string otp)
    {
        var (c, error) = await CheckOtpAsync(http, "REGISTER", otp);
        if (c is null || c.Registration is null) return (false, error ?? "No OTP request is open.");
        var r = c.Registration;
        var fp = fingerprints.Current;
        var url = AppUrl(http);
        var ip = Ip(http);
        try
        {
            await central.UpdateOtpChallengeAsync(c.ChallengeId, true, DateTime.Now, null);                                 // C11
            var license = await central.FindByHardwareAsync(fp, url)                                                        // C3: reuse if already there
                ?? await central.InsertAsync(new LicenseRecord                                                              // C4 + C5
                {
                    ClientName = r.ClientName, ContactNumber = r.ContactNumber, EmailID = r.EmailID,
                    ServerMacID = fp.ServerMacID, HardDiskNumber = fp.HardDiskNumber, MotherboardNumber = fp.MotherboardNumber,
                    PublicIPAddress = ip, AppUrl = url, ProductType = _o.ProductType,
                    StartDate = DateTime.Now, ExpiryDate = r.EndDate.Date.AddDays(1).AddMilliseconds(-3),                     // 23:59:59.997
                    AmcExpiredDate = r.AmcDate?.Date.AddDays(1).AddMilliseconds(-3),
                    CreatedAt = DateTime.Now, LastLoginDate = DateTime.Now
                });
            await central.TouchAsync(license.ClientCode, license.LicenseKey, ip, true);                                     // C6
            var fresh = await central.FindByKeyAsync(license.ClientCode, license.LicenseKey) ?? license;
            fresh.LastRemoteValidatedAt = NowToSecond();
            await local.UpsertAsync(fresh);
            await central.UpdateOtpChallengeAsync(c.ChallengeId, true, DateTime.Now, null, fresh.ClientCode, fresh.LicenseKey); // C11
            await SafeAsync(() => central.LogValidationAsync(fresh.ClientCode, fresh.LicenseKey, true, "Registered", ip, fp.DeviceInfo(), url)); // C9
            await local.LogAsync(fresh, fp.Hash, LicenseGateStatus.Valid, true, false, true, false, "Registered", ip, url);
            ClearCaches(http);
            _ = mailer.SendWelcomeAsync(fresh);                                                                             // best effort
            return (true, $"Licence {fresh.ClientCode} registered. Sign in to continue.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Licence registration failed after the OTP was verified.");
            await SafeAsync(() => central.UpdateOtpChallengeAsync(c.ChallengeId, true, DateTime.Now, "Registration failed: " + ex.Message));
            return (false, "The OTP was correct but the licence could not be saved. Try again or contact the vendor.");
        }
    }

    // ── hardware renewal ─────────────────────────────────────────────────────
    public async Task<(bool Ok, string Message)> StartRenewalOtpAsync(HttpContext http, string licenseKey)
    {
        if (!_o.Enabled) return (false, "Licensing is not enabled on this server.");
        var gate = await EvaluateAccessAsync(http, force: true);
        if (gate.Status != LicenseGateStatus.HardwareMismatch) return (false, "Renewal is only needed when the server hardware has changed.");
        var keyText = (licenseKey ?? string.Empty).Trim().ToUpperInvariant();
        if (!Guid.TryParse(keyText, out _)) return (false, "Enter the licence key from the welcome e-mail (format XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX).");
        if (OtpSendRefusal(http) is { } tooMany) return (false, tooMany);

        var fp = fingerprints.Current;
        try
        {
            var license = await central.FindByLicenseKeyAsync(keyText);                                                        // C7
            if (license is null) return (false, $"No {_o.ProductDisplayName} licence has this key.");
            if (!license.IsActive) return (false, "This licence is deactivated. Contact the vendor.");
            var otp = NewOtp();
            var c = new OtpChallenge
            {
                Kind = "RENEW", ChallengeId = Guid.NewGuid(), OtpHash = crypto.HashOtp(otp), ExpiresAt = DateTime.Now.AddSeconds(_o.OtpLifetimeSeconds),
                LicenseKey = license.LicenseKey, ClientCode = license.ClientCode, AppUrl = AppUrl(http)
            };
            await central.InsertOtpChallengeAsync(c.ChallengeId, license.ClientName, license.ContactNumber, license.EmailID ?? string.Empty,
                c.OtpHash, license.ClientCode, license.LicenseKey, DateTime.Now, c.ExpiresAt, Ip(http));                       // C10
            var (sent, message) = await mailer.SendRenewalOtpAsync(license, fp, c.AppUrl, otp, c.ExpiresAt);
            if (!sent)
            {
                await SafeAsync(() => central.UpdateOtpChallengeAsync(c.ChallengeId, false, null, "OTP e-mail failed"));
                return (false, message);
            }
            SaveChallenge(http, c);
            return (true, $"Renewal OTP sent to the vendor for licence {license.ClientCode}. Call the vendor to get it.");
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Renewal OTP could not be issued.");
            return (false, "The licence server could not be reached. Check the connection and try again.");
        }
    }

    public async Task<(bool Ok, string Message)> VerifyRenewalOtpAsync(HttpContext http, string otp)
    {
        var (c, error) = await CheckOtpAsync(http, "RENEW", otp);
        if (c is null || c.LicenseKey is null || c.ClientCode is null) return (false, error ?? "No OTP request is open.");
        var fp = fingerprints.Current;
        var url = AppUrl(http);
        var ip = Ip(http);
        try
        {
            await central.UpdateOtpChallengeAsync(c.ChallengeId, true, DateTime.Now, null);                                  // C11
            await central.UpdateHardwareAsync(c.ClientCode, c.LicenseKey, fp);                                               // C8
            await central.TouchAsync(c.ClientCode, c.LicenseKey, ip, true);                                                  // C6
            var fresh = await central.FindByKeyAsync(c.ClientCode, c.LicenseKey)
                        ?? throw new InvalidOperationException("The licence disappeared from the licence server.");
            fresh.LastRemoteValidatedAt = NowToSecond();
            await local.UpsertAsync(fresh);
            await SafeAsync(() => central.LogValidationAsync(fresh.ClientCode, fresh.LicenseKey, true, "Hardware renewed", ip, fp.DeviceInfo(), url)); // C9
            await local.LogAsync(fresh, fp.Hash, LicenseGateStatus.Valid, true, false, true, false, "Hardware renewed", ip, url);
            ClearCaches(http);
            return (true, $"Licence {fresh.ClientCode} moved to this server. Sign in to continue.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Hardware renewal failed after the OTP was verified.");
            await SafeAsync(() => central.UpdateOtpChallengeAsync(c.ChallengeId, true, DateTime.Now, "Renewal failed: " + ex.Message));
            return (false, "The OTP was correct but the licence could not be moved. Try again or contact the vendor.");
        }
    }

    // ── banners, overview ────────────────────────────────────────────────────
    public async Task<IReadOnlyList<LicenseBanner>> GetBannersAsync(HttpContext http)
    {
        if (!_o.Enabled) return Array.Empty<LicenseBanner>();
        var bannerKey = $"LicenseBanners:{AppUrl(http)}";
        if (cache.TryGetValue(bannerKey, out IReadOnlyList<LicenseBanner>? cachedBanners) && cachedBanners != null) return cachedBanners;
        var list = new List<LicenseBanner>();
        try
        {
            var url = AppUrl(http);
            if (cache.TryGetValue(CacheKey(url), out LicenseGateResult? gate) && gate is { OfflineGrace: true })
                list.Add(new LicenseBanner("danger", $"The licence server cannot be reached. The application keeps working for {gate.OfflineGraceDaysLeft} more day(s); restore the connection."));
            var (l, _) = await local.FindAsync(fingerprints.Current.Hash, url);
            if (l is null) return list;
            var now = DateTime.Now;
            if (l.IsDisplayAlerts && !string.IsNullOrWhiteSpace(l.AlertMessage))
            {
                var from = (l.AlertStartDate ?? DateTime.MinValue.Date).Date + (l.AlertStartTime ?? TimeSpan.Zero);
                var to = (l.AlertEndDate ?? DateTime.MaxValue.Date).Date + (l.AlertEndTime ?? new TimeSpan(23, 59, 59));
                if (now >= from && now <= to) list.Add(new LicenseBanner("info", l.AlertMessage!));
            }
            var daysLeft = (l.ExpiryDate.Date - now.Date).Days;
            if (daysLeft >= 0 && daysLeft <= _o.ExpiryWarningDays)
                list.Add(new LicenseBanner(daysLeft <= 3 ? "danger" : "warning",
                    daysLeft == 0 ? $"Your {_o.ProductDisplayName} licence expires today. Contact the vendor to renew it."
                                  : $"Your {_o.ProductDisplayName} licence expires in {daysLeft} day(s), on {l.ExpiryDate:dd MMM yyyy}. Contact the vendor to renew it."));
            if (l.AmcExpiredDate.HasValue)
            {
                var amcLeft = (l.AmcExpiredDate.Value.Date - now.Date).Days;
                if (amcLeft < 0) list.Add(new LicenseBanner("warning", $"Your AMC (support contract) ended on {l.AmcExpiredDate:dd MMM yyyy}."));
                else if (amcLeft <= _o.ExpiryWarningDays) list.Add(new LicenseBanner("warning", $"Your AMC (support contract) ends in {amcLeft} day(s), on {l.AmcExpiredDate:dd MMM yyyy}."));
            }
        }
        catch (Exception ex) { logger.LogDebug(ex, "Licence banners unavailable."); }
        cache.Set(bannerKey, (IReadOnlyList<LicenseBanner>)list, TimeSpan.FromMinutes(5));
        return list;
    }

    public async Task<LicenseOverview> GetOverviewAsync(HttpContext http)
    {
        if (!_o.Enabled) return new LicenseOverview { Enabled = false, Machine = fingerprints.Current, AppUrl = AppUrl(http), ProductType = _o.ProductType };
        await EnsureSchemaAsync();
        var gate = await EvaluateAccessAsync(http);
        var url = AppUrl(http);
        var (l, trusted) = await local.FindAsync(fingerprints.Current.Hash, url);
        if (l is null) (l, trusted) = await local.FindLatestAsync(url);
        return new LicenseOverview
        {
            Enabled = true, Status = gate.Status, Reason = gate.Reason, License = l, SignatureTrusted = trusted,
            Machine = fingerprints.Current, AppUrl = url, ProductType = _o.ProductType, RecentChecks = await local.RecentLogsAsync(10)
        };
    }

    public async Task<LicenseLogEntry?> LastCheckAsync()
    {
        try { await EnsureSchemaAsync(); return (await local.RecentLogsAsync(1)).FirstOrDefault(); }
        catch { return null; }
    }
}
