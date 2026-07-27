{ pkgs, ... }:
let
	tokenFile = "/etc/cloudflared/token";

	cf = pkgs.writeShellScriptBin "cf" ''
		set -euo pipefail
		TOKEN_FILE=${tokenFile}

		usage() {
			cat <<EOF
		cf <command>

		  init <token>   Save a Cloudflare Tunnel token and enable+start the service.
		  start          Enable and start the tunnel service.
		  stop           Stop and disable the tunnel service.
		  status         Show the tunnel service status.
		  help           Show this message.
		EOF
		}

		require_root() {
			if [ "$(id -u)" -ne 0 ]; then
				echo "cf $1 must be run as root (try: sudo cf $1)" >&2
				exit 1
			fi
		}

		case "''${1:-help}" in
			init)
				require_root init
				token="''${2:-}"
				if [ -z "$token" ]; then
					echo "usage: cf init <token>" >&2
					exit 1
				fi
				install -d -m 700 "$(dirname "$TOKEN_FILE")"
				umask 077
				printf '%s' "$token" > "$TOKEN_FILE"
				systemctl enable --now cloudflared-tunnel.service
				;;
			start)
				require_root start
				systemctl enable --now cloudflared-tunnel.service
				;;
			stop)
				require_root stop
				systemctl disable --now cloudflared-tunnel.service
				;;
			status)
				systemctl status cloudflared-tunnel.service
				;;
			help|*)
				usage
				;;
		esac
	'';

	runTunnel = pkgs.writeShellScript "cloudflared-tunnel-run" ''
		set -euo pipefail
		token="$(cat ${tokenFile})"
		exec ${pkgs.cloudflared}/bin/cloudflared tunnel run --token "$token"
	'';
in
{
	environment.systemPackages = [ cf pkgs.cloudflared ];

	systemd.services.cloudflared-tunnel = {
		description = "Cloudflare Tunnel (remotely managed)";
		after = [ "network-online.target" ];
		wants = [ "network-online.target" ];
		# Not wantedBy multi-user.target: stays inert until `cf init`/`cf start`
		# enables it, so a machine without a token yet still boots cleanly.
		serviceConfig = {
			ExecStart = "${runTunnel}";
			Restart = "on-failure";
			RestartSec = "5s";
		};
	};
}
