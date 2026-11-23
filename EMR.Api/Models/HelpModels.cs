namespace EMR.Api.Models;

// Utility > Help Center (SQLScripts/2300): api/help over usp_Help_* procedures.

public class HelpMenuRow
{
    public int MenuId { get; set; }
    public string MenuCode { get; set; } = "";
    public string Title { get; set; } = "";
    public int? ParentMenuId { get; set; }
    public int SortOrder { get; set; }
    public string? Icon { get; set; }
}

public class HelpPageRow
{
    public string PageCode { get; set; } = "";
    public string Title { get; set; } = "";
    public string MenuCode { get; set; } = "";
    public string? Controller { get; set; }
    public string? Action { get; set; }
    public string? Icon { get; set; }
    public int SortOrder { get; set; }
}

public class HelpControlRow
{
    public string PageCode { get; set; } = "";
    public string Title { get; set; } = "";
}

public class HelpArticleRow
{
    public string Code { get; set; } = "";
    public string Kind { get; set; } = "";
    public string Module { get; set; } = "";
    public string Title { get; set; } = "";
    public string Summary { get; set; } = "";
    public string? PageCodes { get; set; }
    public string? Keywords { get; set; }
    public string BodyJson { get; set; } = "{}";
    public int SortOrder { get; set; }
}

// ── what the Web pages show ──

public class HelpLink
{
    public string Code { get; set; } = "";
    public string Title { get; set; } = "";
    public string? Url { get; set; }
    public string? Path { get; set; }
    public string? Note { get; set; }
    /// <summary>The short answer / description (FAQs and troubleshooting show it inline).</summary>
    public string? Summary { get; set; }
}

public class HelpArticleView
{
    public string Code { get; set; } = "";
    public string Kind { get; set; } = "";
    public string Module { get; set; } = "";
    public string ModuleTitle { get; set; } = "";
    public string Title { get; set; } = "";
    public string Summary { get; set; } = "";
    public List<string> Steps { get; set; } = [];
    public List<string> Tips { get; set; } = [];
    public List<HelpLink> Prereq { get; set; } = [];
    public List<HelpLink> Next { get; set; } = [];
    public List<HelpLink> Pages { get; set; } = [];
    public List<HelpLink> Related { get; set; } = [];
    /// <summary>The workflows this topic is part of (for a workflow: itself), with its step marked.</summary>
    public List<HelpWorkflowView> Workflows { get; set; } = [];
}

/// <summary>A workflow: the order the work happens in, with the step asked about (Current) and the answer step (Highlight).</summary>
public class HelpWorkflowView
{
    public string Code { get; set; } = "";
    public string Title { get; set; } = "";
    public string Summary { get; set; } = "";
    public int Current { get; set; } = -1;
    public int Highlight { get; set; } = -1;
    public List<HelpFlowStepView> Steps { get; set; } = [];
}

public class HelpFlowStepView
{
    public string Title { get; set; } = "";
    public string Do { get; set; } = "";
    public string? When { get; set; }
    public bool Optional { get; set; }
    public string? ArticleCode { get; set; }
    public HelpLink? Page { get; set; }
}

public class HelpModuleView
{
    public string Code { get; set; } = "";
    public string Title { get; set; } = "";
    public string Summary { get; set; } = "";
    public string Icon { get; set; } = "";
    /// <summary>The setup order: what must be ready before this module is used.</summary>
    public List<HelpLink> Setup { get; set; } = [];
    public List<HelpLink> Workflows { get; set; } = [];
    public List<HelpLink> Guides { get; set; } = [];
    public List<HelpLink> Faqs { get; set; } = [];
    public List<HelpLink> Troubles { get; set; } = [];
    /// <summary>Every page of the module, grouped by its menu.</summary>
    public List<HelpPageGroup> Groups { get; set; } = [];
    public int PageCount { get; set; }
}

public class HelpPageGroup
{
    public string Title { get; set; } = "";
    public List<HelpLink> Pages { get; set; } = [];
}

/// <summary>Help for one page: written guides when there are some, otherwise built from its menu and actions.</summary>
public class HelpPageView
{
    public string PageCode { get; set; } = "";
    public string Title { get; set; } = "";
    public string Path { get; set; } = "";
    public string? Url { get; set; }
    public string Module { get; set; } = "";
    public string ModuleTitle { get; set; } = "";
    public List<string> Actions { get; set; } = [];
    /// <summary>Pages to set up / use before this one (the module's setup order and the guides' prerequisites).</summary>
    public List<HelpLink> Before { get; set; } = [];
    public List<HelpLink> After { get; set; } = [];
    public List<HelpArticleView> Guides { get; set; } = [];
    public List<string> GeneralSteps { get; set; } = [];
    public List<HelpLink> Faqs { get; set; } = [];
    public List<HelpLink> Troubles { get; set; } = [];
    public bool HasWrittenGuide { get; set; }
    /// <summary>The workflows this screen is part of, with its step marked.</summary>
    public List<HelpWorkflowView> Workflows { get; set; } = [];
}

public class HelpHomeView
{
    public List<HelpModuleView> Modules { get; set; } = [];
    public List<HelpLink> QuickStart { get; set; } = [];
    public List<HelpLink> Workflows { get; set; } = [];
    public List<HelpLink> Faqs { get; set; } = [];
    public List<HelpLink> Troubles { get; set; } = [];
    public int PageCount { get; set; }
    public int ArticleCount { get; set; }
}

public class HelpAskRequest
{
    public int CompanyId { get; set; }
    public int? UserId { get; set; }
    public string Question { get; set; } = "";
    public string? PageCode { get; set; }
    /// <summary>Data answers (SQLScripts/2321): the branch (null = Super Admin without a branch: all) and what the user may
    /// see - LAB, OPD, SAMPLES, PATIENTS - from the page permissions (EMR.Web). Empty = help answers only.</summary>
    public int? BranchId { get; set; }
    public List<string> DataScopes { get; set; } = [];
}

public class HelpAnswer
{
    public bool Found { get; set; }
    /// <summary>LOCAL (help content ranking) or AI (Claude, grounded on the help content).</summary>
    public string Source { get; set; } = "LOCAL";
    public string? Title { get; set; }
    public string? Kind { get; set; }
    public string? Code { get; set; }
    public string Text { get; set; } = "";
    public List<string> Steps { get; set; } = [];
    public List<HelpLink> Pages { get; set; } = [];
    public List<HelpLink> Related { get; set; } = [];
    public double Confidence { get; set; }
    /// <summary>What the user wanted (ML.NET): HOWTO, NEXT, BEFORE, FLOW, PROBLEM or WHERE.</summary>
    public string? Intent { get; set; }
    /// <summary>Where the answer sits in the application's workflow.</summary>
    public HelpWorkflowView? Workflow { get; set; }
    /// <summary>The answer comes from what the assistant learned (confirmed by users or taught by an administrator).</summary>
    public bool Learned { get; set; }
    /// <summary>A data answer (Kind DATA).</summary>
    public HelpDataView? Data { get; set; }
    /// <summary>Opened at once ("open bill LAB/HO2627000295").</summary>
    public string? OpenUrl { get; set; }
}

/// <summary>Ask AI data answer (SQLScripts/2321): facts, a small table and actions (e.g. Open Bill).</summary>
public class HelpDataView
{
    public List<HelpDataFact> Facts { get; set; } = [];
    public List<string> Columns { get; set; } = [];
    public List<HelpDataRow> Rows { get; set; } = [];
    public List<HelpDataAction> Actions { get; set; } = [];
    public string? Note { get; set; }
}

public class HelpDataFact
{
    public string Label { get; set; } = "";
    public string Value { get; set; } = "";
    /// <summary>good / warn / bad (colour of the value).</summary>
    public string? Tone { get; set; }
}

public class HelpDataRow
{
    public List<string> Cells { get; set; } = [];
    public string? Url { get; set; }
}

public record HelpDataAction
{
    public string Title { get; set; } = "";
    public string Url { get; set; } = "";
    public string? Icon { get; set; }
    public bool Primary { get; set; }
}

public class HelpGapRow
{
    public string Question { get; set; } = "";
    public int Asked { get; set; }
    public int Users { get; set; }
    public int NotFound { get; set; }
    public decimal AvgConfidence { get; set; }
    public DateTime LastAsked { get; set; }
}

public class HelpLearningRunRow
{
    public DateTime RunDate { get; set; }
    public int Promoted { get; set; }
    public int Demoted { get; set; }
    public int Signals { get; set; }
}

public class HelpGapsView
{
    public List<HelpGapRow> Gaps { get; set; } = [];
    public HelpLearningRunRow? LastRun { get; set; }
}

public class HelpFeedbackRequest
{
    public int CompanyId { get; set; }
    public int? UserId { get; set; }
    public string? ArticleCode { get; set; }
    public string? PageCode { get; set; }
    public string? Question { get; set; }
    public bool? Helpful { get; set; }
    public string? Comment { get; set; }
    /// <summary>The answer's kind and what the user wanted (the assistant learns from them).</summary>
    public string? Kind { get; set; }
    public string? Intent { get; set; }
    /// <summary>CLICK: a related topic opened from an answer (no vote).</summary>
    public string? Signal { get; set; }
}

/// <summary>An administrator teaches the assistant the right topic for a question (Help Insights).</summary>
public class HelpTeachRequest
{
    public int CompanyId { get; set; }
    public int? UserId { get; set; }
    public string Question { get; set; } = "";
    public string? TargetCode { get; set; }
    public string? Intent { get; set; }
}

public class HelpDayStat
{
    public DateTime Day { get; set; }
    public int Asked { get; set; }
    public int Answered { get; set; }
    public int Helpful { get; set; }
    public int NotHelpful { get; set; }
}

public class HelpLearnedView
{
    public int LearnedId { get; set; }
    public string Question { get; set; } = "";
    public string? TargetCode { get; set; }
    public string? TargetTitle { get; set; }
    public string? Intent { get; set; }
    public string Source { get; set; } = "";
    public int UpVotes { get; set; }
    public int DownVotes { get; set; }
    public int Clicks { get; set; }
    public DateTime ModifiedDate { get; set; }
    public string? ByUser { get; set; }
}

/// <summary>Help Insights: the daily trend of the last 30 days, what has been learned and the topics that can be taught.</summary>
public class HelpLearningStats
{
    public List<HelpDayStat> Days { get; set; } = [];
    public List<HelpLearnedView> Learned { get; set; } = [];
    public List<HelpLink> Topics { get; set; } = [];
}

public class HelpFeedbackRow
{
    public string? Question { get; set; }
    public string? ArticleCode { get; set; }
    public string? ArticleTitle { get; set; }
    public bool? Helpful { get; set; }
    public string? Comment { get; set; }
    public DateTime CreatedDate { get; set; }
    public string? UserName { get; set; }
}

public class HelpArticleScore
{
    public string Code { get; set; } = "";
    public string Title { get; set; } = "";
    public int Helpful { get; set; }
    public int NotHelpful { get; set; }
}

public class HelpFeedbackList
{
    public List<HelpFeedbackRow> Open { get; set; } = [];
    public List<HelpArticleScore> Scores { get; set; } = [];
}

/// <summary>A learned question (usp_Help_Learned_List).</summary>
public class HelpLearnedRow
{
    public int LearnedId { get; set; }
    public string QuestionKey { get; set; } = "";
    public string Question { get; set; } = "";
    public string? TargetCode { get; set; }
    public string? Intent { get; set; }
    public string Source { get; set; } = "";
    public int UpVotes { get; set; }
    public int DownVotes { get; set; }
    public int Clicks { get; set; }
    public DateTime ModifiedDate { get; set; }
}
