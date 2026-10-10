namespace EMR.Web.Services.PrescriptionAssist;

/// <summary>
/// "PrescriptionAssist" section of appsettings: the optional AI assist of LAB billing that reads an uploaded
/// prescription (Tesseract OCR on this server - the image never leaves it) and suggests the tests it asks for
/// (ML.NET text matching against the bookable investigations / profiles).
/// </summary>
public sealed class PrescriptionAssistOptions
{
    public const string SectionName = "PrescriptionAssist";

    /// <summary>Shows the AI assist button. Off = the billing screens are exactly as before.</summary>
    public bool Enabled { get; set; } = true;

    /// <summary>Tesseract executable: a full path (e.g. C:\Program Files\Tesseract-OCR\tesseract.exe) or just "tesseract" when it is on PATH.</summary>
    public string TesseractPath { get; set; } = "tesseract";

    /// <summary>Tesseract language data to use, e.g. "eng".</summary>
    public string Languages { get; set; } = "eng";

    public int TimeoutSeconds { get; set; } = 45;

    public int MaxFileSizeMb { get; set; } = 8;

    /// <summary>Lowest match score (0-1) offered as a suggestion.</summary>
    public double MinScore { get; set; } = 0.42;

    /// <summary>
    /// Reads handwritten lines with the offline handwriting model (TrOCR, ONNX Runtime) as well as OCR. Skipped when
    /// off or when the model files are not found - OCR alone is then used.
    /// </summary>
    public bool HandwritingEnabled { get; set; } = true;

    /// <summary>Folder of the handwriting model (encoder_model.onnx, decoder_model.onnx, tokenizer.json); relative to the site.</summary>
    public string HandwritingModelPath { get; set; } = "AiModels/trocr-small-handwritten";

    /// <summary>Score (0-1) from which a suggestion is ticked for the user by default.</summary>
    public double PreselectScore { get; set; } = 0.60;
}
