# cb-cli.nix
{ pkgs, ... }:
{
  environment.systemPackages = [
    (pkgs.stdenv.mkDerivation {
      pname = "cb-cli";
      version = "2026.1.6";
      src = pkgs.fetchurl {
        url = "https://github.com/ClearBlade/cb-cli/releases/download/2026.1.6/cb-cli-linux-amd64.tar.gz";
        sha256 = "4d1b5b167cbe8b64bff9657e9741b9854b358132142a57f036478ecfec68818a";
      };
      sourceRoot = ".";
      nativeBuildInputs = [ pkgs.autoPatchelfHook ];
      installPhase = ''
        mkdir -p $out/bin
        cp cb-cli $out/bin/
      '';
    })
  ];
}
