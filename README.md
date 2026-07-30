<div align="center">

# ani-cli

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://readme-typing-svg.demolab.com?font=JetBrains+Mono&weight=600&size=14&pause=1200&color=FFFFFF&center=true&vCenter=true&width=440&lines=Stream+%26+torrent+anime+from+your+terminal" />
  <img src="https://readme-typing-svg.demolab.com?font=JetBrains+Mono&weight=600&size=14&pause=1200&color=000000&center=true&vCenter=true&width=440&lines=Stream+%26+torrent+anime+from+your+terminal" alt="Stream & torrent anime from your terminal" />
</picture>

<br>

<p align="center"><a href="https://github.com/Hehe1111111/CLI"><img src="https://img.shields.io/badge/Linux-000000?style=for-the-badge&logo=linux&logoColor=white" alt="Linux" /></a><a href="https://github.com/Hehe1111111/CLI"><img src="https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS" /></a><a href="https://github.com/Hehe1111111/CLI"><img src="https://custom-icon-badges.demolab.com/badge/Windows-000000?style=for-the-badge&logo=windows11&logoColor=white" alt="Windows" /></a></p>

<p align="center"><a href="https://github.com/Hehe1111111/CLI"><img src="https://img.shields.io/badge/Bash-000000?style=for-the-badge&logo=gnubash&logoColor=white" alt="Bash" /></a><a href="https://github.com/Hehe1111111/CLI"><img src="https://img.shields.io/badge/Python-000000?style=for-the-badge&logo=python&logoColor=white" alt="Python" /></a><a href="./LICENSE"><img src="https://img.shields.io/badge/MIT-000000?style=for-the-badge&logo=opensourceinitiative&logoColor=white" alt="MIT License" /></a></p>

</div>

<br>

### Install

**macOS / Linux (Homebrew):**
```bash
brew tap Hehe1111111/tap
brew install ani-cli
```

**Windows (Scoop):**
```powershell
scoop bucket add extras
scoop bucket add hehe1111111 https://github.com/Hehe1111111/scoop-bucket
scoop install ani-cli
```

Both pull dependencies (jq, fzf, mpv, python) as prebuilt binaries — no admin rights, no compiling, no waiting on apt/choco. Update any time with brew upgrade ani-cli or scoop update ani-cli.

<details>
<summary>Manual install (no package manager)</summary>

**Linux / macOS / Git Bash (Windows):**
```bash
curl -sL https://raw.githubusercontent.com/Hehe1111111/CLI/main/install.sh | bash
```

**Windows (PowerShell, run as Administrator):**
```powershell
irm https://raw.githubusercontent.com/Hehe1111111/CLI/main/install.ps1 | iex
```

Auto-detects your OS, resolves dependencies via your system package manager, and sets up `ani-cli`. Slower and needs admin/sudo, but works with zero extra tools.
</details>

### Quick start

```bash
ani-cli                    # launch interactive menu
ani-cli search <query>     # search AniList
ani-cli continue           # resume watching
ani-cli stream <id> <ep>   # stream an episode
ani-cli torrent <id> <ep>  # torrent-stream an episode
ani-cli auth               # re-authenticate with AniList
```

<sub>Navigate with <kbd>↑</kbd> <kbd>↓</kbd> · select with <kbd>↵</kbd> · back with <kbd>esc</kbd> · quit with <kbd>Ctrl+C</kbd></sub>

### Features

<small><small>

| Feature           | Description                                                                    |
| ----------------- | ------------------------------------------------------------------------------ |
| **Dual engine**   | Direct streams (kaa, uniquestream) raced in parallel, plus torrent via nyaa.si |
| **Auto tracking** | AniList sync — unwatched → watching, completed → rewatching, 80% rule          |
| **Smart resume**  | Position saved every 30s, resumable across stream and torrent                  |
| **OP/ED skip**    | AniSkip integration with auto-generated mpv chapters                           |
| **Autoplay**      | Next episode prefetched during playback                                        |
| **Fast resume**   | Hot window seek — playback starts in ~5s                                       |

</small></small>

### Requirements

<small><small>

| Required                          | Optional                    |
| --------------------------------- | --------------------------- |
| `curl` `jq` `fzf` `mpv` `python3` | `python3-libtorrent` `rofi` |
| bash ≥ 4                          |                             |

</small></small>

<details>
<summary>Providers</summary>
<br>

<small><small>

| Type        | Sources                                              |
| ----------- | ---------------------------------------------------- |
| **Stream**  | kaa (krussdomi.com), uniquestream (uniquestream.net) |
| **Torrent** | nyaa (nyaa.si)                                       |

</small></small>

</details>

<details>
<summary>Data paths</summary>
<br>

<small><small>

| Path                       | Purpose                             |
| -------------------------- | ----------------------------------- |
| `~/.config/ani-cli/config` | Settings                            |
| `~/.local/share/ani-cli/`  | Auth tokens, resume points, history |
| `/tmp/ani-cli_*`           | Caches                              |

</small></small>

</details>

<br>

<div align="center">
<small>Distributed under the <a href="./LICENSE">MIT License</a></small>
</div>
