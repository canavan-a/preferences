{config, pkgs, ...}:
{
	environment.systemPackages = with pkgs; [
	
	];
	
	home-manager.users.nixos = {
		systemd.user.tmpfiles.rules = [
			"d %h/canavan-a 0755 - - -"
			"d %h/work 0755 - - -"
			"d %h/other 0755 - - -"
			"d %h/scripts 0755 - - -"
			"d %h/notes 0755 - - -"
		];		
	};

	systemd.tmpfiles.rules = [
		"d /etc/nixos 0755 nixos users -"	
	];
}
