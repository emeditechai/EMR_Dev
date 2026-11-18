using System.Collections.Concurrent;
using System.Text;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace EMR.Shared.Security.Diagnostics;

/// <summary>
/// Warnings and errors of EMR.Web / EMR.Api written to App_Data/logs/{app}-yyyyMMdd.log (one file a day, kept 14 days),
/// so an intermittent failure leaves a trace after the console is gone. Also records unhandled and unobserved exceptions.
/// Writing never throws: a full disk or a locked file just skips the line.
/// </summary>
public static class ErrorFileLogging
{
    /// <summary>Adds the error file log and makes a failing background service log instead of stopping the application.</summary>
    public static ILoggingBuilder AddErrorFile(this ILoggingBuilder logging, string contentRoot, string app)
    {
        var dir = Path.Combine(contentRoot, "App_Data", "logs");
        var provider = new ErrorFileLoggerProvider(dir, app);
        logging.AddProvider(provider);
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            provider.Write("CRITICAL", "AppDomain", "Unhandled exception" + (e.IsTerminating ? " (process ending)" : ""), e.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            provider.Write("ERROR", "TaskScheduler", "Unobserved task exception", e.Exception);
            e.SetObserved();
        };
        return logging;
    }

    /// <summary>A background service that throws is logged; the web application keeps running (default would stop it).</summary>
    public static IServiceCollection KeepRunningOnBackgroundFailure(this IServiceCollection services) =>
        services.Configure<HostOptions>(o => o.BackgroundServiceExceptionBehavior = BackgroundServiceExceptionBehavior.Ignore);
}

public sealed class ErrorFileLoggerProvider(string directory, string app) : ILoggerProvider
{
    private readonly object _gate = new();
    private DateTime _cleaned = DateTime.MinValue;
    private readonly ConcurrentDictionary<string, ErrorFileLogger> _loggers = new();

    public ILogger CreateLogger(string categoryName) => _loggers.GetOrAdd(categoryName, c => new ErrorFileLogger(this, c));
    public void Dispose() { }

    internal void Write(string level, string category, string message, Exception? ex)
    {
        try
        {
            var sb = new StringBuilder();
            sb.Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff")).Append(" [").Append(level).Append("] ").Append(category).Append(": ").AppendLine(message);
            if (ex is not null) sb.AppendLine(ex.ToString());
            lock (_gate)
            {
                Directory.CreateDirectory(directory);
                File.AppendAllText(Path.Combine(directory, $"{app}-{DateTime.Now:yyyyMMdd}.log"), sb.ToString());
                if (DateTime.Now - _cleaned > TimeSpan.FromHours(12))
                {
                    _cleaned = DateTime.Now;
                    foreach (var f in Directory.GetFiles(directory, $"{app}-*.log"))
                        if (File.GetLastWriteTime(f) < DateTime.Now.AddDays(-14)) File.Delete(f);
                }
            }
        }
        catch { /* logging must never break the application */ }
    }

    private sealed class ErrorFileLogger(ErrorFileLoggerProvider owner, string category) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Warning;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            if (!IsEnabled(logLevel)) return;
            owner.Write(logLevel.ToString().ToUpperInvariant(), category, formatter(state, exception), exception);
        }
    }
}
