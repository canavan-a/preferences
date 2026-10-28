{
  description = "desktop and server configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
	home-manager = {
		url = "github:nix-community/home-manager/release-26.05";
		inputs.nixpkgs.follows = "nixpkgs";	
	};
	stylix = {
	    # url = "github:canavan-a/stylix/stable-base";
		url = "github:nix-community/stylix/release-26.05";	
	    inputs.nixpkgs.follows = "nixpkgs";
	};
	home-server.url = "github:canavan-a/home-server"; 
	open-lock.url = "github:canavan-a/open-lock";
		fleetman.url = "github:canavan-a/fleetman";
	spinnyfetch.url = "github:canavan-a/spinnyfetch";
	horus-33 = {
		url = "github:canavan-a/horus-33";
		inputs.nixpkgs.follows = "nixpkgs";
	};
	super-badger.url = "github:canavan-a/super-badger";
	super-chat.url = "github:canavan-a/super-chat";
	super-atlas.url = "github:canavan-a/super-atlas";
	super-matrix.url = "github:canavan-a/super-matrix";
  };


  outputs = { self, nixpkgs, nixos-hardware, home-manager, stylix, home-server, open-lock, fleetman, nixpkgs-unstable, horus-33, super-badger, super-chat, super-atlas, super-matrix, ... } @ inputs:
  	let 
  	unstable = import nixpkgs-unstable {
  		system = "x86_64-linux";
  		config.allowUnfree = true;
  	};
	serverBase = [
		./common.nix
		./modules/server.nix
		./modules/micro.nix
		home-manager.nixosModules.home-manager
	];
	in
	{
	nixosConfigurations = {
		desktop = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			specialArgs = {inherit inputs unstable fleetman; };
			modules = [
				./common.nix 
				nixos-hardware.nixosModules.framework-16-7040-amd
				./hardware-configuration-framework-16.nix
				./modules/desktop.nix
				./modules/cb-cli.nix
				./modules/work.nix
				./modules/keyd.nix
				./modules/dir.nix
				./modules/micro.nix
				./modules/mqtt-broker.nix
				./modules/5gbandforce.nix
				./modules/claude-code-router.nix
				home-manager.nixosModules.home-manager
				stylix.nixosModules.stylix
				open-lock.nixosModules.default
				# The `supermatrix` SSH client (ProxyCommand / forward). Add
				# deployments to sshHosts to get ssh_config entries for them.
				super-matrix.nixosModules.client
				{
					programs.supermatrix.enable = true;
				}
				# Super Matrix relay. It dials out to the server, so it needs no
				# open ports; which services it forwards is set in the app. The
				# token (smr_…, shown when the relay is added in the app) stays
				# out of the store:
				#   sudo install -Dm600 /dev/stdin /etc/supermatrix/relay-token
				super-matrix.nixosModules.relay
				{
					services.supermatrix-relay = {
						enable = true;
						serverUrl = "https://aidan.supermatrix.io";
						tokenFile = "/etc/supermatrix/relay-token";
					};
				}
			];
		};
		server =nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			modules = serverBase ++[
				./hardware-configuration-M70s.nix
				./cloudflare/cf.nix
			];	
		};
		homeServer = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			modules = serverBase ++ [
				./hardware-configuration-M70s.nix
				./cloudflare/cf.nix
				home-server.nixosModules.default
				{ 
					services.home-server.streamer.enable = true;	
				}
			];
		};

		bwServer = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			modules = serverBase ++ [
				# hardware configuration file here
				
			];
		};

		neo = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			modules = serverBase ++ [
				./hardware-configuration-neo.nix
				./modules/mqtt-broker.nix
				horus-33.nixosModules.default
				open-lock.nixosModules.default
				super-matrix.nixosModules.relay
				./modules/neoHomeServer.nix
			];
		};

		wrx = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			modules = serverBase ++ [
				./hardware-configuration-wrx.nix
				./modules/wrx80-local-ai.nix
				./modules/nixstrata.nix
				# Super Matrix relay. It dials out to the server, so it needs no
				# open ports; which services it forwards is set in the app. The
				# token (smr_…, shown when the relay is added in the app) stays
				# out of the store:
				#   sudo install -Dm600 /dev/stdin /etc/supermatrix/relay-token
				super-matrix.nixosModules.relay
				{
					services.supermatrix-relay = {
						enable = true;
						serverUrl = "https://aidan.supermatrix.io";
						tokenFile = "/etc/supermatrix/relay-token";
					};
				}
			];
		};

		badger = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			modules = serverBase ++ [
				./hardware-configuration-badger.nix

				./modules/badger.nix
				super-badger.nixosModules.default
				super-matrix.nixosModules.relay
			];
		};

		# The old stealth-operation server, now running Super Chat and Super Atlas.
		superchat = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			modules = serverBase ++ [
				./hardware-configuration-superchat.nix
				./modules/superchat.nix
				super-chat.nixosModules.default
				super-atlas.nixosModules.default
				super-matrix.nixosModules.relay
			];
		};

		# Dedicated EC2 box for Super Matrix (see modules/matrix.nix).
		matrix = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			modules = [
				./modules/matrix.nix
				./modules/supermatrix.nix
				super-matrix.nixosModules.default
			];
		};

	};
  };
}
