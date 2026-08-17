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
	claude-code.url = "github:sadjow/claude-code-nix";
	fleetman.url = "github:canavan-a/fleetman";
	spinnyfetch.url = "github:canavan-a/spinnyfetch";
	horus-33 = {
		url = "github:canavan-a/horus-33";
		inputs.nixpkgs.follows = "nixpkgs";
	};
  };


  outputs = { self, nixpkgs, nixos-hardware, home-manager, stylix, home-server, open-lock, fleetman, nixpkgs-unstable, horus-33, ... } @ inputs:
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
				./cloudflare/cf.nix
				home-manager.nixosModules.home-manager
				stylix.nixosModules.stylix
				open-lock.nixosModules.default
			];	
		};
		server = nixpkgs.lib.nixosSystem {
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

		neoHomeServer = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			modules = serverBase ++ [
				# TODO: run `nixos-generate-config` on the target machine and
				# add the resulting hardware-configuration file here, e.g.:
				# ./hardware-configuration-neoHomeServer.nix
				./cloudflare/cf.nix
				./modules/mqtt-broker.nix
				horus-33.nixosModules.default
				./modules/neoHomeServer.nix
			];
		};
		
	};
  };
}
