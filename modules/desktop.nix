# desktop packages here

{ inputs, config, pkgs, lib, ... }:
{
	environment.systemPackages = with pkgs; [
		kitty
		hyprcursor
		adwaita-icon-theme
		brave
		pulsemixer
		# waybar
		hyprpaper
		hypridle
		brightnessctl
		wev
		wl-clipboard
		nerd-fonts.jetbrains-mono
		networkmanagerapplet
		libnotify
	];

	boot.kernelPackages = pkgs.linuxPackagesFor (
	  pkgs.linux_latest.override {
	    argsOverride = rec {
	      version = "7.0.6";
	      modDirVersion = "7.0.6";
	      src = pkgs.fetchurl {
	        url = "mirror://kernel/linux/kernel/v7.x/linux-${version}.tar.xz";
	        sha256 = "08vm18wx6399phzgr3wz94yga3ab4fyca79445ygvbspm904996b";
	      };
	    };
	  }
	);

	users.users.nixos.extraGroups = [ "video" "dialout" ];
		
	services.blueman.enable = true;
	# services.logind.lidSwitch = "sudo systemctl suspend";
	security.sudo.extraRules = [{
	  commands = [{
	    command = "/run/current-system/sw/bin/systemctl suspend";
	    options = [ "NOPASSWD" ];
	  }
	  {
	  	command = "/run/current-system/sw/bin/brightnessctl";
	  	options = [ "NOPASSWD" ];
	  }];
	  users = [ "nixos" ];
	}];
	
	stylix.enable = true;
	stylix.polarity = "dark";
	stylix.image = ./wall/w6.jpg;
	stylix.fonts.sansSerif = {
		package = pkgs.nerd-fonts.jetbrains-mono;
		name = "JetBrainsMono Nerd Font Mono";	
	};
	stylix.opacity.terminal = 0.8;
	stylix.targets.chromium.enable = true;
	stylix.base16Scheme = "${pkgs.base16-schemes}/share/themes/twilight.yaml";
	networking.firewall.allowedTCPPorts = [ 5900 ];
	programs.bash.interactiveShellInit = ''
	  tput rmam
	'';

	home-manager.users.nixos = {
		programs.fuzzel.enable = true;
		programs.swayimg.enable = true;
		programs.mpv.enable = true;
		services.hyprpaper.enable = true;
		services.mako = {
			enable = true;
			defaultTimeout = 2000;
		};
		services.hyprsunset.enable = true;
		home.file.".config/fastfetch/config.jsonc".text = ''
				{
					"modules": [
					 "Title",
					 "Separator",
					 "OS",
					 "Host",
					 "Kernel",
					 "Uptime",
					 "Packages",
					 "Shell",
					 "Display",
					 "WM",
					 "Theme",
					 "Cursor",
					 "Terminal",
					 "TerminalFont",
					 "CPU",
					 "GPU",
					 "Memory",
					 "Swap",
					 "Disk",
					 "LocalIP",
					 "Battery",
					 "Locale"
					]
				}
		'';
		programs.waybar = {
			enable = true;
			style = ''
				#custom-nix {
					font-size: 25px;
					padding: 1px 8px 1px 8px;
				}
			'';
			settings = [{
				# spacing = 10;

				modules-left = [ "custom/nix" ];
				modules-center = [ "clock" ];
				modules-right = [ "bluetooth" "pulseaudio" "battery" "tray" "network" ];

				"clock" = {
				  format = "{:%I:%M %p}";
				  tooltip-format = "<big>{:%B %Y}</big>\n<tt><small>{calendar}</small></tt>";
				};

				"custom/nix" = {
					format = "󱄅";
					tooltip = false;
				};

				"bluetooth" = {
				  on-click = "blueman-manager";
				  format = " 󰂯 {num_connections} ";
				  format-disabled = "󰂲";
				  format-off = "󰂲";
				  tooltip-format = "{controller_alias}\n{num_connections} connected";
				  tooltip-format-connected = "{device_enumerate}";
				  tooltip-format-enumerate-connected = "{device_alias}";
				};

				"battery" = {
				  format = " {icon} {capacity}% ";
				  format-charging =  " 󰂄 {capacity}% ";
				  format-icons = [ "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹" ];
				};

				"pulseaudio" = {
				  format = "{icon} {volume}%";
				  format-icons = { default = [ "󰕿" "󰖀" "󰕾" ]; };
				  scroll-step = 5;
				};

				"network" = {
				  format-wifi = "{essid} ";
				  format-disconnected = "Disconnected ";
				};

				"tray" = {
				  spacing = 10;
				};
			}];	
		};
		stylix.targets.waybar = {
			enable = true;	
		};

		# programs.waybar.settings.mainBar.modules-left = [ "hyprland/workspaces" ];

		

		programs.kitty = {
			enable = true;
			settings.confirm_os_window_close = 0;
			keybindings = {
				"ctrl+shift+left" = "no_op";
				"ctrl+shift+right" = "no_op";
				"ctrl+backspace" = "send_text all \\x17";
			};
		};
		
		services.hypridle = {
			enable = true;
			settings = {
				listener = [
					{
						timeout = 2000;
						on-timeout = "sudo systemctl suspend";
					}
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

		


		wayland.windowManager.hyprland = {
			enable = true;
			# same nixpkgs package the system installs; keeps onChange auto-reload working.
			# portal stays with the NixOS programs.hyprland module.
			package = pkgs.hyprland;
			portalPackage = null;
			settings = {
				monitor = [
					",preferred,auto,1"
				# "HEADLESS-1,2560x1600,0x0,1"
				# "HDMI-A-2,2560x1600,0x0,1"
				];
				exec-once = [
				"dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP"
				"waybar"
				"hyprpaper"
				"nm-applet --indicator"
				"hypridle > /tmp/hypridle.log 2>&1"
				"hyprsunset"
				"mako"
				 ];
				bind = [
					"ALT_R, T, exec, kitty"
					"ALT_R, B, exec, brave"
					"ALT_R, C, exec, codium"
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
					"ALT_R, Tab, pin,"
					"ALT_R, Return, fullscreen,"
					"ALT_R SHIFT, E, exec, hyprlock"
					# "ALT_R, O, resizeactive, -50 0"
					# "ALT_R, P, resizeactive, 50 0"
					# "ALT_R SHIFT, O, resizeactive, 0 -50"
					# "ALT_R SHIFT, P, resizeactive, 0 50"
					"ALT_R, R, exec, fuzzel"
					"ALT_R, M, cyclenext,"
					"ALT_R, N, cyclenext, prev"
					", XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"
					", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
					", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
					"SHIFT, XF86AudioRaiseVolume, exec, brightnessctl set 5%+"
					"SHIFT, XF86AudioLowerVolume, exec, brightnessctl set 5%-"
					"SHIFT, XF86AudioMute, exec, pgrep hyprsunset && pkill hyprsunset || hyprsunset -t 2000"
				];

				binde = [
				  "ALT_R, O, resizeactive, -50 0"
				  "ALT_R, P, resizeactive, 50 0"
				  "ALT_R SHIFT, O, resizeactive, 0 -50"
				  "ALT_R SHIFT, P, resizeactive, 0 50"
				];
				
				bindl = [", switch:on:Lid Switch, exec, hyprlock & sudo systemctl suspend"];				
				env = [ "XCURSOR_SIZE,12" "WLR_NO_HARDWARE_CURSORS,1" "XCURSOR_THEME,Adwaita" ];
				input = {
					accel_profile = "flat";
				};
				decoration = {
					rounding = 2;
				};

				general = {
					border_size = 2;
					# border colors are managed by stylix
				};

			};
		};
	};

	services.greetd = {
		enable = true;
		settings.default_session = {
			command = "${pkgs.hyprland}/bin/Hyprland";
			user = "nixos";
		};
	};
	environment.sessionVariables.WAYLAND_DISPLAY = "wayland-1";

	programs.hyprland.enable = true;

	programs.bash.shellAliases = {
		sunset = "pkill hyprsunset; sleep 0.5 && setsid hyprsunset -t 2000 $1 & echo";
		daylight = "pkill hyprsunset; echo;";
		bup = "sudo brightnessctl set 10%+"; 
		bdown = "sudo brightnessctl set 10%-";
	};
}
