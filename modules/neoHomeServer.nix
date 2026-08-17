{ config, pkgs, lib, ... }:
let
	# capture-eye's config as a real Nix attrset instead of a hand-written
	# JSON file — pkgs.writers.writeJSON renders it at build time, so it's
	# Nix-managed like everything else here. Trade-off: a config change now
	# needs a rebuild instead of `$EDITOR` + `systemctl restart` (the module's
	# normal fast loop) — worth it for keeping it all in one place.
	#
	# TODO: these device paths are placeholders. Find the real ones on the
	# target machine with:
	#   ls /dev/v4l/by-id/
	#   capture-eye --list-formats --device /dev/videoN   (via `nix develop
	#     horus-33` for the binary, or after the service is built once)
	#   ls /dev/serial/by-id/
	# and prefer the by-id symlinks over raw /dev/videoN or /dev/ttyACMN —
	# those can renumber across reboots.
	captureEyeConfig = pkgs.writers.writeJSON "capture-eye.json" {
		capture = {
			device = "/dev/v4l/by-id/REPLACE_ME";
			width = 1280;
			height = 720;
			fourcc = "MJPG";
			fps = 30;
		};
		serial = {
			port = "/dev/serial/by-id/REPLACE_ME";
		};
		sink = {
			rtsp_url = "rtsp://127.0.0.1:8554/eye";
		};
		clipping = {
			enabled = true;
			output_dir = "/var/lib/horus-capture-eye/clips";
			admin_socket_path = "/run/horus/clip-admin.sock";
		};
	};
in
{
	services.horus = {
		enable = true;
		repoUrl = "https://github.com/canavan-a/horus-33.git";
		configFile = captureEyeConfig;
		openFirewall = true;
	};
}
