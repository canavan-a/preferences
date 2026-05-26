# cb-cli.nix
{ pkgs, ... }:
{
  environment.systemPackages = [
    (pkgs.stdenv.mkDerivation {
      pname = "cb-cli";
      version = "2026.1.4";
      src = pkgs.fetchurl {
        url = "https://github.com/ClearBlade/cb-cli/releases/download/2026.1.4/cb-cli-linux-amd64.tar.gz";
        sha256 = "ab0fb42567fa0b243aeef03c7c9aede3335b1b56afc4fcba87c6a2ec3a7b2794";
      };
      nativeBuildInputs = [ pkgs.autoPatchelfHook ];
      installPhase = ''
        mkdir -p $out/bin
        cp cb-cli $out/bin/
      '';
    })
  ];
}
