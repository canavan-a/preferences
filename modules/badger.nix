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
	};

	home-manager.users.badger = {
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

	# This host's Wi-Fi network hands out IPv6 ULA addresses with no default
	# route (IP6.GATEWAY is empty, no ::/0 route) - likely internal mesh
	# backhaul addressing, not real IPv6 internet access. cloudflared's QUIC
	# transport still tries IPv6 as part of its dual-stack dial and fails
	# with "sendmsg: operation not permitted" instead of falling back
	# cleanly, so force it to IPv4 only. Scoped to this host (not
	# cloudflare/cf.nix) since other hosts' tunnels work fine as-is.
	#
	# This host also runs Mullvad, which routes all traffic through its
	# tunnel and severs cloudflared's connection to Cloudflare's edge when
	# connected. mullvad-exclude uses Mullvad's split-tunneling support
	# (cgroup net_cls) to route cloudflared's traffic outside the Mullvad
	# tunnel, so both can run at once.
	systemd.services.cloudflared-tunnel = {
		after = [ "mullvad-daemon.service" ];
		wants = [ "mullvad-daemon.service" ];
		serviceConfig.ExecStart = lib.mkForce (
			pkgs.writeShellScript "cloudflared-tunnel-run-badger" ''
				set -euo pipefail
				token="$(cat /etc/cloudflared/token)"
				exec ${pkgs.mullvad}/bin/mullvad-exclude ${pkgs.cloudflared}/bin/cloudflared tunnel --edge-ip-version 4 run --token "$token"
			''
		);
	};
}
