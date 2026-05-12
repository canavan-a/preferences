# desktop packages here

{ inputs, config, pkgs, ...}:
{
	environment.systemPackages = with pkgs; [
		wayvnc
j		kitty
		hyprcursor
		adwaita-icon-theme
		brave
		pulsemixer
		hyprpaper
		waybar
	];

	programs.waybar.enable = true;
	
	networking.firewall.allowedTCPPorts = [ 5900 ];

	home-manager.users.nixos = {
	  services.hyprpaper.enable = true;
	};

	services.greetd = {
		enable = true;
		settings.default_session = {
			command = "${pkgs.hyprland}/bin/Hyprland";
			user = "nixos";			
		};
	};

	programs.hyprland = {
		enable = true;
		package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
		portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
		settings = {
			monitor = [ "HEADLESS-1,2560x1600,0x0,2" ];
			exec-once = [ 
				"wayvnc --render-cursor 0.0.0.0"
				"waybar"
			 ];	
			bind = [
				"ALT_R, T, exec, kitty"
				"ALT_R, B, exec, brave"
				"ALT_R SHIFT, Q, killactive,"
				"ALT_R, H, movefocus, l"
				"ALT_R, L, movefocus, r"
				"ALT_R, K, movefocus, u"
				"ALT_R, J, movefocus, d"
				"ALT_R SHIFT, H, movewindow, l"
				"ALT_R SHIFT, L, movewindow, r"
				"ALT_R SHIFT, K, movewindow, u"
				"ALT_R SHIFT, J, movewindow, d"
				"ALT_R, A, workspace, 1"
				"ALT_R, S, workspace, 2"
				"ALT_R, D, workspace, 3"
				"ALT_R, F, workspace, 4"
				"ALT_R, G, workspace, 5"
				"ALT_R SHIFT, A, movetoworkspace, 1"
				"ALT_R SHIFT, S, movetoworkspace, 2"
				"ALT_R SHIFT, D, movetoworkspace, 3"
				"ALT_R SHIFT, F, movetoworkspace, 4"
				"ALT_R SHIFT, G, movetoworkspace, 5"
				"ALT_R, Space, togglefloating,"
				"ALT_R, Return, fullscreen,"
	
			];
			env = [ "XCURSOR_SIZE,12" "WLR_NO_HARDWARE_CURSORS,1" "XCURSOR_THEME,Adwaita" ];
			input = {
				accel_profile = "flat";	
			};
			decoration = {
				rounding = 2;
			};

			general = {
				border_size = 2;
				"col.active_border" = "rgba(cba6f7ff)";
				"col.inactive_border" = "rgba(00000000)";	
			};

		};
		
	};

	
		
}

