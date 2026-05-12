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
	    url = "github:nix-community/stylix";
	    inputs.nixpkgs.follows = "nixpkgs";
	};
  };


  outputs = { self, nixpkgs, sops-nix, hyprland, home-manager, stylix, ... } @ inputs: {
	nixosConfigurations = {
		desktop = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			specialArgs = {inherit inputs; };
			modules = [
				./common.nix 
				./hardware-configuration.nix
				./modules/desktop.nix
				./modules/micro.nix
				./modules/keyd.nix
				home-manager.nixosModules.home-manager
				sops-nix.nixosModules.sops
				hyprland.nixosModules.default
			];	
		};
		server = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			modules = [
				./common.nix 
				./hardware-configuration.nix
				./modules/server.nix
				sops-nix.nixosModules.sops
			];	
		};
	};
  };
}
