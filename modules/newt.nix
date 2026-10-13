# Pangolin tunneling client (newt), shared by the hosts that use it. Managed
# the same way `cf` manages cloudflared: credentials live outside the nix
# store in /etc/pangolin/newt.env, written by `newtctl init`.
{ config, pkgs, lib, ... }:
{
	environment.systemPackages = [
		(pkgs.writeShellScriptBin "newtctl" ''
			set -euo pipefail
			ENV_FILE=/etc/pangolin/newt.env

			usage() {
				cat <<-EOF
				newtctl <command>

				  init <endpoint> <id> <secret>   Save Pangolin newt credentials and enable+start the service.
				  start                            Enable and start the newt service.
				  stop                             Stop and disable the newt service.
				  status                           Show the newt service status.
				  help                             Show this message.
				EOF
			}

			require_root() {
				if [ "$(id -u)" -ne 0 ]; then
					echo "newtctl $1 must be run as root (try: sudo newtctl $1)" >&2
					exit 1
				fi
			}

			case "''${1:-help}" in
				init)
					require_root init
					endpoint="''${2:-}"
					id="''${3:-}"
					secret="''${4:-}"
					if [ -z "$endpoint" ] || [ -z "$id" ] || [ -z "$secret" ]; then
						echo "usage: newtctl init <endpoint> <id> <secret>" >&2
						exit 1
					fi
					install -d -m 700 "$(dirname "$ENV_FILE")"
					umask 077
					printf 'PANGOLIN_ENDPOINT=%s\nNEWT_ID=%s\nNEWT_SECRET=%s\n' "$endpoint" "$id" "$secret" > "$ENV_FILE"
					systemctl enable --now newt.service
					;;
				start)
					require_root start
					systemctl enable --now newt.service
					;;
				stop)
					require_root stop
					systemctl disable --now newt.service
					;;
				status)
					systemctl status newt.service
					;;
				help|*)
					usage
					;;
			esac
		'')
	];

	systemd.services.newt = {
		description = "Pangolin newt tunneling client";
		after = [ "network-online.target" ];
		wants = [ "network-online.target" ];
		wantedBy = [ "multi-user.target" ];
		serviceConfig = {
			ExecStart = "${pkgs.fosrl-newt}/bin/newt";
			EnvironmentFile = "/etc/pangolin/newt.env";
			Restart = "on-failure";
			RestartSec = "5s";
		};
	};
}
