{ config, pkgs, lib, modulesPath, ... }:
{
	# The Super Matrix server: a dedicated EC2 box (us-east-2, t3a.small,
	# instance i-0c9fe676237b9f40f, Elastic IP 13.184.85.196, security group
	# "supermatrix": 80/tcp, 443/tcp, 443/udp open, 22 from home only).
	#
	# Doesn't use serverBase: common.nix's Mullvad would route replies to the
	# public out through the VPN, its systemd-boot doesn't fit the EC2 image,
	# and its desktop tooling is too much for a 2 GB box.
	#
	# Deploy from the desktop (builds there, copies the closure over):
	#   nixos-rebuild switch --flake /etc/nixos#matrix \
	#     --target-host root@13.184.85.196
	# with ~/.ssh/nixos-key.pem (the "nixos-key" EC2 key pair) for root.
	imports = [ "${modulesPath}/virtualisation/amazon-image.nix" ];

	nix.settings.experimental-features = [ "nix-command" "flakes" ];
	networking.hostName = "matrix";
	time.timeZone = "America/New_York";

	# Key-only SSH. Log in as matrix with the desktop's id_ed25519
	# (~/run/matrix.sh); root takes the "nixos-key" EC2 key pair, for
	# nixos-rebuild --target-host (the amazon image also installs it at boot).
	services.openssh.settings = {
		PasswordAuthentication = false;
		KbdInteractiveAuthentication = false;
		PermitRootLogin = "prohibit-password";
	};
	users.users.root.openssh.authorizedKeys.keys = [
		(builtins.readFile ./matrix-root.pub)
	];
	users.users.matrix = {
		isNormalUser = true;
		extraGroups = [ "wheel" ];
		openssh.authorizedKeys.keys = [
			"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINkDkDEINpPrafUIlAoUt950tL6ZiUC6bFpvxEC14A49"
		];
	};
	# The matrix user has no password (key-only), so sudo can't ask for one.
	security.sudo.wheelNeedsPassword = false;

	# Super Matrix's activation script builds the server (go build) and the
	# web app (npm ci + vite) on the box; 2 GB of RAM isn't enough for that.
	swapDevices = [ { device = "/swapfile"; size = 4096; } ];

	nix.gc = {
		automatic = true;
		dates = "weekly";
		options = "--delete-older-than 14d";
	};

	environment.systemPackages = with pkgs; [ git htop sqlite curl ];

	# Installed from the NixOS 25.11 AMI.
	system.stateVersion = "25.11";
}
