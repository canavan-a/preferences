{ config, pkgs, lib, ... }:
{
	users.users."badger" = {
		isNormalUser = true;
		description = "badger";
		extraGroups = [ "networkmanager" "wheel" ];
		packages = with pkgs; [];
	};

	services.superbadger = {
		enable = true;
		mullvad.enable = true;
		# block everything off-tunnel, but keep the LAN reachable
		mullvad.lockdown = true;
		mullvad.allowLan = true;
		web.enable = true;
	};

	# Super Matrix relay, as on neo. It dials out to the server, so it needs
	# no open ports; which services it forwards is set in the app. Add this
	# box as its own relay in the app and put its token (smr_…) here, out of
	# the store:
	#   sudo install -Dm600 /dev/stdin /etc/supermatrix/relay-token
	services.supermatrix-relay = {
		enable = true;
		serverUrl = "https://aidan.supermatrix.io";
		tokenFile = "/etc/supermatrix/relay-token";
	};

	# Run the relay outside the Mullvad tunnel (Mullvad's split tunneling):
	# through the tunnel every connection to it took a detour via the
	# Mullvad exit and was slow. Excluded processes still get out with
	# lockdown mode on.
	#
	# Joining Mullvad's net_cls cgroup takes root. The setuid wrapper can't
	# do it here: DynamicUser forces RestrictSUIDSGID, a seccomp filter, and
	# systemd sets NoNewPrivileges to apply that to a non-root service. So
	# "!" starts the command as root (the rest of the sandbox still applies),
	# mullvad-exclude joins the cgroup, and setpriv drops to the dynamic user
	# before the relay runs. ProtectControlGroups and ProtectKernelTunables
	# would both leave /sys/fs/cgroup read-only.
	systemd.services.supermatrix-relay = {
		after = [ "mullvad-daemon.service" ];
		wants = [ "mullvad-daemon.service" ];
		serviceConfig = {
			ExecStart = lib.mkForce "!${pkgs.mullvad}/bin/mullvad-exclude ${pkgs.util-linux}/bin/setpriv --reuid=supermatrix-relay --regid=supermatrix-relay --clear-groups /var/lib/supermatrix-relay/bin/supermatrix-relay";
			# For setpriv's switch to the relay's user; dropped as it switches.
			CapabilityBoundingSet = lib.mkForce [ "CAP_SETUID" "CAP_SETGID" ];
			ProtectControlGroups = lib.mkForce false;
			ProtectKernelTunables = lib.mkForce false;
		};
	};

	# services.superbadger.web's static web-client port (default listenAddr
	# ":8081" — see super-badger's module.nix).
	networking.firewall.allowedTCPPorts = [ 8081 ];

	# opencode-serve (from super-badger's module) has no User set, so it runs
	# as root and reads /root/.config/opencode/opencode.json - not the
	# home-manager-managed config below, which lives under badger's home.
	# Run it as badger so it actually picks up these providers.
	systemd.services.opencode-serve.serviceConfig.User = "badger";

	# Root access for the agent stack: opencode-serve (runs as badger, above)
	# and superbadger (super-badger's module runs it as the superbadger system
	# user) can both `sudo` anything without a password. NixOS services get a
	# minimal PATH, so put the setuid wrappers dir (/run/wrappers/bin, where
	# sudo lives) on it explicitly.
	security.sudo.extraRules = [{
		users = [ "badger" "superbadger" ];
		commands = [{ command = "ALL"; options = [ "NOPASSWD" ]; }];
	}];
	systemd.services.opencode-serve.path = [ "/run/wrappers" ];
	systemd.services.superbadger.path = [ "/run/wrappers" ];

	home-manager.users.badger = {
		home.stateVersion = "25.11";
		programs.opencode = {
			enable = true;
			settings = {
				permission = {
					edit = "ask";
				};
				provider.nixllm = {
					npm = "@ai-sdk/openai-compatible";
					name = "nixllm (llama.cpp)";
					options.baseURL = "https://llm.acanavan.com/v1";
					models."Qwen3.8-27B-Q4_K_M.gguf" = { name = "Qwen3 27B"; };
				};
				provider."home-nixllm" = {
					npm = "@ai-sdk/openai-compatible";
					name = "nixllm (local)";
					options.baseURL = "http://nixllm:8080/v1";
					models."Qwen3.8-27B-Q4_K_M.gguf" = { name = "Local Qwen"; };
				};
				provider."home-nixllm-ip" = {
					npm = "@ai-sdk/openai-compatible";
					name = "nixllm (local IP)";
					options.baseURL = "http://192.168.2.149:8080/v1";
					models."Qwen3.8-27B-Q4_K_M.gguf" = { name = "Local Qwen (IP)"; };
				};
				provider."home-nixllm-a" = {
					npm = "@ai-sdk/openai-compatible";
					name = "nixllm (double A / GPU 0)";
					options.baseURL = "http://nixllm:8091/v1";
					models."Qwen3.8-27B-Q4_K_M.gguf" = { name = "Local Qwen (GPU A)"; };
				};
				provider."home-nixllm-b" = {
					npm = "@ai-sdk/openai-compatible";
					name = "nixllm (double B / GPU 1)";
					options.baseURL = "http://nixllm:8092/v1";
					models."Qwen3.8-27B-Q4_K_M.gguf" = { name = "Local Qwen (GPU B)"; };
				};
				provider."home-nixllm-ip-a" = {
					npm = "@ai-sdk/openai-compatible";
					name = "nixllm (double A / GPU 0, IP)";
					options.baseURL = "http://192.168.2.149:8091/v1";
					models."Qwen3.8-27B-Q4_K_M.gguf" = { name = "Local Qwen (IP A)"; };
				};
				provider."home-nixllm-ip-b" = {
					npm = "@ai-sdk/openai-compatible";
					name = "nixllm (double B / GPU 1, IP)";
					options.baseURL = "http://192.168.2.149:8092/v1";
					models."Qwen3.8-27B-Q4_K_M.gguf" = { name = "Local Qwen (IP B)"; };
				};
			};
		};
	};
}
