#!/usr/bin/env bash
# Fetches the noise removal model for test/audio/noise_reference_test.dart,
# from the same two hosts the app uses (lib/speech/local_models.dart,
# noiseRemovalModel), and names it in KAPY_DENOISE_MODEL. The test checks the
# file's sha256 against the app's own, so the two cannot drift apart.
set -euo pipefail

path=Ceva-IP/DPDFNet/dd6818d00f50c836fed43a6243ebe49116de5964/onnx/dpdfnet2.onnx
sha=4f0ee28935b4a32abecc717d745416976565834d839601acf43031094b4dc94c
dest="$RUNNER_TEMP/dpdfnet2.onnx"

for url in "https://dl.kapynotes.com/models/$path" \
  "https://huggingface.co/${path/\/DPDFNet\//\/DPDFNet\/resolve\/}"; do
  if curl -fsSL --retry 5 --retry-all-errors -o "$dest" "$url" &&
    [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$sha" ]; then
    echo "KAPY_DENOISE_MODEL=$dest" >>"$GITHUB_ENV"
    echo "noise removal model from $url"
    exit 0
  fi
done
echo "::error::no host served the noise removal model with sha256 $sha"
exit 1
