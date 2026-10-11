# Contributing to SplashBar

Thanks for helping! The project is deliberately small (one Swift file), so
there's a low barrier to entry.

## How to contribute

1. **Fork** the repo and create a branch from `main`
   (e.g. `git checkout -b fix/memory-readout`).
2. Make your change. Keep commits focused; write commit messages that explain
   *what* and *why*, in English (this repo is community-facing; German is fine
   for issues/discussions if that's your preference).
3. Build and test on your Mac:
   ```sh
   bash build.sh && /Applications/SplashBar.app/Contents/MacOS/SplashBar
   ```
4. Push the branch and open a **pull request** from your fork.
5. In the PR description: what changed, why, and a screenshot of the menu
   (before/after if it changes the UI).

### Good first contributions

- Showing the currently loaded model (from `GET /v1/models`) in the menu
- Localizing the menu (currently English; German strings live in `main.swift`)
- An Apple Silicon memory readout that doesn't shell out to `footprint`
  (via `proc_info`/`host_statistics`)
- A release workflow (`brew` tap or DMG in GitHub Actions)

## Conventions

- Swift 5, Cocoa, no external dependencies
- Shell-outs go through the `sh()` helper; new ones belong in small,
  single-purpose functions with a comment saying *why*
- The app must keep working when Splash is absent or uninstalled
