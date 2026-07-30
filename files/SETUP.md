# Fast-install setup for ani-cli

Two small repos turn `ani-cli` into a real "download & run" package on every
OS, using each platform's package manager to fetch `jq`/`fzf`/`mpv`/`python`
as **prebuilt binaries** — that's what actually removes the slowness/issues
in the current `install.sh`/`install.ps1` (those compile-or-fetch-from-apt
every single time on every machine).

## 1. macOS + Linux — Homebrew tap

Homebrew requires the tap repo to be named `homebrew-<something>`.

```bash
# create a new GitHub repo named exactly: homebrew-tap
gh repo create Hehe1111111/homebrew-tap --public
git clone https://github.com/Hehe1111111/homebrew-tap
cp Formula/ani-cli.rb homebrew-tap/Formula/
cd homebrew-tap && git add -A && git commit -m "ani-cli formula" && git push
```

Then, on any Mac or Linux box:
```bash
brew tap Hehe1111111/tap
brew install ani-cli
```

- No `sha256` in the formula — it installs via `git clone` of `main`, so
  `brew upgrade ani-cli` always pulls your latest commit.
- `libtorrent-rasterbar` is a `:recommended` dependency (installed by
  default, skip with `--without-libtorrent-rasterbar`) — Homebrew's build
  already ships the Python bindings, so torrents work out of the box.
- Bump the `version "2.0.0"` line in the formula whenever you bump
  `VERSION` in `run.sh` — it's cosmetic only (git install ignores it for
  fetching), just keeps `brew info ani-cli` accurate.

## 2. Windows — Scoop bucket

```bash
gh repo create Hehe1111111/scoop-bucket --public
git clone https://github.com/Hehe1111111/scoop-bucket
cp bucket/ani-cli.json scoop-bucket/bucket/
cd scoop-bucket && git add -A && git commit -m "ani-cli manifest" && git push
```

Then, in any PowerShell (no admin needed):
```powershell
scoop bucket add extras          # hosts mpv
scoop bucket add hehe1111111 https://github.com/Hehe1111111/scoop-bucket
scoop install ani-cli
```

This installs `git` (provides `bash.exe`), `jq`, `fzf`, `python`, and `mpv`
(from `extras`) as prebuilt Scoop packages, then a `post_install` step:
- writes `ani-cli.cmd`, a one-line wrapper that calls `bash.exe run.sh %*`
  (same pattern Scoop itself uses for bash-based tools like `pyenv`)
- best-effort `pip install libtorrent` — PyPI ships prebuilt Windows
  wheels for it, so torrents now work on Windows without WSL, unlike the
  current `install.ps1` which skips torrent support there entirely.

**Keeping the hash fresh:** unlike the Homebrew formula, Scoop manifests
pin an exact file hash, so after you push new commits to `main` you need
to refresh it once:
```bash
curl -sL -o /tmp/main.zip https://github.com/Hehe1111111/CLI/archive/refs/heads/main.zip
sha256sum /tmp/main.zip   # paste into ani-cli.json's "hash" field
```
Commit + push that to `scoop-bucket`, then `scoop update ani-cli` on any
machine picks it up. (The `checkver`/`autoupdate` blocks in the manifest
are wired for this — if you ever want it fully automatic, Scoop's bucket
template repo ships a GitHub Action that runs `checkver` on a schedule and
opens the PR for you.)

## 3. Two small patches to the app itself

- `skip-self-install-when-packaged.patch` — stops `run.sh` from creating a
  second, redundant `~/.local/bin/ani-cli` symlink when it's already
  running from a Homebrew/Scoop install.
- `readme-install-section.patch` — updates the README's Install section to
  lead with the two commands above, keeping the old `curl`/`irm` one-liners
  as a documented manual fallback.

Apply with `git apply <file>.patch` from the repo root, review, then commit.

## Why not a single dependency-free binary?

`mpv` is a full media player, `fzf`/`jq` are separate C/Go programs — none
of that can be statically linked into your bash script the way a Go/Rust
CLI's own code can. The two package managers above are the closest
practical equivalent: one command, prebuilt binaries, no compiling.
