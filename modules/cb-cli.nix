# cb-cli.nix
{ pkgs, ... }:
{
  environment.systemPackages = [
    (pkgs.stdenv.mkDerivation {
      pname = "cb-cli";
      version = "2026.1.5";
      src = pkgs.fetchurl {
        url = "https://github.com/ClearBlade/cb-cli/releases/download/2026.1.5/cb-cli-linux-amd64.tar.gz";
        sha256 = "75b55524d75b2be3bd47190e01f28f8f5059e3694af4cf61e825a072892d3eed";
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
