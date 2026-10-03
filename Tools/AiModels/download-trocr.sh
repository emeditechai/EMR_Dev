#!/bin/bash
# Fetches the offline handwriting model used by LAB billing AI assist (TrOCR small, handwritten; ONNX).
# Usage (repo root):  bash Tools/AiModels/download-trocr.sh [target folder]
# Default target: EMR.Web/AiModels/trocr-small-handwritten  (on a published server: <site>/AiModels/trocr-small-handwritten)
set -e
DIR="${1:-EMR.Web/AiModels/trocr-small-handwritten}"
BASE="https://huggingface.co/Xenova/trocr-small-handwritten/resolve/main"
mkdir -p "$DIR"
for f in onnx/encoder_model.onnx onnx/decoder_model.onnx tokenizer.json; do
  echo "Downloading $f ..."
  curl -fL --retry 3 -o "$DIR/$(basename "$f")" "$BASE/$f"
done
echo "Done: $DIR"
