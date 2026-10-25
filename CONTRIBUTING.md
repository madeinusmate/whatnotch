# Contributing

Thanks for your interest in Whatnotch.

## Before you open a PR

1. Search [existing issues](https://github.com/madeinusmate/whatnotch/issues) for duplicates.
2. For large changes (new bridge capabilities, sandbox policy, sidecar protocol), open an issue first so we can align on approach.
3. Keep pull requests focused — one logical change per PR.

## Development

Follow the **README** for requirements and how to run the app from Xcode.

Sidecar changes:

```bash
cd Sidecar
pnpm install
pnpm build
```

Then rebuild **Whatnotch** in Xcode so the post-build script rebundles `Sidecar/` into the app.

Swift changes should compile with the **Whatnotch** scheme on macOS 14+. Avoid checking in `build/`, `DerivedData/`, or `Sidecar/node_modules/`.

## Pull requests

- Describe user-visible behavior and include screenshots or screen recordings for notch/shelf UI changes when possible.
- Do not commit API keys, `.env` files, or personal signing identities.
- Update `Workspace/AGENTS.md` (and bump `whatnotch-spec-version` in that file) when agent-facing widget rules change. Keep `Workspace/.cursor/rules/whatnotch.mdc` aligned if the “do not explore” workflow changes.

## Security

Do not open public issues for security vulnerabilities. See the security note in the README for how to report them.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](./LICENSE).
