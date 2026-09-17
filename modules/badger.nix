{ config, pkgs, lib, ... }:
{
	users.users."badger" = {
		isNormalUser = true;
		description = "badger";
		extraGroups = [ "networkmanager" "wheel" ];
		packages = with pkgs; [];
	};

	services.superbadger = {
		enable = true;
		mullvad.enable = true;
	};

	# This host's Wi-Fi network hands out IPv6 ULA addresses with no default
	# route (IP6.GATEWAY is empty, no ::/0 route) - likely internal mesh
	# backhaul addressing, not real IPv6 internet access. cloudflared's QUIC
	# transport still tries IPv6 as part of its dual-stack dial and fails
	# with "sendmsg: operation not permitted" instead of falling back
	# cleanly, so force it to IPv4 only. Scoped to this host (not
	# cloudflare/cf.nix) since other hosts' tunnels work fine as-is.
	#
	# This host also runs Mullvad, which routes all traffic through its
	# tunnel and severs cloudflared's connection to Cloudflare's edge when
	# connected. mullvad-exclude uses Mullvad's split-tunneling support
	# (cgroup net_cls) to route cloudflared's traffic outside the Mullvad
	# tunnel, so both can run at once.
	systemd.services.cloudflared-tunnel = {
		after = [ "mullvad-daemon.service" ];
		wants = [ "mullvad-daemon.service" ];
		serviceConfig.ExecStart = lib.mkForce (
			pkgs.writeShellScript "cloudflared-tunnel-run-badger" ''
				set -euo pipefail
				token="$(cat /etc/cloudflared/token)"
				exec ${pkgs.mullvad}/bin/mullvad-exclude ${pkgs.cloudflared}/bin/cloudflared tunnel --edge-ip-version 4 run --token "$token"
			''
		);
	};
}
