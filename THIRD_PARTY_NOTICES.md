# Third-party notices

This file records reviewed dependencies and runtime-downloaded models used by MeetingScribe. It is not a substitute for the complete license texts that must be bundled with a release.

## FluidAudio

- Project: FluidAudio
- Author: FluidInference Team and contributors
- Source: https://github.com/FluidInference/FluidAudio
- Reviewed version: `0.15.5`
- Reviewed commit: `19600a485baa4998812e4654b70d2bab8f2c9949`
- License: Apache License 2.0

MeetingScribe links FluidAudio as a Swift Package dependency. A release that ships this dependency must include the Apache 2.0 license and retain applicable copyright and attribution notices.

## Parakeet TDT 0.6B v3 Core ML model

- Runtime repository: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- Reviewed repository revision: `aed02740059203c4a87495924f685de3722ae9ce`
- Parent model: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- Model author: NVIDIA
- Core ML conversion: FluidInference
- Governing attribution decision: Creative Commons Attribution 4.0 International (CC BY 4.0)

The model is downloaded separately at the user's request and is not committed to this repository. Product UI and release documentation must retain the model name, authorship/origin, source links, reviewed revision, and CC BY 4.0 notice.

## Speaker diarization Core ML model

- Runtime repository: https://huggingface.co/FluidInference/speaker-diarization-coreml
- Reviewed repository revision: `1ed7a662fdc7109e36d822db793ee6eebdaf8594`
- Parent model: https://huggingface.co/pyannote/speaker-diarization-community-1
- Model origins: pyannote, WeSpeaker, and the FluidInference Core ML conversion
- Governing attribution decision: Creative Commons Attribution 4.0 International (CC BY 4.0)

The model is downloaded separately at the user's request and is not committed to this repository. Product UI and release documentation must retain the model name, authorship/origin, source links, reviewed revision, and CC BY 4.0 notice.
