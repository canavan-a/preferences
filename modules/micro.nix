{config, pkgs, lib, ...}:
{
	environment.systemPackages = with pkgs; [
		micro
	];
	
	home-manager.users.nixos = {
		home.stateVersion = "25.11";	
		programs.micro = {
			enable = true;
			settings = {
				syntax = true;
				linter = true;
			};
		};

		home.file.".config/micro/bindings.json".text = builtins.toJSON {
		  "Alt-/" = "lua:comment.comment";
		  "CtrlW" = "DeleteWordLeft";
		  "CtrlUnderscore" = "lua:comment.comment";
		  "Escape" = "command:quit";
		};
	};
}
