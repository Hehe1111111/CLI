class AniCli < Formula
  desc "Stream & torrent anime from your terminal"
  homepage "https://github.com/Hehe1111111/CLI"
  url "https://github.com/Hehe1111111/CLI.git", branch: "main"
  version "2.0.0"   # bump this to match VERSION in run.sh on real releases
  license "MIT"

  # No sha256 needed: this checks out over git, so `brew install` and
  # `brew upgrade` always pull the latest commit on main. The *app* is a
  # bash script, so there's nothing to compile — only these deps below
  # get pulled as prebuilt bottles, which is what actually makes this fast.
  depends_on "curl"
  depends_on "jq"
  depends_on "fzf"
  depends_on "mpv"
  depends_on "python@3"
  depends_on "libtorrent-rasterbar" => :recommended  # skip with --without-libtorrent-rasterbar

  def install
    libexec.install Dir["*"]
    (libexec/"run.sh").chmod 0755
    (bin/"ani-cli").write_env_script libexec/"run.sh", {}
  end

  def caveats
    <<~EOS
      Config: ~/.config/ani-cli/config
      Data:   ~/.local/share/ani-cli/

      Update any time with:
        brew upgrade ani-cli
    EOS
  end

  test do
    assert_match "ani-cli", shell_output("#{bin}/ani-cli --help 2>&1", 0)
  end
end
