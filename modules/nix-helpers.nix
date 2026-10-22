{ pkgs, ... }:
{
	# The nix* shell helpers (nixhelp lists them), on every host that imports
	# this: common.nix, and hosts like matrix that skip it.
	environment.systemPackages = [ pkgs.fastfetch ];

	programs.bash.interactiveShellInit = ''
fastfetch
nixrb() { sudo nixos-rebuild switch --flake /etc/nixos#"$1"; }
nixsync() { cd /etc/nixos && sudo git pull origin main; }
nixdiff() {
  local back="''${1:-0}"
  local cur=$(readlink /nix/var/nix/profiles/system | grep -oP '\d+')
  local new=$((cur-back))
  local old=$((new-1))
  nix store diff-closures "/nix/var/nix/profiles/system-$old-link" "/nix/var/nix/profiles/system-$new-link"
}
nixpv() {
  local out="/tmp/nixpreview-result"
  nix build --out-link "$out" /etc/nixos#nixosConfigurations."$1".config.system.build.toplevel || return 1
  nix store diff-closures /run/current-system "$out"
}
nixclean() {
  sudo nix-collect-garbage --delete-older-than 20d
}
nixclean-boot() {
  sudo nix-env --delete-generations +5 --profile /nix/var/nix/profiles/system
  sudo nix-collect-garbage
  sudo /run/current-system/bin/switch-to-configuration boot
}
nixhelp() {
  cat <<'EOF'
nixrb <host>    Rebuild and switch to the flake config for <host>.
nixsync         Pull the latest /etc/nixos config from origin main.
nixdiff [n]     Diff closures between system generations (n back, default 0) and n+1 back.
nixpv <host>    Build <host>'s config without switching and diff against the running system.
nixclean        Garbage-collect generations older than 20 days.
nixclean-boot   Keep only the last 5 system generations and free /boot space.
nixhelp         Show this list of custom nix commands.
EOF
}
'';
}
