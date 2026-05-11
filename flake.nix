{
  description = "desktop and server configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-25.11";
	sops-nix.url = "github:Mic92/sops-nix";
	hyprland.url = "github:hyprwm/Hyprland";
  };


  outputs = { self, nixpkgs, sops-nix, hyprland, ... } @ inputs: {
	nixosConfigurations = {
		desktop = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			specialArgs = {inherit inputs; };
			modules = [
				./common.nix 
				./hardware-configuration.nix
				./modules/desktop.nix
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
