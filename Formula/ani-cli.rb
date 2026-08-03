class AniCli < Formula
  desc "Stream & torrent anime from your terminal"
  homepage "https://github.com/Hehe1111111/CLI"
  url "https://github.com/Hehe1111111/CLI.git", branch: "main"
  version "2.0.1"
  license "MIT"

  depends_on "bash"
  depends_on "curl"
  depends_on "jq"
  depends_on "fzf"
  depends_on "mpv"
  depends_on "python@3"
  depends_on "libtorrent-rasterbar" => :recommended

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