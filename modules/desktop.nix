# desktop packages here

{ inputs, config, pkgs, lib, ... }:
{
	environment.systemPackages = with pkgs; [
		wayvnc
		kitty
		hyprcursor
		adwaita-icon-theme
		brave
		pulsemixer
		waybar
		hyprpaper
		hypridle
		brightnessctl
		wlsunset
	];
	
	# programs.waybar.enable = true;
	stylix.enable = true;
	stylix.polarity = "dark";
	stylix.image = ./wall/w6.jpg;
	stylix.opacity.terminal = 0.8;
	stylix.targets.chromium.enable = true;
	stylix.base16Scheme = "${pkgs.base16-schemes}/share/themes/twilight.yaml";
	networking.firewall.allowedTCPPorts = [ 5900 ];
	programs.bash.interactiveShellInit = ''
	  tput rmam
	'';
	
	home-manager.users.nixos = {
		services.hyprpaper.enable = true;
		programs.kitty.enable = true;
		programs.waybar.enable = true;
		services.hyprsunset = {
			enable = true;					
		};
		services.hypridle = {
			enable = true;
			settings = {
				listener = [
					{
						timeout = 1800;
						on-timeout = "hyprlock";
					}
				];
			};
		};


		programs.hyprlock = {
			enable = true;
			settings = {
				general	= {
					ignore_empty_input = true;	
				};


				input-field = lib.mkForce [{
					monitor = "";
					size = "300, 50";
					outline_thickness = 2;
					dots_size = 0.3;
					dots_spacing = 0.2;
					fade_on_empty = true;
					placeholder_text = "password";
					halign = "center";
					valign = "center";
				}];

				label = [
					{
						monitor = "";
						text = "$TIME";
						font_size = 64;
						halign = "center";
						valign = "top";
						position = "0, -100";
					}	
					{
						monitor = "";
						position = "0, -200";
						text = "cmd[update:1000] date '+%A, %B %d'";
						font_size = 24;
						halign = "center";
						valign = "top";
						# position = "0, -100";
					}
				];
				
			};
		};

		programs.hyprlock.settings = {};
		
		stylix.targets.vscode.enable = true;
		programs.vscode = {
			enable = true;
			package = pkgs.vscodium;	
		};
	  	programs.kitty.settings.confirm_os_window_close = 0;
	};

	services.greetd = {
		enable = true;
		settings.default_session = {
			command = "${pkgs.hyprland}/bin/Hyprland";
			user = "nixos";			
		};
	};
	environment.sessionVariables.WAYLAND_DISPLAY = "wayland-1";

	programs.hyprland = {
		enable = true;
		package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
		portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
		settings = {
			monitor = [ 
			"HEADLESS-1,2560x1600,0x0,6"
			"HDMI-A-2,2560x1600,0x0,1" ];
			exec-once = [
			"dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP" 
			"wayvnc --render-cursor 0.0.0.0"
			"waybar"
			"hyprpaper"
			"hypridle > /tmp/hypridle.log 2>&1"
			"hyprsunset"
			 ];	
			bind = [
				"ALT_R, T, exec, kitty"
				"ALT_R, B, exec, brave"
				"ALT_R, C, exec, codium"
				"ALT_R, Q, killactive,"
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
				"ALT_R SHIFT, E, exec, hyprlock"
				"ALT_R, O, resizeactive, -50 0"
				"ALT_R, P, resizeactive, 50 0"	
				"ALT_R SHIFT, O, resizeactive, 0 -50"
				"ALT_R SHIFT, P, resizeactive, 0 50"	
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

