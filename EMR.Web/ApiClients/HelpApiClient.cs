namespace EMR.Web.ApiClients;

public interface IHelpApiClient
{
    Task<HelpHomeView> HomeAsync(int companyId);
    Task<HelpModuleView?> ModuleAsync(int companyId, string module);
    Task<HelpArticleView?> ArticleAsync(int companyId, string code);
    Task<HelpPageView?> PageAsync(int companyId, string? pageCode, string? controller, string? action);
    Task<HelpAnswer> AskAsync(HelpAskRequest request);
    Task FeedbackAsync(HelpFeedbackRequest request);
    Task<HelpFeedbackList> FeedbackListAsync(int companyId);
    Task<HelpLearningStats> LearningStatsAsync(int companyId);
    Task TeachAsync(HelpTeachRequest request);
    Task ForgetAsync(int companyId, int learnedId, int? userId);
}

/// <summary>Utility > Help Center: EMR.Api api/help.</summary>
public class HelpApiClient(IHttpClientFactory httpClientFactory) : IHelpApiClient
{
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");
    private const string Base = "api/help";

    private async Task<T?> GetOrNull<T>(string url) where T : class
    {
        var r = await Client.GetAsync(url);
        if (r.StatusCode == System.Net.HttpStatusCode.NotFound) return null;
        r.EnsureSuccessStatusCode();
        return await r.Content.ReadFromJsonAsync<T>();
    }

    public async Task<HelpHomeView> HomeAsync(int companyId) => await GetOrNull<HelpHomeView>($"{Base}/home?companyId={companyId}") ?? new();
    public Task<HelpModuleView?> ModuleAsync(int companyId, string module) => GetOrNull<HelpModuleView>($"{Base}/module/{Uri.EscapeDataString(module)}?companyId={companyId}");
    public Task<HelpArticleView?> ArticleAsync(int companyId, string code) => GetOrNull<HelpArticleView>($"{Base}/article/{Uri.EscapeDataString(code)}?companyId={companyId}");

    public Task<HelpPageView?> PageAsync(int companyId, string? pageCode, string? controller, string? action) =>
        GetOrNull<HelpPageView>($"{Base}/page?companyId={companyId}&pageCode={Uri.EscapeDataString(pageCode ?? "")}&controller={Uri.EscapeDataString(controller ?? "")}&action={Uri.EscapeDataString(action ?? "")}");

    public async Task<HelpAnswer> AskAsync(HelpAskRequest request)
    {
        var r = await Client.PostAsJsonAsync($"{Base}/ask", request);
        r.EnsureSuccessStatusCode();
        return await r.Content.ReadFromJsonAsync<HelpAnswer>() ?? new();
    }

    public async Task FeedbackAsync(HelpFeedbackRequest request) => (await Client.PostAsJsonAsync($"{Base}/feedback", request)).EnsureSuccessStatusCode();

    public async Task<HelpFeedbackList> FeedbackListAsync(int companyId) => await GetOrNull<HelpFeedbackList>($"{Base}/feedback?companyId={companyId}") ?? new();

    // the assistant's learning (SQLScripts/2301)
    public async Task<HelpLearningStats> LearningStatsAsync(int companyId) => await GetOrNull<HelpLearningStats>($"{Base}/learning/stats?companyId={companyId}") ?? new();
    public async Task TeachAsync(HelpTeachRequest request) => (await Client.PostAsJsonAsync($"{Base}/learning/teach", request)).EnsureSuccessStatusCode();
    public async Task ForgetAsync(int companyId, int learnedId, int? userId) =>
        (await Client.PostAsync($"{Base}/learning/forget/{learnedId}?companyId={companyId}&userId={userId}", null)).EnsureSuccessStatusCode();
}
