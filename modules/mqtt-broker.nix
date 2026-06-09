{config, pkgs, lib, ...}:
{
	environment.systemPackages = with pkgs; [
		mosquitto
		mosquitto.dev	
	];
		
	services.mosquitto = {
		enable = true;
		listeners = [{
			port = 1883;
			omitPasswordAuth = true;
			settings.allow_anonymous = true;
			acl = [ "pattern readwrite #" ];
		}];
	};
	networking.firewall.allowedTCPPorts = [ 1883 ];
}
