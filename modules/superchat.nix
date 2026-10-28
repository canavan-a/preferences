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
		# Loopback only.
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
		# Loopback only, next to Super Chat's 8080/8081; the Super Matrix
		# relay publishes it as superatlas.lunargen.com. The web client is
		# served from the same port, at /.
		listenAddr = "127.0.0.1:8090";
		publicOrigin = "https://superatlas.lunargen.com";
		# Signing key SHA-256s, so invite links open the app directly: the
		# release key (sideload builds; super-atlas/release/gen-keystore.sh
		# prints it), and once the first bundle is uploaded, Play's app signing
		# key (Play Console → App integrity → App signing).
		androidCertSha256 = [
			"C7:B6:A9:20:2F:A5:17:1F:6D:5D:DE:7A:0F:35:BD:22:3B:90:1B:62:D7:7A:59:75:2D:EB:A8:F4:AE:FD:B5:AC"
		];
		web.enable = true;
		# The Gmail account sign-in codes are sent from, put on the box once:
		#   sudo install -D -m 600 -o root /dev/stdin /etc/superatlas/env <<EOF
		#   SUPERATLAS_SMTP_EMAIL=...
		#   SUPERATLAS_SMTP_APP_PASSWORD=...
		#   EOF
		# The service won't start until this file exists.
		environmentFile = "/etc/superatlas/env";
		# Google Play build notifications (Firebase service account key),
		# put on the box once with
		# `sudo install -D -m 600 -o root <key>.json /etc/superatlas/fcm.json`
		# (the service won't start until it exists).
		fcmCredentialsFile = "/etc/superatlas/fcm.json";
		# App store review sign-in: this email always takes this code, isn't
		# emailed, and needs no `superatlas-admin allow`.
		reviewAccount = {
			email = "tester@lunargen.com";
			code = "222222";
		};
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
}
