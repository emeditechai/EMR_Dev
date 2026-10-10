# Fetches the offline handwriting model used by LAB billing AI assist (TrOCR small, handwritten; ONNX).
# Usage (PowerShell, on the server):  .\download-trocr.ps1 -Target "C:\inetpub\EMR.Web\AiModels\trocr-small-handwritten"
param([string]$Target = "EMR.Web\AiModels\trocr-small-handwritten")
$base = "https://huggingface.co/Xenova/trocr-small-handwritten/resolve/main"
New-Item -ItemType Directory -Force -Path $Target | Out-Null
foreach ($f in @("onnx/encoder_model.onnx", "onnx/decoder_model.onnx", "tokenizer.json")) {
    Write-Host "Downloading $f ..."
    Invoke-WebRequest -Uri "$base/$f" -OutFile (Join-Path $Target (Split-Path $f -Leaf))
}
Write-Host "Done: $Target"
