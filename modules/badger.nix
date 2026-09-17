{ config, pkgs, lib, ... }:
{
	users.users."badger" = {
		isNormalUser = true;
		description = "badger";
		extraGroups = [ "networkmanager" "wheel" ];
		packages = with pkgs; [];
	};

	services.superbadger = {
		enable = true;
	};
}
