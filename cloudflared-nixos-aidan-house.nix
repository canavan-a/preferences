{ config, pkgs, ... }:
{
    services.cloudflared = {
		enable = true;
		tunnels = {
			"d49c6f4d-1a09-4071-a495-cacbf3f80ab8" = {
				credentialsFile = config.sops.secrets.cloudflared-creds.path;
				default = "http_status:404";
				ingress = {
				    	"nixos.aidan.house" = {
				    	service = "ssh://127.0.0.1:22";
					};
				};
			};
		
		};
	};
}