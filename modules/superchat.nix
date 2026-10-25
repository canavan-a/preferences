{ config, pkgs, lib, ... }:
{
	# Pangolin tunnel client: `sudo newtctl init <endpoint> <id> <secret>`
	# once.
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
		# Play's app signing key SHA-256 (Play Console → App integrity → App
		# signing), so invite links open the Google Play build directly.
		androidCertSha256 = [
			"43:DE:46:B6:30:53:13:CF:9A:A0:A1:F0:E7:FB:8C:50:C7:13:5B:7E:8C:CA:46:8D:FA:98:0B:DA:77:59:6A:93"
		];
		# The iOS app (Team ID.bundle ID), served in
		# /.well-known/apple-app-site-association so invite links open the
		# iPhone app directly.
		appleAppIds = [ "4W9H62B6C2.com.superchatapp" ];
		web.enable = true;
		web.listenAddr = "127.0.0.1:8081";
		# FCM wake-ups for the Google Play build of the app: the Firebase
		# service account key (Firebase console → Project settings → Service
		# accounts → Generate new private key), put on the box once with
		# `sudo install -D -m 600 -o root <key>.json /etc/superchat/fcm.json`.
		# Not in the Nix store; the service reads it via LoadCredential.
		fcmCredentialsFile = "/etc/superchat/fcm.json";
	};

	services.superatlas = {
		enable = true;
		# Loopback only, next to Super Chat's 8080/8081; cloudflared publishes
		# it (see below). The web client is served from the same port, at /.
		listenAddr = "127.0.0.1:8090";
		publicOrigin = "https://atlas.superbadger.io";
		# Fill in with the release key's SHA-256 so invite links open the app
		# directly: super-atlas/release/gen-keystore.sh prints it.
		androidCertSha256 = [ ];
		web.enable = true;
		# The Gmail account sign-in codes are sent from, put on the box once:
		#   sudo install -D -m 600 -o root /dev/stdin /etc/superatlas/env <<EOF
		#   SUPERATLAS_SMTP_EMAIL=...
		#   SUPERATLAS_SMTP_APP_PASSWORD=...
		#   EOF
		# The service won't start until this file exists.
		environmentFile = "/etc/superatlas/env";
		# Google Play build notifications (Firebase service account key), once
		# there's a Firebase project for super-atlas:
		# fcmCredentialsFile = "/etc/superatlas/fcm.json";
	};

	# Super Matrix relay, as on neo. It dials out to the server, so it needs
	# no open ports; which services it forwards is set in the app. Add this
	# box as its own relay in the app and put its token (smr_…) here, out of
	# the store:
	#   sudo install -Dm600 /dev/stdin /etc/supermatrix/relay-token
	services.supermatrix-relay = {
		enable = true;
		serverUrl = "https://aidan.supermatrix.io";
		tokenFile = "/etc/supermatrix/relay-token";
	};

	# Cloudflare tunnel: `sudo cf init <token>` once, then in the Cloudflare
	# dashboard route chat.superbadger.io → http://localhost:8080 (and, if you
	# want the browser client, another hostname → http://localhost:8081), and
	# atlas.superbadger.io → http://localhost:8090.
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
