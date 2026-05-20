{
  description = "desktop and server configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-25.11";
	sops-nix.url = "github:Mic92/sops-nix";
	hyprland.url = "github:hyprwm/Hyprland/v0.55.0";
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


  outputs = { self, nixpkgs, sops-nix, hyprland, home-manager, stylix, home-server, ... } @ inputs: 
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
				./hardware-configuration-M70s.nix
				./modules/desktop.nix
				./modules/keyd.nix
				./modules/dir.nix
				./modules/micro.nix
				./cloudflared-nixos-aidan-house.nix
				home-manager.nixosModules.home-manager
				sops-nix.nixosModules.sops
				hyprland.nixosModules.default
				stylix.nixosModules.stylix
			];	
		};
		server = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			modules = serverBase ++[
				./hardware-configuration-M70s.nix
				./cloudflared-nixos-aidan-house.nix
			];	
		};
		homeServer = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			modules = serverBase ++ [
				./hardware-configuration-M70s.nix
				./cloudflared-nixos-aidan-house.nix
				home-server.nixosModules.default
				{ 
					services.home-server.streamer.enable = true;	
				}
			];
		};
		
	};
  };
}
