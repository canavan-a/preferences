{ uuid, ingress }:{ config, pkgs, ... }:
{
    services.cloudflared = {
		enable = true;
		tunnels = {
			"${uuid}" = {
				credentialsFile = config.sops.secrets.cloudflared-creds.path;
				default = "http_status:404";
				ingress = ingress;
				};
			};
		};
	};
}