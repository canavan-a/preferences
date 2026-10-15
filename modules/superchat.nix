{ config, pkgs, lib, ... }:
{
	# Pangolin tunnel client, same as the badger host: `sudo newtctl init
	# <endpoint> <id> <secret>` once.
	imports = [ ./newt.nix ];

	# This is the old stealth-operation box (hardware-configuration-superchat.nix
	# is its generated hardware config). It was installed with legacy BIOS GRUB
	# on the NVMe disk and has no EFI partition, while common.nix assumes
	# systemd-boot on EFI like every other host, so boot the way it was
	# installed.
	boot.loader.systemd-boot.enable = lib.mkForce false;
	boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
	boot.loader.grub = {
		enable = true;
		device = "/dev/nvme0n1";
	};

	# Installed at 26.05 (common.nix says 25.11 for the older hosts).
	system.stateVersion = lib.mkForce "26.05";

	# Logins: the box's existing `nixos` user (from common.nix, password SSH,
	# wheel) is unchanged. Users are mutable, so its current password carries
	# over and the rebuild can't lock anyone out.

	services.superchat = {
		enable = true;
		# Loopback only; cloudflared publishes it (see below).
		listenAddr = "127.0.0.1:8080";
		publicOrigin = "https://chat.superbadger.io";
		# Fill in with the release key's SHA-256 so invite links open the app
		# directly: keytool -list -v -keystore super-chat/release/release.keystore
		androidCertSha256 = [ ];
		web.enable = true;
		web.listenAddr = "127.0.0.1:8081";
		# FCM wake-ups for the Google Play build of the app: the Firebase
		# service account key (Firebase console → Project settings → Service
		# accounts → Generate new private key), put on the box once with
		# `sudo install -D -m 600 -o root <key>.json /etc/superchat/fcm.json`.
		# Not in the Nix store; the service reads it via LoadCredential.
		fcmCredentialsFile = "/etc/superchat/fcm.json";
	};

	# Cloudflare tunnel: `sudo cf init <token>` once, then in the Cloudflare
	# dashboard route chat.superbadger.io → http://localhost:8080 (and, if you
	# want the browser client, another hostname → http://localhost:8081).
	#
	# common.nix enables Mullvad on every host; if it's ever connected it
	# would cut cloudflared off from Cloudflare's edge, so run cloudflared
	# outside the Mullvad tunnel the same way the badger host does.
	systemd.services.cloudflared-tunnel = {
		after = [ "mullvad-daemon.service" ];
		wants = [ "mullvad-daemon.service" ];
		serviceConfig.ExecStart = lib.mkForce (
			pkgs.writeShellScript "cloudflared-tunnel-run-superchat" ''
				set -euo pipefail
				token="$(cat /etc/cloudflared/token)"
				exec ${pkgs.mullvad}/bin/mullvad-exclude ${pkgs.cloudflared}/bin/cloudflared tunnel --protocol http2 run --token "$token"
			''
		);
	};
}
