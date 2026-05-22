{
  description = "desktop and server configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-25.11";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
	sops-nix.url = "github:Mic92/sops-nix";
	home-manager = {
		url = "github:nix-community/home-manager/release-25.11";
		inputs.nixpkgs.follows = "nixpkgs";	
	};
	stylix = {
	    # url = "github:canavan-a/stylix/stable-base";
		url = "github:nix-community/stylix/release-25.11";	
	    inputs.nixpkgs.follows = "nixpkgs";
	};
	home-server.url = "github:canavan-a/home-server"; 
  };


  outputs = { self, nixpkgs, nixos-hardware, sops-nix, home-manager, stylix, home-server, ... } @ inputs:
  	let 
	serverBase = [
		./common.nix
		./modules/server.nix
		./modules/micro.nix
		home-manager.nixosModules.home-manager
		sops-nix.nixosModules.sops
	];
	in
	{
	nixosConfigurations = {
		desktop = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			specialArgs = {inherit inputs; };
			modules = [
				./common.nix 
				nixos-hardware.nixosModules.framework-16-7040-amd
				./hardware-configuration-framework-16.nix
				./modules/desktop.nix
				./modules/keyd.nix
				./modules/dir.nix
				./modules/micro.nix
				(import ./cloudflare/config.nix { 
					uuid = "d49c6f4d-1a09-4071-a495-cacbf3f80ab8";
					ingress = {
						"nixos.aidan.house".service = "ssh://127.0.0.1:22";
					};
				})
				home-manager.nixosModules.home-manager
				sops-nix.nixosModules.sops
				stylix.nixosModules.stylix
			];	
		};
		server = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			modules = serverBase ++[
				./hardware-configuration-M70s.nix
				(import ./cloudflare/config.nix { 
					uuid = "d49c6f4d-1a09-4071-a495-cacbf3f80ab8";
					ingress = {
						"nixos.aidan.house".service = "ssh://127.0.0.1:22";
					};
				})
			];	
		};
		homeServer = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			modules = serverBase ++ [
				./hardware-configuration-M70s.nix
				(import ./cloudflare/config.nix { 
					uuid = "d49c6f4d-1a09-4071-a495-cacbf3f80ab8";
					ingress = {
						"nixos.aidan.house".service = "ssh://127.0.0.1:22";
					};
				})
				home-server.nixosModules.default
				{ 
					services.home-server.streamer.enable = true;	
				}
			];
		};
		
	};
  };
}
