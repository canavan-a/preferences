{
  description = "desktop and server configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-25.11";
	sops-nix.url = "github:Mic92/sops-nix";
  };


  outputs = { self, nixpkgs, sops-nix }: {
	nixosConfigurations = {
		desktop = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			modules = [
				./common.nix 
				./hardware-configuration.nix
				./modules/desktop.nix
				sops-nix.nixosModules.sops
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
