{ config, pkgs, lib, ... }:
let
	# Both builds ship. A GGUF model is backend-agnostic: the same file runs
	# under ROCm, Vulkan or CPU - only the llama-server binary changes.
	llamaCppRocm   = pkgs.llama-cpp.override { rocmSupport = true; };
	llamaCppVulkan = pkgs.llama-cpp.override { vulkanSupport = true; };

	stateDir  = "/var/lib/llm";
	modelsDir = "${stateDir}/models";
	configF   = "${stateDir}/config";
	modelF    = "${stateDir}/model";

	# Derivation defaults. Each is overridable by a line in ${configF}.
	defHost      = "0.0.0.0";
	defPort      = "8080";
	defPortInt   = 8080;
	defCtx       = "4096";
	defNgl       = "999";
	defBackend   = "rocm";
	defExtraArgs = "";

	# ExecStart for the systemd unit. Sources the config file over the
	# defaults, resolves the active model and execs the chosen backend.
	llmLaunch = pkgs.writeShellScript "llm-launch" ''
		set -euo pipefail

		LLM_HOST="${defHost}"
		LLM_PORT="${defPort}"
		LLM_CTX="${defCtx}"
		LLM_NGL="${defNgl}"
		LLM_BACKEND="${defBackend}"
		LLM_EXTRA_ARGS="${defExtraArgs}"

		if [ -f "${configF}" ]; then
			# shellcheck disable=SC1090
			. "${configF}"
		fi

		if [ ! -s "${modelF}" ]; then
			echo "llm: no model selected - run 'llm load <path-to-gguf>'" >&2
			exit 1
		fi
		MODEL="$(cat "${modelF}")"
		if [ ! -f "$MODEL" ]; then
			echo "llm: active model does not exist: $MODEL" >&2
			exit 1
		fi

		case "$LLM_BACKEND" in
			rocm)   SERVER="${llamaCppRocm}/bin/llama-server" ;;
			vulkan) SERVER="${llamaCppVulkan}/bin/llama-server" ;;
			*)      echo "llm: unknown backend: $LLM_BACKEND" >&2; exit 1 ;;
		esac

		echo "llm: starting $LLM_BACKEND server on $LLM_HOST:$LLM_PORT (model: $MODEL)"
		# shellcheck disable=SC2086
		exec "$SERVER" \
			--model "$MODEL" \
			--host "$LLM_HOST" \
			--port "$LLM_PORT" \
			--ctx-size "$LLM_CTX" \
			--n-gpu-layers "$LLM_NGL" \
			$LLM_EXTRA_ARGS
	'';

	llmCli = pkgs.writeShellApplication {
		name = "llm";
		runtimeInputs = with pkgs; [ curl coreutils gnugrep gnused systemd ];
		text = ''
			MODELS_DIR="${modelsDir}"
			CONFIG_F="${configF}"
			MODEL_F="${modelF}"

			cfg_get() {
				# cfg_get KEY DEFAULT
				if [ -f "$CONFIG_F" ] && grep -q "^$1=" "$CONFIG_F"; then
					grep "^$1=" "$CONFIG_F" | tail -n1 | cut -d= -f2- | sed 's/^"//; s/"$//'
				else
					printf '%s' "$2"
				fi
			}

			cfg_set() {
				# cfg_set KEY VALUE
				touch "$CONFIG_F"
				if grep -q "^$1=" "$CONFIG_F"; then
					sed -i "s|^$1=.*|$1=\"$2\"|" "$CONFIG_F"
				else
					printf '%s="%s"\n' "$1" "$2" >> "$CONFIG_F"
				fi
			}

			host() { cfg_get LLM_HOST "${defHost}"; }
			port() { cfg_get LLM_PORT "${defPort}"; }

			health() {
				h="$(host)"; [ "$h" = "0.0.0.0" ] && h="127.0.0.1"
				curl -fsS --max-time 2 "http://$h:$(port)/health" 2>/dev/null || true
			}

			wait_health() {
				for _ in $(seq 1 60); do
					if health | grep -q '"status"'; then return 0; fi
					sleep 1
				done
				return 1
			}

			cmd="''${1:-help}"
			[ "$#" -gt 0 ] && shift || true

			case "$cmd" in
				start)
					sudo systemctl start llm
					if wait_health; then
						echo "llm: up at http://$(host):$(port)  ($(health))"
					else
						echo "llm: service started but /health did not come up - check 'llm status'" >&2
						exit 1
					fi
					;;
				stop)
					sudo systemctl stop llm
					echo "llm: stopped"
					;;
				restart)
					sudo systemctl restart llm
					if wait_health; then
						echo "llm: restarted, up at http://$(host):$(port)"
					else
						echo "llm: restarted but /health did not come up - check 'llm status'" >&2
						exit 1
					fi
					;;
				status)
					systemctl --no-pager --full status llm || true
					echo
					echo "backend : $(cfg_get LLM_BACKEND "${defBackend}")"
					echo "endpoint: http://$(host):$(port)"
					echo "ctx     : $(cfg_get LLM_CTX "${defCtx}")   ngl: $(cfg_get LLM_NGL "${defNgl}")"
					if [ -s "$MODEL_F" ]; then
						echo "model   : $(cat "$MODEL_F")"
					else
						echo "model   : (none - run 'llm load <path>')"
					fi
					h="$(health)"
					if [ -n "$h" ]; then
						echo "health  : $h"
					else
						echo "health  : unreachable"
						exit 1
					fi
					;;
				load)
					[ "$#" -eq 1 ] || { echo "usage: llm load <path-to-gguf>" >&2; exit 1; }
					p="$(readlink -f "$1")"
					case "$p" in
						*.gguf) ;;
						*) echo "llm: not a .gguf file: $1" >&2; exit 1 ;;
					esac
					[ -f "$p" ] || { echo "llm: file not found: $p" >&2; exit 1; }
					printf '%s' "$p" > "$MODEL_F"
					echo "llm: active model -> $p"
					systemctl is-active --quiet llm && echo "llm: run 'llm restart' to apply" || true
					;;
				backend)
					[ "$#" -eq 1 ] || { echo "usage: llm backend <rocm|vulkan>" >&2; exit 1; }
					case "$1" in
						rocm|vulkan) cfg_set LLM_BACKEND "$1"; echo "llm: backend -> $1" ;;
						*) echo "llm: backend must be 'rocm' or 'vulkan'" >&2; exit 1 ;;
					esac
					systemctl is-active --quiet llm && echo "llm: run 'llm restart' to apply" || true
					;;
				models)
					shopt -s nullglob
					found=("$MODELS_DIR"/*.gguf)
					if [ ''${#found[@]} -eq 0 ]; then
						echo "llm: no models in $MODELS_DIR"
					else
						ls -lh "$MODELS_DIR"/*.gguf
					fi
					;;
				pull)
					auth=()
					[ -n "''${HF_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $HF_TOKEN")
					mkdir -p "$MODELS_DIR"
					if [ "$#" -eq 1 ]; then
						url="$1"
						case "$url" in
							http://*|https://*) ;;
							*) echo "llm: single-arg pull needs a URL; or use 'llm pull <repo> <file.gguf>'" >&2; exit 1 ;;
						esac
						out="$MODELS_DIR/$(basename "''${url%%\?*}")"
					elif [ "$#" -eq 2 ]; then
						url="https://huggingface.co/$1/resolve/main/$2"
						out="$MODELS_DIR/$(basename "$2")"
					else
						echo "usage: llm pull <hf-url> | llm pull <repo> <file.gguf>" >&2
						exit 1
					fi
					echo "llm: downloading -> $out"
					curl -fL --progress-bar "''${auth[@]}" -o "$out" "$url"
					echo "llm: saved $out"
					echo "llm: run 'llm load $out' to use it"
					;;
				help|-h|--help)
					cat <<EOF
llm - manage the llama.cpp server on this host

  llm start                 start the server (systemd) and wait for /health
  llm stop                  stop the server
  llm restart               restart (apply a new model / backend / config)
  llm status                service state, active model, backend, health
  llm load <path.gguf>      select the active model
  llm backend <rocm|vulkan> choose the server backend (default: ${defBackend})
  llm pull <hf-url>         download a gguf into $MODELS_DIR
  llm pull <repo> <file>    download huggingface.co/<repo>/resolve/main/<file>
  llm models                list downloaded models
  llm help                  this text

Config file ($CONFIG_F), KEY="VALUE" per line, overrides derivation defaults:
  LLM_HOST (${defHost})  LLM_PORT (${defPort})  LLM_CTX (${defCtx})
  LLM_NGL (${defNgl})  LLM_BACKEND (${defBackend})  LLM_EXTRA_ARGS
Set HF_TOKEN in the environment for gated 'llm pull' downloads.
EOF
					;;
				*)
					echo "llm: unknown command '$cmd' (try 'llm help')" >&2
					exit 1
					;;
			esac
		'';
	};
in
{
	environment.systemPackages = with pkgs; [
		llmCli
		libdrm.out
		(writeShellScriptBin "rocm-smi" ''
			export LD_LIBRARY_PATH=${libdrm.out}/lib:$LD_LIBRARY_PATH
			exec ${rocmPackages.rocm-smi}/bin/rocm-smi "$@"
		'')
	];

	# llama-server exposes an OpenAI-compatible HTTP API + web UI on this port:
	#   GET  /health                 GET /props            GET  /
	#   POST /completion             POST /v1/chat/completions
	#   POST /v1/completions         GET  /v1/models       POST /embedding, /tokenize, ...
	networking.firewall.allowedTCPPorts = [ defPortInt ];

	# State dir is group-writable by wheel so 'llm load/backend/pull' need no sudo.
	systemd.tmpfiles.rules = [
		"d ${stateDir} 0775 llm wheel -"
		"d ${modelsDir} 0775 llm wheel -"
	];

	# Started on demand by 'llm start' - deliberately not in multi-user.target.
	systemd.services.llm = {
		description = "llama.cpp server (managed by the llm CLI)";
		serviceConfig = {
			ExecStart = llmLaunch;
			User = "llm";
			Group = "llm";
			Restart = "on-failure";
			RestartSec = 2;
			# GPU access for ROCm (/dev/kfd, /dev/dri) and Vulkan (/dev/dri).
			SupplementaryGroups = [ "video" "render" ];
		};
	};

	# mutableUsers stays true (default), so passwords set with `passwd`
	# persist across rebuilds. The account itself is declared here so a
	# clean reinstall always recreates it; set its password after install.
	users.users.llm = {
		isNormalUser = true;
		description = "llm";
		extraGroups = [ "networkmanager" "wheel" "video" "render" ];
	};
}
