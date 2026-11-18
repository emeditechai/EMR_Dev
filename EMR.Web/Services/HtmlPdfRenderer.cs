using System.Diagnostics;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace EMR.Web.Services;

/// <summary>
/// One of EMR's own print pages (the LAB / OPD bill, the Image report) as a PDF, returned as bytes: headless Chrome
/// opens the page and prints it through the DevTools protocol (Page.printToPDF), so no PDF file is written - unlike the
/// --print-to-pdf temp file the WhatsApp bill sender uses. Chrome's own throw-away profile folder is removed afterwards.
/// Chrome is the one the bill sender already needs; "PdfRenderer:ChromePath" names another.
/// </summary>
public interface IHtmlPdfRenderer
{
    /// <summary>The page at the URL as an A4 PDF, or null when Chrome is missing or the page could not be printed.</summary>
    Task<byte[]?> RenderAsync(string url, CancellationToken ct = default);
}

public sealed partial class HtmlPdfRenderer(IConfiguration config, ILogger<HtmlPdfRenderer> logger) : IHtmlPdfRenderer
{
    private static readonly SemaphoreSlim Gate = new(2);   // at most two Chromes at a time
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(45);

    [GeneratedRegex(@"DevTools listening on (ws://\S+)")]
    private static partial Regex ListeningLine();

    public async Task<byte[]?> RenderAsync(string url, CancellationToken ct = default)
    {
        var chrome = ChromePath();
        if (chrome is null)
        {
            logger.LogWarning("[PDF] Chrome was not found; set PdfRenderer:ChromePath");
            return null;
        }

        await Gate.WaitAsync(ct);
        var profile = Path.Combine(Path.GetTempPath(), $"emr-pdf-{Guid.NewGuid():N}");
        Process? process = null;
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(Timeout);

            process = Process.Start(new ProcessStartInfo
            {
                FileName = chrome,
                Arguments = $"--headless=new --disable-gpu --no-first-run --no-default-browser-check --disable-extensions " +
                            $"--hide-scrollbars --remote-debugging-port=0 --user-data-dir=\"{profile}\" about:blank",
                UseShellExecute = false,
                RedirectStandardError = true,
                RedirectStandardOutput = true,
                CreateNoWindow = true
            });
            if (process is null) return null;
            process.OutputDataReceived += (_, _) => { };
            process.BeginOutputReadLine();

            // Chrome says where its DevTools socket is on stderr
            string? browserWs = null;
            while (browserWs is null && await process.StandardError.ReadLineAsync(cts.Token) is { } line)
                if (ListeningLine().Match(line) is { Success: true } m) browserWs = m.Groups[1].Value;
            if (browserWs is null) return null;
            _ = process.StandardError.ReadToEndAsync(CancellationToken.None);   // keep the pipe drained

            using var cdp = new Cdp();
            await cdp.ConnectAsync(new Uri(browserWs), cts.Token);
            var target = await cdp.SendAsync("Target.createTarget", new JsonObject { ["url"] = "about:blank" }, null, cts.Token);
            var attach = await cdp.SendAsync("Target.attachToTarget",
                new JsonObject { ["targetId"] = target["targetId"]!.GetValue<string>(), ["flatten"] = true }, null, cts.Token);
            var session = attach["sessionId"]!.GetValue<string>();

            await cdp.SendAsync("Page.enable", new JsonObject(), session, cts.Token);
            // the bill pages open the print dialog on load; here the page is printed to PDF instead
            await cdp.SendAsync("Page.addScriptToEvaluateOnNewDocument",
                new JsonObject { ["source"] = "window.print = function () {};" }, session, cts.Token);
            var loaded = cdp.WaitForEvent("Page.loadEventFired", session);
            await cdp.SendAsync("Page.navigate", new JsonObject { ["url"] = url }, session, cts.Token);
            await loaded.WaitAsync(cts.Token);
            await Task.Delay(600, cts.Token);   // barcodes / QR codes drawn by the page's own script after load

            var pdf = await cdp.SendAsync("Page.printToPDF", new JsonObject
            {
                ["printBackground"] = true,
                ["preferCSSPageSize"] = true,
                ["paperWidth"] = 8.27,      // A4, unless the page sets its own @page size
                ["paperHeight"] = 11.69,
                ["marginTop"] = 0.3, ["marginBottom"] = 0.3, ["marginLeft"] = 0.3, ["marginRight"] = 0.3
            }, session, cts.Token);

            try { await cdp.SendAsync("Browser.close", new JsonObject(), null, cts.Token); } catch { /* killed below */ }
            return Convert.FromBase64String(pdf["data"]!.GetValue<string>());
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "[PDF] Could not print {Url}", Redact(url));
            return null;
        }
        finally
        {
            try
            {
                if (process is { HasExited: false })
                {
                    if (!process.WaitForExit(3000)) process.Kill(entireProcessTree: true);
                }
            }
            catch { /* already gone */ }
            process?.Dispose();
            try { if (Directory.Exists(profile)) Directory.Delete(profile, recursive: true); } catch { /* Chrome may hold a file a moment longer */ }
            Gate.Release();
        }
    }

    private string? ChromePath()
    {
        var configured = config["PdfRenderer:ChromePath"];
        if (!string.IsNullOrWhiteSpace(configured)) return configured;
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string[] candidates = OperatingSystem.IsWindows()
            ? [@"C:\Program Files\Google\Chrome\Application\chrome.exe", @"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
               Path.Combine(local, @"Google\Chrome\Application\chrome.exe"), @"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"]
            : OperatingSystem.IsMacOS()
                ? ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]
                : ["/usr/bin/google-chrome", "/usr/bin/google-chrome-stable", "/usr/bin/chromium", "/usr/bin/chromium-browser"];
        return candidates.FirstOrDefault(File.Exists);
    }

    // the page URLs carry a secret or a ticket: never logged
    private static string Redact(string url) => url.Split('?')[0];

    /// <summary>A minimal DevTools protocol client: numbered commands, their replies, and awaited events.</summary>
    private sealed class Cdp : IDisposable
    {
        private readonly ClientWebSocket _ws = new();
        private readonly Dictionary<int, TaskCompletionSource<JsonNode>> _pending = new();
        private readonly List<(string Method, string? Session, TaskCompletionSource<bool> Done)> _waits = new();
        private readonly object _lock = new();
        private int _nextId;

        public async Task ConnectAsync(Uri uri, CancellationToken ct)
        {
            _ws.Options.KeepAliveInterval = TimeSpan.Zero;
            await _ws.ConnectAsync(uri, ct);
            _ = Task.Run(ReceiveLoopAsync);
        }

        public Task WaitForEvent(string method, string? session)
        {
            var tcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (_lock) _waits.Add((method, session, tcs));
            return tcs.Task;
        }

        public async Task<JsonNode> SendAsync(string method, JsonObject parameters, string? session, CancellationToken ct)
        {
            var tcs = new TaskCompletionSource<JsonNode>(TaskCreationOptions.RunContinuationsAsynchronously);
            int id;
            lock (_lock) { id = ++_nextId; _pending[id] = tcs; }
            var message = new JsonObject { ["id"] = id, ["method"] = method, ["params"] = parameters };
            if (session != null) message["sessionId"] = session;
            await _ws.SendAsync(Encoding.UTF8.GetBytes(message.ToJsonString()), WebSocketMessageType.Text, true, ct);
            using (ct.Register(() => tcs.TrySetCanceled()))
                return await tcs.Task;
        }

        private async Task ReceiveLoopAsync()
        {
            var buffer = new byte[64 * 1024];
            using var message = new MemoryStream();
            try
            {
                while (_ws.State == WebSocketState.Open)
                {
                    var result = await _ws.ReceiveAsync(buffer, CancellationToken.None);
                    if (result.MessageType == WebSocketMessageType.Close) break;
                    message.Write(buffer, 0, result.Count);
                    if (!result.EndOfMessage) continue;

                    var node = JsonNode.Parse(message.ToArray());
                    message.SetLength(0);
                    if (node is null) continue;

                    if (node["id"] is { } idNode)
                    {
                        TaskCompletionSource<JsonNode>? tcs;
                        lock (_lock) { _pending.Remove(idNode.GetValue<int>(), out tcs); }
                        if (tcs is null) continue;
                        if (node["error"] is { } error) tcs.TrySetException(new InvalidOperationException(error.ToJsonString()));
                        else tcs.TrySetResult(node["result"] ?? new JsonObject());
                    }
                    else if (node["method"]?.GetValue<string>() is { } method)
                    {
                        var session = node["sessionId"]?.GetValue<string>();
                        lock (_lock)
                        {
                            foreach (var w in _waits.Where(w => w.Method == method && (w.Session == null || w.Session == session)).ToList())
                            {
                                w.Done.TrySetResult(true);
                                _waits.Remove(w);
                            }
                        }
                    }
                }
            }
            catch { /* the socket closes with Chrome */ }
            lock (_lock)
            {
                foreach (var p in _pending.Values) p.TrySetException(new WebSocketException("DevTools connection closed."));
                _pending.Clear();
            }
        }

        public void Dispose() => _ws.Dispose();
    }
}
