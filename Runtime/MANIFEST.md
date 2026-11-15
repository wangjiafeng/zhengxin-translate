# Runtime manifest

## llama.cpp

- Version: `b10783`
- Upstream: `https://github.com/ggml-org/llama.cpp/releases/tag/b10783`
- arm64 archive SHA-256: `7ca85491f7bcbc7b52ddb3142f04fac4eb3a694a22a36b76951d851479b97501`
- x86_64 archive SHA-256: `9719033d42747e4c7d083ec79688f36c3e43aa0189f5445a5559f8d9272e9048`
- Apple Silicon runtime: `Runtime/arm64/`
- Intel runtime: `Runtime/x86_64/`

TranslateGemma is launched with `--no-jinja --chat-template gemma`. The APP constructs TranslateGemma's source/target-aware translation instruction before calling the local OpenAI-compatible endpoint.

## BookForge

- Version: `v2.6.1`
- arm64 binary: `Runtime/arm64/bookforge`
- x86_64 binary: `Runtime/x86_64/bookforge`
- x86_64 archive SHA-256: `8de565ea6007e466de55e71da6ea39a0938ff471e8443b7198e597d984b62f0a`

## Model

- File: `Models/translategemma-4b-it.Q4_K_M.gguf`
- Size: `2489909760` bytes
- SHA-256: `81200d03e843d2ec1ece6eeafe7d13cb6e5211e1fcd336ade55790b683a08330`
- The model is not embedded in the APP bundle.

