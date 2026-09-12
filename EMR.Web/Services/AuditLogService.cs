using System.Security.Claims;
using EMR.Web.Data;
using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

public class AuditLogService(ApplicationDbContext dbContext, IHttpContextAccessor httpContextAccessor) : IAuditLogService
{
    public Task LogAsync(string eventType, string actionName, string? description = null, int? userId = null, int? branchId = null)
    {
        return LogActivityAsync(eventType, actionName, description, userId, branchId);
    }

    public async Task LogActivityAsync(
        string eventType,
        string actionName,
        string? description = null,
        int? userId = null,
        int? branchId = null,
        string? moduleCode = null,
        string? referenceNo = null,
        long? referenceId = null,
        string? patientCode = null,
        object? metadata = null)
    {
        var httpContext = httpContextAccessor.HttpContext;
        var principal = httpContext?.User;

        var resolvedUserId = userId ?? ParseInt(principal?.FindFirstValue(ClaimTypes.NameIdentifier));
        var resolvedBranchId = branchId ?? ParseInt(principal?.FindFirstValue("BranchId"));

        string? metadataJson = null;
        if (metadata != null)
        {
            try
            {
                metadataJson = metadata is string str ? str : System.Text.Json.JsonSerializer.Serialize(metadata);
            }
            catch
            {
                // Fallback to null if serialization fails
            }
        }

        var log = new AuditLog
        {
            UserId = resolvedUserId,
            BranchId = resolvedBranchId,
            EventType = eventType,
            ActionName = actionName,
            ControllerName = httpContext?.GetRouteValue("controller")?.ToString(),
            RoutePath = httpContext?.Request.Path.Value,
            HttpMethod = httpContext?.Request.Method,
            IpAddress = ResolveClientIp(httpContext),
            UserAgent = httpContext?.Request.Headers.UserAgent.ToString(),
            Description = description,
            ModuleCode = moduleCode,
            ReferenceNo = referenceNo,
            ReferenceId = referenceId,
            PatientCode = patientCode,
            MetadataJson = metadataJson,
            CreatedDate = DateTime.Now,
        };

        dbContext.AuditLogs.Add(log);
        await dbContext.SaveChangesAsync();
    }

    private static int? ParseInt(string? input)
    {
        return int.TryParse(input, out var value) ? value : null;
    }

    private static string? ResolveClientIp(HttpContext? ctx)
    {
        if (ctx is null) return null;

        // 1. X-Forwarded-For: client, proxy1, proxy2 — take the leftmost (original client)
        var forwarded = ctx.Request.Headers["X-Forwarded-For"].FirstOrDefault();
        if (!string.IsNullOrWhiteSpace(forwarded))
        {
            var first = forwarded.Split(',')[0].Trim();
            if (!string.IsNullOrWhiteSpace(first))
                return NormalizeIp(first);
        }

        // 2. X-Real-IP (Nginx sets this)
        var realIp = ctx.Request.Headers["X-Real-IP"].FirstOrDefault();
        if (!string.IsNullOrWhiteSpace(realIp))
            return NormalizeIp(realIp);

        // 3. Direct connection IP
        return NormalizeIp(ctx.Connection.RemoteIpAddress?.ToString());
    }

    // Map IPv4-in-IPv6 (::ffff:1.2.3.4) back to plain IPv4
    private static string? NormalizeIp(string? ip)
    {
        if (ip is null) return null;
        if (ip.StartsWith("::ffff:", StringComparison.OrdinalIgnoreCase))
            return ip[7..];
        return ip;
    }}