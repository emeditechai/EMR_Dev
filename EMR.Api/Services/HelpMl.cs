using Microsoft.ML;
using Microsoft.ML.Data;
using Microsoft.ML.Transforms.Text;

namespace EMR.Api.Services;

/// <summary>
/// The machine-learning side of the Help Assistant (ML.NET): a text classifier (word 1-2 grams + character 3-grams,
/// SDCA maximum entropy) trained in memory - one model learns what a question is ABOUT (help topics and screens, trained
/// from the help content), one learns what the user WANTS (how-to, next step, before, whole workflow, problem, where).
/// Nothing leaves the server; the models are rebuilt from the help content when it changes.
/// </summary>
public sealed class HelpTextClassifier
{
    private sealed class Row
    {
        public string Text { get; set; } = "";
        public string Label { get; set; } = "";
    }

    private sealed class Prediction
    {
        [ColumnName("Score")] public float[] Score { get; set; } = [];
    }

    private readonly PredictionEngine<Row, Prediction> _engine;
    private readonly string[] _labels;
    private readonly Lock _gate = new();   // a PredictionEngine is not thread safe

    private HelpTextClassifier(PredictionEngine<Row, Prediction> engine, string[] labels)
    {
        _engine = engine;
        _labels = labels;
    }

    public int Classes => _labels.Length;

    public static HelpTextClassifier Train(IEnumerable<(string Text, string Label)> examples, int iterations = 40)
    {
        var ml = new MLContext(seed: 7);
        var data = ml.Data.LoadFromEnumerable(examples.Where(e => !string.IsNullOrWhiteSpace(e.Text))
                                                      .Select(e => new Row { Text = HelpText.Normalize(e.Text), Label = e.Label }));
        var pipeline = ml.Transforms.Conversion.MapValueToKey("Label")
            .Append(ml.Transforms.Text.FeaturizeText("Features", new TextFeaturizingEstimator.Options
            {
                CaseMode = TextNormalizingEstimator.CaseMode.Lower,
                KeepDiacritics = false, KeepPunctuations = false, KeepNumbers = true,
                // words and word pairs ("next step", "b2c bill"), plus character 3-grams so typos still match
                WordFeatureExtractor = new WordBagEstimator.Options { NgramLength = 2, UseAllLengths = true },
                CharFeatureExtractor = new WordBagEstimator.Options { NgramLength = 3, UseAllLengths = false },
                Norm = TextFeaturizingEstimator.NormFunction.L2
            }, nameof(Row.Text)))
            .Append(ml.MulticlassClassification.Trainers.SdcaMaximumEntropy("Label", "Features", maximumNumberOfIterations: iterations));
        var model = pipeline.Fit(data);

        // the class names in the order of the Score vector
        VBuffer<ReadOnlyMemory<char>> names = default;
        model.GetOutputSchema(data.Schema)["Score"].Annotations.GetValue("SlotNames", ref names);
        var labels = names.DenseValues().Select(n => n.ToString()).ToArray();
        return new HelpTextClassifier(ml.Model.CreatePredictionEngine<Row, Prediction>(model), labels);
    }

    /// <summary>The classes with their probability, best first.</summary>
    public List<(string Label, double P)> Predict(string text, int top = 10)
    {
        float[] scores;
        lock (_gate) scores = _engine.Predict(new Row { Text = HelpText.Normalize(text) }).Score;
        return scores.Select((p, i) => (_labels[i], (double)p)).OrderByDescending(x => x.Item2).Take(top).ToList();
    }

    /// <summary>The probability of every class (for blending with the keyword ranking).</summary>
    public Dictionary<string, double> All(string text)
    {
        float[] scores;
        lock (_gate) scores = _engine.Predict(new Row { Text = HelpText.Normalize(text) }).Score;
        var d = new Dictionary<string, double>(scores.Length, StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < scores.Length; i++) d[_labels[i]] = scores[i];
        return d;
    }
}

/// <summary>What the user wants from a question.</summary>
public static class HelpIntent
{
    public const string HowTo = "HOWTO", Next = "NEXT", Before = "BEFORE", Flow = "FLOW", Problem = "PROBLEM", Where = "WHERE";

    /// <summary>The intent model: the built-in sentences plus what was learned from use (confirmed answers, admin teaching).</summary>
    public static HelpTextClassifier Train(IEnumerable<(string Text, string Intent)> learned) => HelpTextClassifier.Train(Examples().Concat(learned), 60);

    public static (string Intent, double P) Predict(HelpTextClassifier? model, string question)
    {
        if (model is null) return (HowTo, 0);
        var best = model.Predict(question, 1)[0];
        return (best.Label, best.P);
    }

    /// <summary>Training sentences: patterns of each intent filled with the subjects users ask about.</summary>
    public static IEnumerable<(string, string)> Examples()
    {
        string[] things =
        [
            "a b2c bill", "the lab bill", "b2c booking", "b2b booking", "creating the bill", "billing", "sample collection", "collecting the sample",
            "result entry", "entering results", "report approval", "approving the report", "the report is approved", "dispatch", "patient registration",
            "registering a patient", "the consultation", "service booking", "vitals", "token", "adding a test", "investigation master", "rate list",
            "the profile", "a new branch", "creating a user", "smtp settings", "the email template", "a campaign", "sample transfer", "un-authorize",
            "day closing", "the opd bill", "doctor roster", "adding a doctor", "ward master", "bed master", "the invoice", "franchise top up", "this screen", "this page", "this step", "this"
        ];
        string[] acts =
        [
            "create a b2c bill", "cancel a lab bill", "add a doctor", "print the report", "reset my password", "give access to a user", "collect a sample",
            "approve a report", "set up email", "book a consultation", "register a patient", "add a new test", "change the rate", "send report on whatsapp",
            "transfer a sample", "close the day", "create a profile", "add a branch", "refund a bill", "redeem membership points", "export to excel",
            "send a campaign", "edit an email template", "record vitals", "make a package", "apply discount"
        ];
        string[] places = ["ward master", "lab reporting", "sample collection", "b2c booking", "role permissions", "smtp settings", "the workload report",
                           "email logs", "doctor master", "rate list", "hospital settings", "day closing", "audit log", "campaigns"];

        string[] next =
        [
            "after {0} what is the next step", "after {0} what is next", "what next after {0}", "what is the next step after {0}", "{0} done, what now",
            "once {0} is done what should i do", "what to do after {0}", "after {0} where do i go", "next step of {0}", "i have finished {0} then what",
            "what comes after {0}", "after {0} what should i do next", "what happens after {0}", "after {0} next", "{0} is complete what is the next process",
            "then what after {0}", "next process after {0}", "where to go after {0}"
        ];
        string[] before =
        [
            "what should be done before {0}", "before {0} what is needed", "prerequisite for {0}", "what must be ready before {0}",
            "what do i need before {0}", "what comes before {0}", "previous step of {0}", "what to set up before {0}", "requirements for {0}",
            "before {0} what should i do", "what is required for {0}", "what step is before {0}", "what has to be done first for {0}"
        ];
        string[] flow =
        [
            "what is the process of {0}", "workflow of {0}", "full flow of {0}", "explain the {0} process", "complete process for {0}",
            "end to end {0}", "{0} lifecycle", "show the workflow of {0}", "how does {0} work end to end", "order of steps for {0}",
            "all steps of {0}", "step by step process of {0}", "{0} workflow", "process flow of {0}", "what are the stages of {0}",
            "what is the first step of {0}", "where do i start {0}", "how to start {0}", "what is the first step for {0}", "where to begin {0}"
        ];
        string[] howto =
        [
            "how do i {0}", "how to {0}", "steps to {0}", "i want to {0}", "can i {0}", "{0}", "help me {0}", "how can i {0}", "way to {0}",
            "guide to {0}", "need to {0}", "how should i {0}"
        ];
        string[] problem =
        [
            "{0} not working", "cannot {1}", "unable to {1}", "error when i {1}", "{0} failed", "why is {0} missing", "i can't {1}",
            "{0} not showing", "{0} is not appearing", "getting error in {0}", "{0} is stuck", "why can't i {1}", "{0} gives an error", "problem with {0}"
        ];
        string[] where =
        [
            "where is {0}", "where can i find {0}", "which menu has {0}", "open {0}", "where do i find the {0} page", "navigate to {0}",
            "in which menu is {0}", "where is the {0} screen", "location of {0}", "how to open {0}"
        ];

        foreach (var t in things)
        {
            foreach (var p in next) yield return (string.Format(p, t), HelpIntent.Next);
            foreach (var p in before) yield return (string.Format(p, t), HelpIntent.Before);
            foreach (var p in flow) yield return (string.Format(p, t), HelpIntent.Flow);
        }
        for (var i = 0; i < acts.Length; i++)
        {
            foreach (var p in howto) yield return (string.Format(p, acts[i]), HelpIntent.HowTo);
            foreach (var p in problem) yield return (string.Format(p, things[i % things.Length], acts[i]), HelpIntent.Problem);
        }
        foreach (var pl in places)
            foreach (var p in where) yield return (string.Format(p, pl), HelpIntent.Where);
        // whole-process questions without a subject
        foreach (var s in new[] { "show me the workflow", "what is the workflow", "explain the process", "lab workflow", "opd workflow",
                                  "complete lab process", "what is the order of work", "full process" })
            yield return (s, HelpIntent.Flow);
    }
}

/// <summary>Text clean-up shared by the classifiers and the keyword ranking.</summary>
public static partial class HelpText
{
    /// <summary>Lower case, common spellings of B2C / B2B and similar joined ("b@c", "b 2 c", "b to c" -> "b2c").</summary>
    public static string Normalize(string? text)
    {
        var s = (text ?? "").ToLowerInvariant();
        s = B2x().Replace(s, m => "b2" + m.Groups[1].Value);
        s = s.Replace("e-mail", "email").Replace("re-collect", "recollect").Replace("re-test", "retest")
             .Replace("un-authorize", "unauthorize").Replace("un-authorise", "unauthorize").Replace("un-approve", "unapprove")
             .Replace("log in", "login").Replace("sign in", "signin").Replace("set up", "setup").Replace("day end", "dayend");
        return s;
    }

    [System.Text.RegularExpressions.GeneratedRegex(@"\bb\s*(?:2|@|to|two)\s*([bc])\b")]
    private static partial System.Text.RegularExpressions.Regex B2x();
}
