{ config, pkgs, lib, ... }:
let
	# capture-eye's *initial* config as a Nix attrset. Passed as seedConfigFile,
	# so the module copies it to /etc/horus/capture-eye.json once — on the first
	# activation where that file does not exist — and never overwrites it after.
	# From then on the live config belongs to the host and `horusctl config`
	# edits it in place, which is what keeps a camera or serial-port change from
	# needing a commit and a rebuild. Editing the attrset below therefore only
	# affects a machine that has not been activated yet; to change a running
	# host, use horusctl.
	#
	# Device paths here are a starting guess. On the host itself:
	#   horusctl config devices                    # cameras + serial ports
	#   horusctl config devices --device /dev/videoN   # formats that camera has
	#   horusctl config set-video --device ... --restart
	# Prefer the by-id symlinks over raw /dev/videoN or /dev/ttyACMN — those can
	# renumber across reboots.
	captureEyeConfig = pkgs.writers.writeJSON "capture-eye.json" {
		capture = {
			device = "/dev/video1";
			width = 1280;
			height = 720;
			fourcc = "MJPG";
			fps = 30;
		};
		serial = {
			port = "/dev/ttyACM0";
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
	# Define a user account. Don't forget to set a password with ‘passwd’.
	users.users."neo" = {
		isNormalUser = true;
		description = "neo";
		extraGroups = [ "networkmanager" "wheel" ];
		packages = with pkgs; [];
	};

	networking.firewall.allowedTCPPorts = [ 33 8080 ];

	# VAAPI, so capture-eye can encode H.264 on the iGPU instead of burning the
	# cores inference needs. Only makes the hardware available: capture-eye
	# still encodes with libx264 until /etc/horus/capture-eye.json opts in with
	# "hardware_encode": true (see capture-eye/docs/config.md). Nothing else is
	# needed for the service to see it — its unit is unsandboxed and already
	# carries the "render" group, and libva finds the driver under
	# /run/opengl-driver.
	hardware.graphics = {
		enable = true;
		extraPackages = with pkgs; [ intel-media-driver ];
	};

	services.horus = {
		enable = true;
		repoUrl = "https://github.com/canavan-a/horus-33.git";
		# Seed, not the live path: configFile stays at its mutable default
		# (/etc/horus/capture-eye.json) so horusctl can edit it.
		seedConfigFile = captureEyeConfig;
		openFirewall = true;
		# Deploys the capture-eye build with the OpenVINO backend compiled in.
		# Only makes it *available* — which backend actually runs is
		# inference.backend in /etc/horus/capture-eye.json.
		openvino = true;
	};

	# open-lock web controller. mqtt-broker.nix already runs a local anonymous
	# mosquitto on :1883, so don't let this module manage its own broker — just
	# point at localhost. UI + lock API are served on :8080 (front it with the
	# Cloudflare tunnel; auth stays at Cloudflare Access).
	services.open-lock = {
		enable = true;
		manageBroker = false;
		mqttBroker = "127.0.0.1";
		mqttPort = 1883;
		mqttAnon = true;
	};
}
