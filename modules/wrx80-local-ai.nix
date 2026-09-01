{ config, pkgs, lib, ... }:
let
	# Both builds ship. A GGUF model is backend-agnostic: the same file runs
	# under ROCm, Vulkan or CPU - only the llama-server binary changes.
	llamaCppRocm   = pkgs.llama-cpp.override { rocmSupport = true; };
	llamaCppVulkan = pkgs.llama-cpp.override { vulkanSupport = true; };

	stateDir  = "/var/lib/nixllm";
	modelsDir = "${stateDir}/models";
	configF   = "${stateDir}/config";
	modelF    = "${stateDir}/model";
	mmprojF   = "${stateDir}/mmproj";
	apiKeyF   = "${stateDir}/apikey";

	# rocm-smi needs libdrm on LD_LIBRARY_PATH; wrap once and reuse for both the
	# system package and the nixllm CLI's 'gpu-monitor'.
	rocmSmiWrapped = pkgs.writeShellScriptBin "rocm-smi" ''
		export LD_LIBRARY_PATH=${pkgs.libdrm.out}/lib:$LD_LIBRARY_PATH
		exec ${pkgs.rocmPackages.rocm-smi}/bin/rocm-smi "$@"
	'';

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
	nixllmLaunch = pkgs.writeShellScript "nixllm-launch" ''
		set -euo pipefail

		NIXLLM_HOST="${defHost}"
		NIXLLM_PORT="${defPort}"
		NIXLLM_CTX="${defCtx}"
		NIXLLM_NGL="${defNgl}"
		NIXLLM_BACKEND="${defBackend}"
		NIXLLM_EXTRA_ARGS="${defExtraArgs}"

		if [ -f "${configF}" ]; then
			# shellcheck disable=SC1090
			. "${configF}"
		fi

		if [ ! -s "${modelF}" ]; then
			echo "nixllm: no model selected - run 'nixllm load <path-to-gguf>'" >&2
			exit 1
		fi
		MODEL="$(cat "${modelF}")"
		if [ ! -f "$MODEL" ]; then
			echo "nixllm: active model does not exist: $MODEL" >&2
			exit 1
		fi

		MMPROJ_ARGS=""
		if [ -s "${mmprojF}" ]; then
			MP="$(cat "${mmprojF}")"
			if [ -f "$MP" ]; then
				MMPROJ_ARGS="--mmproj $MP"
			else
				echo "nixllm: mmproj set but missing, ignoring: $MP" >&2
			fi
		fi

		APIKEY_ARGS=""
		if [ -s "${apiKeyF}" ]; then
			APIKEY_ARGS="--api-key-file ${apiKeyF}"
		fi

		case "$NIXLLM_BACKEND" in
			rocm)   SERVER="${llamaCppRocm}/bin/llama-server" ;;
			vulkan) SERVER="${llamaCppVulkan}/bin/llama-server" ;;
			*)      echo "nixllm: unknown backend: $NIXLLM_BACKEND" >&2; exit 1 ;;
		esac

		echo "nixllm: starting $NIXLLM_BACKEND server on $NIXLLM_HOST:$NIXLLM_PORT (model: $MODEL)"
		# shellcheck disable=SC2086
		exec "$SERVER" \
			--model "$MODEL" \
			--host "$NIXLLM_HOST" \
			--port "$NIXLLM_PORT" \
			--ctx-size "$NIXLLM_CTX" \
			--n-gpu-layers "$NIXLLM_NGL" \
			$MMPROJ_ARGS \
			$APIKEY_ARGS \
			$NIXLLM_EXTRA_ARGS
	'';

	nixllmCli = pkgs.writeShellApplication {
		name = "nixllm";
		runtimeInputs = (with pkgs; [ curl coreutils gnugrep gnused systemd jq ]) ++ [ rocmSmiWrapped ];
		text = ''
			MODELS_DIR="${modelsDir}"
			CONFIG_F="${configF}"
			MODEL_F="${modelF}"
			MMPROJ_F="${mmprojF}"
			API_KEY_F="${apiKeyF}"
			TOKEN_F="''${XDG_CONFIG_HOME:-$HOME/.config}/nixllm/token"

			banner() {
				# nix snowflake x3 = the GPU fans; nix-blue, plain when piped
				local g r line
				if [ -t 1 ] && [ -z "''${NO_COLOR:-}" ]; then
					g=$'\033[38;5;39m'; r=$'\033[0m'
				else
					g=""; r=""
				fi
				while IFS= read -r line; do
					printf '%s%s%s\n' "$g" "$line" "$r"
				done <<'ART'
   +--------------------------------------------------------------+
   |   \   \ //      \   \ //      \   \ //                       |
   |  ==\__\/ //   ==\__\/ //   ==\__\/ //     n i x l l m        |
   |    //   \//       //   \//       //   \//                    |
   | ==//     //==  ==//     //==  ==//     //==   llama.cpp on   |
   |  //\___//       //\___//       //\___//       this  machine  |
   | // /\  \==   // /\  \==   // /\  \==                         |
   |    \   \         \   \         \   \     run  nixllm help    |
   +--------------------------------------------------------------+
ART
			}

			hf_token() {
				# precedence: env -> 'nixllm login' file -> huggingface-cli login file
				if [ -n "''${HF_TOKEN:-}" ]; then printf '%s' "$HF_TOKEN"; return; fi
				if [ -s "$TOKEN_F" ]; then cat "$TOKEN_F"; return; fi
				if [ -s "$HOME/.cache/huggingface/token" ]; then cat "$HOME/.cache/huggingface/token"; return; fi
			}

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

			host() { cfg_get NIXLLM_HOST "${defHost}"; }
			port() { cfg_get NIXLLM_PORT "${defPort}"; }

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
					sudo systemctl start nixllm
					if wait_health; then
						echo "nixllm: up at http://$(host):$(port)  ($(health))"
					else
						echo "nixllm: service started but /health did not come up - check 'nixllm status'" >&2
						exit 1
					fi
					;;
				stop)
					sudo systemctl stop nixllm
					echo "nixllm: stopped"
					;;
				restart)
					sudo systemctl restart nixllm
					if wait_health; then
						echo "nixllm: restarted, up at http://$(host):$(port)"
					else
						echo "nixllm: restarted but /health did not come up - check 'nixllm status'" >&2
						exit 1
					fi
					;;
				status)
					systemctl --no-pager --full status nixllm || true
					echo
					echo "backend : $(cfg_get NIXLLM_BACKEND "${defBackend}")"
					echo "endpoint: http://$(host):$(port)"
					echo "ctx     : $(cfg_get NIXLLM_CTX "${defCtx}")   ngl: $(cfg_get NIXLLM_NGL "${defNgl}")"
					if [ -s "$MODEL_F" ]; then
						echo "model   : $(cat "$MODEL_F")"
					else
						echo "model   : (none - run 'nixllm load <path>')"
					fi
					if [ -s "$MMPROJ_F" ]; then
						echo "mmproj  : $(cat "$MMPROJ_F")"
					fi
					if [ -s "$API_KEY_F" ]; then
						echo "apikey  : set"
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
					[ "$#" -eq 1 ] || { echo "usage: nixllm load <path-to-gguf>" >&2; exit 1; }
					p="$(readlink -f "$1")"
					case "$p" in
						*.gguf) ;;
						*) echo "nixllm: not a .gguf file: $1" >&2; exit 1 ;;
					esac
					[ -f "$p" ] || { echo "nixllm: file not found: $p" >&2; exit 1; }
					printf '%s' "$p" > "$MODEL_F"
					echo "nixllm: active model -> $p"
					systemctl is-active --quiet nixllm && echo "nixllm: run 'nixllm restart' to apply" || true
					;;
				backend)
					[ "$#" -eq 1 ] || { echo "usage: nixllm backend <rocm|vulkan>" >&2; exit 1; }
					case "$1" in
						rocm|vulkan) cfg_set NIXLLM_BACKEND "$1"; echo "nixllm: backend -> $1" ;;
						*) echo "nixllm: backend must be 'rocm' or 'vulkan'" >&2; exit 1 ;;
					esac
					systemctl is-active --quiet nixllm && echo "nixllm: run 'nixllm restart' to apply" || true
					;;
				mmproj)
					sub="''${1:-show}"
					case "$sub" in
						show|help|-h|--help)
							if [ -s "$MMPROJ_F" ]; then
								echo "mmproj: $(cat "$MMPROJ_F")"
							else
								echo "mmproj: (none)"
							fi
							cat <<EOF
usage:
  nixllm mmproj                 show the attached vision projector
  nixllm mmproj add <path.gguf> attach a projector (restart to apply)
  nixllm mmproj clear           detach the projector (restart to apply)
EOF
							;;
						clear|none|rm)
							rm -f "$MMPROJ_F"
							echo "nixllm: mmproj cleared"
							systemctl is-active --quiet nixllm && echo "nixllm: run 'nixllm restart' to apply" || true
							;;
						add|set)
							[ "$#" -eq 2 ] || { echo "usage: nixllm mmproj add <path.gguf>" >&2; exit 1; }
							p="$(readlink -f "$2")"
							case "$p" in *.gguf) ;; *) echo "nixllm: not a .gguf file: $2" >&2; exit 1 ;; esac
							[ -f "$p" ] || { echo "nixllm: file not found: $p" >&2; exit 1; }
							printf '%s' "$p" > "$MMPROJ_F"
							echo "nixllm: mmproj -> $p"
							systemctl is-active --quiet nixllm && echo "nixllm: run 'nixllm restart' to apply" || true
							;;
						*)
							p="$(readlink -f "$sub")"
							case "$p" in *.gguf) ;; *) echo "nixllm: unknown mmproj subcommand '$sub' (try 'nixllm mmproj help')" >&2; exit 1 ;; esac
							[ -f "$p" ] || { echo "nixllm: file not found: $p" >&2; exit 1; }
							printf '%s' "$p" > "$MMPROJ_F"
							echo "nixllm: mmproj -> $p"
							systemctl is-active --quiet nixllm && echo "nixllm: run 'nixllm restart' to apply" || true
							;;
					esac
					;;
				apikey)
					sub="''${1:-show}"
					apikey_write() {
						# apikey_write VALUE
						( umask 077; printf '%s' "$1" > "$API_KEY_F" )
						chgrp wheel "$API_KEY_F" && chmod 640 "$API_KEY_F"
						echo "nixllm: api key set"
						echo "nixllm: run 'nixllm restart' to apply"
					}
					case "$sub" in
						show|"")
							if [ -s "$API_KEY_F" ]; then
								cat "$API_KEY_F"; echo
							else
								echo "apikey: (none)"
							fi
							;;
						set)
							[ "$#" -eq 2 ] || { echo "usage: nixllm apikey set <key>" >&2; exit 1; }
							[ -n "$2" ] || { echo "nixllm: empty key" >&2; exit 1; }
							apikey_write "$2"
							;;
						generate|gen)
							k="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-40)"
							apikey_write "$k"
							echo "$k"
							;;
						clear|none|rm)
							rm -f "$API_KEY_F"
							echo "nixllm: api key cleared"
							echo "nixllm: run 'nixllm restart' to apply"
							;;
						*)
							echo "nixllm: unknown apikey subcommand '$sub' (show|set <k>|generate|clear)" >&2
							exit 1
							;;
					esac
					;;
				models)
					shopt -s nullglob
					found=("$MODELS_DIR"/*.gguf)
					if [ ''${#found[@]} -eq 0 ]; then
						echo "nixllm: no models in $MODELS_DIR"
					else
						ls -lh "$MODELS_DIR"/*.gguf
					fi
					;;
				login)
					if [ "$#" -eq 1 ]; then
						tok="$1"
					else
						printf 'Hugging Face token (input hidden): ' >&2
						read -rs tok
						echo >&2
					fi
					[ -n "$tok" ] || { echo "nixllm: empty token" >&2; exit 1; }
					mkdir -p "$(dirname "$TOKEN_F")"
					( umask 077; printf '%s' "$tok" > "$TOKEN_F" )
					echo "nixllm: token saved to $TOKEN_F"
					;;
				logout)
					rm -f "$TOKEN_F"
					echo "nixllm: removed $TOKEN_F"
					;;
				pull)
					auth=()
					tok="$(hf_token)"
					[ -n "$tok" ] && auth=(-H "Authorization: Bearer $tok")
					mkdir -p "$MODELS_DIR"
					if [ "$#" -eq 1 ]; then
						url="$1"
						case "$url" in
							http://*|https://*) ;;
							*) echo "nixllm: single-arg pull needs a URL; or use 'nixllm pull <repo> <file.gguf>'" >&2; exit 1 ;;
						esac
						out="$MODELS_DIR/$(basename "''${url%%\?*}")"
					elif [ "$#" -eq 2 ]; then
						url="https://huggingface.co/$1/resolve/main/$2"
						out="$MODELS_DIR/$(basename "$2")"
					else
						echo "usage: nixllm pull <hf-url> | nixllm pull <repo> <file.gguf>" >&2
						exit 1
					fi
					echo "nixllm: downloading -> $out"
					curl -fL --progress-bar "''${auth[@]}" -o "$out" "$url"
					echo "nixllm: saved $out"
					echo "nixllm: run 'nixllm load $out' to use it"
					;;
				gpu-monitor)
					command -v rocm-smi >/dev/null || { echo "nixllm: rocm-smi unavailable" >&2; exit 1; }
					HW=""
					for h in /sys/class/drm/card*/device/hwmon/hwmon*; do
						if [ -r "$h/name" ] && [ "$(cat "$h/name")" = "amdgpu" ]; then HW="$h"; break; fi
					done
					printf '\033[?25l'
					trap 'printf "\033[?25h\n"; exit 0' INT
					while :; do
						j="$(rocm-smi --showtemp --showpower --showuse --json 2>/dev/null || true)"
						read -r edge junc mem pwr use <<EOF2
$(printf '%s' "$j" | jq -r '
  (.[] // {}) as $c |
  [ ($c["Temperature (Sensor edge) (C)"]     // "n/a"),
    ($c["Temperature (Sensor junction) (C)"] // "n/a"),
    ($c["Temperature (Sensor memory) (C)"]   // "n/a"),
    ($c["Average Graphics Package Power (W)"] // "n/a"),
    ($c["GPU use (%)"]                        // "n/a") ] | @tsv' 2>/dev/null)
EOF2
						[ -n "$edge" ] || edge="n/a"
						rpm="n/a"; fanpct="n/a"
						if [ -n "$HW" ] && [ -r "$HW/fan1_input" ]; then
							rpm="$(cat "$HW/fan1_input" 2>/dev/null || echo n/a)"
							if [ -r "$HW/pwm1" ]; then
								p="$(cat "$HW/pwm1" 2>/dev/null || echo 0)"
								case "$p" in ""|*[!0-9]*) fanpct="n/a" ;; *) fanpct="$(( p * 100 / 255 ))" ;; esac
							fi
						fi
						printf '\033[H\033[2J'
						echo "nixllm gpu-monitor   $(date '+%H:%M:%S')   (Ctrl-C to exit)"
						echo
						printf '  temp     edge %s C   junction %s C   mem %s C\n' "$edge" "$junc" "$mem"
						printf '  fan      %s rpm   (%s%% pwm)\n' "$rpm" "$fanpct"
						printf '  power    %s W\n' "$pwr"
						printf '  util     %s %%\n' "$use"
						sleep 1
					done
					;;
				help|-h|--help)
					banner
					cat <<EOF

nixllm - manage the llama.cpp server on this host

  nixllm start                 start the server (systemd) and wait for /health
  nixllm stop                  stop the server
  nixllm restart               restart (apply a new model / backend / config)
  nixllm status                service state, active model, backend, health
  nixllm gpu-monitor           live GPU temp / fan / power / util (Ctrl-C to exit)
  nixllm load <path.gguf>      select the active model
  nixllm backend <rocm|vulkan> choose the server backend (default: ${defBackend})
  nixllm mmproj [add <p>|clear] attach/detach a vision projector (mmproj gguf)
  nixllm apikey [show|set <k>|generate|clear]  require Bearer auth on the HTTP endpoint
  nixllm pull <hf-url>         download a gguf into $MODELS_DIR
  nixllm pull <repo> <file>    download huggingface.co/<repo>/resolve/main/<file>
  nixllm models                list downloaded models
  nixllm login [token]         save a Hugging Face token (prompts if omitted)
  nixllm logout                delete the saved token
  nixllm help                  this text

Config file ($CONFIG_F), KEY="VALUE" per line, overrides derivation defaults:
  NIXLLM_HOST (${defHost})  NIXLLM_PORT (${defPort})  NIXLLM_CTX (${defCtx})
  NIXLLM_NGL (${defNgl})  NIXLLM_BACKEND (${defBackend})  NIXLLM_EXTRA_ARGS
Gated 'nixllm pull' auth, in order: \$HF_TOKEN, $TOKEN_F, ~/.cache/huggingface/token.
EOF
					;;
				*)
					echo "nixllm: unknown command '$cmd' (try 'nixllm help')" >&2
					exit 1
					;;
			esac
		'';
	};
in
{
	environment.systemPackages = (with pkgs; [
		nixllmCli
		libdrm.out
		vulkan-tools   # vulkaninfo, vkcube - Vulkan backend diagnostics
	]) ++ [ rocmSmiWrapped ];

	# Mesa RADV userspace so the Vulkan backend has an ICD. Without this the
	# host has no Vulkan driver at all and 'nixllm backend vulkan' hangs.
	# Populates /run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json.
	hardware.graphics.enable = true;

	# llama-server exposes an OpenAI-compatible HTTP API + web UI on this port:
	#   GET  /health                 GET /props            GET  /
	#   POST /completion             POST /v1/chat/completions
	#   POST /v1/completions         GET  /v1/models       POST /embedding, /tokenize, ...
	# The endpoint is unauthenticated unless a key has been set with
	# 'nixllm apikey set|generate' (then 'nixllm restart'); with a key,
	# every request except /health needs 'Authorization: Bearer <key>'.
	networking.firewall.allowedTCPPorts = [ defPortInt ];

	# State dir is group-writable by wheel so 'nixllm load/backend/pull' need no sudo.
	systemd.tmpfiles.rules = [
		"d ${stateDir} 0775 llm wheel -"
		"d ${modelsDir} 0775 llm wheel -"
	];

	# Started on demand by 'nixllm start' - deliberately not in multi-user.target.
	systemd.services.nixllm = {
		description = "llama.cpp server (managed by the nixllm CLI)";
		serviceConfig = {
			ExecStart = nixllmLaunch;
			User = "llm";
			Group = "llm";
			Restart = "on-failure";
			RestartSec = 2;
			# GPU access for ROCm (/dev/kfd, /dev/dri) and Vulkan (/dev/dri).
			SupplementaryGroups = [ "video" "render" ];
			# The unit runs with a scrubbed env; pin the RADV ICD so the Vulkan
			# loader finds it regardless of default-path behaviour.
			Environment = [
				"VK_ICD_FILENAMES=/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json"
			];
		};
	};

	# mutableUsers stays true (default), so passwords set with `passwd`
	# persist across rebuilds. The account itself is declared here so a
	# clean reinstall always recreates it; set its password after install.
	users.groups.llm = {};
	users.users.llm = {
		isNormalUser = true;
		description = "llm";
		group = "llm";
		extraGroups = [ "networkmanager" "wheel" "video" "render" ];
	};
}
