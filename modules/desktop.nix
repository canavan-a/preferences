# desktop packages here

{ inputs, config, pkgs, ...}:
{
	environment.systemPackages = with pkgs; [
		wayvnc
j		kitty
		hyprcursor
		adwaita-icon-theme
		swww
		brave
		pulsemixer
	];

	networking.firewall.allowedTCPPorts = [ 5900 ];

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
			monitor = [ "HEADLESS-1,2560x1600,0x0,0.5" ];
			exec-once = [ 
				"wayvnc --render-cursor 0.0.0.0"
				"swww-daemon"
				"sleep 1 && swww img /etc/nixos/wall/w1.jpg"
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
				rounding = 10;	
			};

			general = {
				border_size = 2;
				"col.active_border" = "rgba(cba6f7ff)";
				"col.inactive_border" = "rgba(00000000)";	
			};

		};
		
	};

	environment.etc."xdg/kitty/kitty.conf".text = ''
	background_opacity 0.8
	background_blur 10
	include themes/Base2Tone_Cave_Dark.conf
	
	## name: Base2Tone Cave Dark
	## author: Bram de Haan (https://github.com/atelierbram)
	## license: MIT
	## upstream: https://github.com/atelierbram/Base2Tone-kitty/blob/main/themes/base2tone-cave-dark.conf
	## blurb: Duotone theme | cool cave red - yellow ochre
	
	
	#: The basic colors
	
	foreground #9f999b
	background #222021
	selection_foreground #9f999b
	selection_background #2f2d2e
	
	
	#: Cursor colors
	
	cursor #996e00
	cursor_text_color #222021
	
	
	#: URL underline color when hovering with mouse
	
	url_color #f0a8c1
	
	
	#: kitty window border colors and terminal bell colors
	
	active_border_color #565254
	inactive_border_color #222021
	bell_border_color #ad1f51
	visual_bell_color none
	
	
	#: OS Window titlebar colors
	
	wayland_titlebar_color #2f2d2e
	macos_titlebar_color #2f2d2e
	
	
	#: Tab bar colors
	
	active_tab_foreground #fbfaf9
	active_tab_background #222021
	inactive_tab_foreground #aeaca7
	inactive_tab_background #2f2d2e
	tab_bar_background #2f2d2e
	tab_bar_margin_color none
	
	
	#: Colors for marks (marked text in the terminal)
	
	mark1_foreground #222021
	mark1_background #875e6d
	mark2_foreground #222021
	mark2_background #8b8984
	mark3_foreground #222021
	mark3_background #aa7c09
	
	
	#: The basic 16 colors
	
	#: black
	color0 #222021
	color8 #635f60
	
	#: red
	color1 #936c7a
	color9 #ddaf3c
	
	#: green
	color2 #cca133
	color10 #2f2d2e
	
	#: yellow
	color3 #ffcc4d
	color11 #565254
	
	#: blue
	color4 #9c818b
	color12 #706b6d
	
	#: magenta
	color5 #cca133
	color13 #f0a8c1
	
	#: cyan
	color6 #d27998
	color14 #c39622
	
	#: white
	color7 #9f999b
	color15 #ffebf2
	'';
		
}

