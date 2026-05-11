{config, pkgs, ...}:
{
	environment.systemPackages = with pkgs; [
		micro
	];
	
	home-manager.users.nixos = {
		home.stateVersion = "25.11";	
		home.file.".config/micro/settings.json".text = builtins.toJSON {
		  colorscheme = "twilight";
		  syntax = true;
		  linter = true;
		};

		home.file.".config/micro/bindings.json".text = builtins.toJSON {
		  "Alt-/" = "lua:comment.comment";
		  "CtrlBackspace" = "DeleteWordLeft";
		  "CtrlUnderscore" = "lua:comment.comment";
		  "Escape" = "command:quit";
		};
	};
}
