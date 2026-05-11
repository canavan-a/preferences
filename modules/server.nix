{ config, pkgs, ...}
{
	environment.systemPackages = with pkgs; [
		monero-cli
		tor	
	];
}

