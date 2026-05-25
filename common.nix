# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
{ config, pkgs, ... }:
{

	nix.settings.experimental-features = ["nix-command" "flakes"];
	
	environment.variables = {
	  SOPS_AGE_KEY_FILE = "/etc/age/keys.txt";
	};

	sops = {
		age.keyFile = "/etc/age/keys.txt";
		defaultSopsFile = ./secrets/secrets.yaml;
		secrets.cloudflared-creds = {};	
	};

	# Bootloader.
	boot.loader.systemd-boot.enable = true;
	boot.loader.efi.canTouchEfiVariables = true;

	networking.hostName = "nixos"; # Define your hostname.
	# networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

	# Configure network proxy if necessary
	# networking.proxy.default = "http://user:password@proxy:port/";
	# networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

	# Enable networking
	networking.networkmanager.enable = true;

	# Set your time zone.
	time.timeZone = "America/New_York";

	# Select internationalisation properties.
	i18n.defaultLocale = "en_US.UTF-8";

	i18n.extraLocaleSettings = {
		LC_ADDRESS = "en_US.UTF-8";
		LC_IDENTIFICATION = "en_US.UTF-8";
		LC_MEASUREMENT = "en_US.UTF-8";
		LC_MONETARY = "en_US.UTF-8";
		LC_NAME = "en_US.UTF-8";
		LC_NUMERIC = "en_US.UTF-8";
		LC_PAPER = "en_US.UTF-8";
		LC_TELEPHONE = "en_US.UTF-8";
		LC_TIME = "en_US.UTF-8";
	};

	# Configure keymap in X11
	services.xserver.xkb = {
		layout = "us";
		variant = "";
	};

	# Define a user account. Don't forget to set a password with ‘passwd’.
	users.users.nixos = {
		 isNormalUser = true;
		 description = "nixos";
		 extraGroups = [
		   "networkmanager"
		   "wheel"
		 ];
		 packages = with pkgs; [ ];
	};

	# Allow unfree packages
	nixpkgs.config.allowUnfree = true;

	# List packages installed in system profile. To search, run:
	# $ nix search wget
	environment.systemPackages = with pkgs; [
		wget
		mullvad
		openvpn
		fastfetch
		git
		gh
		cloudflared
		sops
		age
		tmux
		ripgrep
		ffmpeg
		pciutils
		usbutils
		platformio
		nodejs
		tree
	];

	# Open ports in the firewall.
	# networking.firewall.allowedTCPPorts = [ ... ];
	# networking.firewall.allowedUDPPorts = [ ... ];
	# Or disable the firewall altogether.
	# networking.firewall.enable = false;
	networking.firewall.allowedTCPPorts = [ 22 ];

	# This value determines the NixOS release from which the default
	# settings for stateful data, like file locations and database versions
	# on your system were taken. It‘s perfectly fine and recommended to leave
	# this value at the release version of the first install of this system.
	# Before changing this value read the documentation for this option
	# (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
	system.stateVersion = "25.11"; # Did you read the comment?

	services.openssh.enable = true;

	# services.tor.enable = true;


	programs.bash.shellAliases = {
	};
	
	programs.bash.interactiveShellInit = ''
fastfetch
nixrb() { sudo nixos-rebuild switch --flake /etc/nixos#"$1"; }
nixsync() { cd /etc/nixos && sudo git pull origin main; }
'';

}
