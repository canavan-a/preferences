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
		NIXLLM_PARALLEL=""
		NIXLLM_REASONING="off"
		NIXLLM_SAMPLE_ARGS="--temp 0.7 --top-p 0.8 --top-k 20 --min-p 0 --presence-penalty 1.0"

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

		PARALLEL_ARGS=""
		if [ -n "$NIXLLM_PARALLEL" ]; then
			PARALLEL_ARGS="--parallel $NIXLLM_PARALLEL"
		fi

		# --jinja is required for --reasoning-budget and correct Qwen3 reasoning parsing.
		REASON_ARGS="--jinja"
		case "$NIXLLM_REASONING" in
			off|0)      REASON_ARGS="$REASON_ARGS --reasoning-budget 0" ;;
			low)        REASON_ARGS="$REASON_ARGS --reasoning-budget 512" ;;
			full|-1|"") REASON_ARGS="$REASON_ARGS --reasoning-budget -1" ;;
			*[!0-9]*)   echo "nixllm: bad NIXLLM_REASONING: $NIXLLM_REASONING (off|low|full|<int>)" >&2; exit 1 ;;
			*)          REASON_ARGS="$REASON_ARGS --reasoning-budget $NIXLLM_REASONING" ;;
		esac

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
			--metrics \
			$MMPROJ_ARGS \
			$APIKEY_ARGS \
			$PARALLEL_ARGS \
			$REASON_ARGS \
			$NIXLLM_SAMPLE_ARGS \
			$NIXLLM_EXTRA_ARGS
	'';

	nixllmCli = pkgs.writeShellApplication {
		name = "nixllm";
		runtimeInputs = (with pkgs; [ curl coreutils gnugrep gnused gawk systemd jq ]) ++ [ rocmSmiWrapped ];
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

			cfg_unset() {
				# cfg_unset KEY
				[ -f "$CONFIG_F" ] && sed -i "/^$1=/d" "$CONFIG_F"
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

			# Bytes -> "X.X" (GiB, one decimal, truncated).
			gib1() { printf '%d.%d' "$(( $1 / 1073741824 ))" "$(( $1 * 10 / 1073741824 % 10 ))"; }

			# Echo the amdgpu hwmon dir (.../cardN/device/hwmon/hwmonM), empty if none.
			find_amdgpu_hwmon() {
				for h in /sys/class/drm/card*/device/hwmon/hwmon*; do
					if [ -r "$h/name" ] && [ "$(cat "$h/name")" = "amdgpu" ]; then
						printf '%s' "$h"; return 0
					fi
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
					echo "ctx     : $(cfg_get NIXLLM_CTX "${defCtx}")   ngl: $(cfg_get NIXLLM_NGL "${defNgl}")   parallel: $(cfg_get NIXLLM_PARALLEL "auto")"
					echo "reason  : $(cfg_get NIXLLM_REASONING "off")"
					echo "sampling: $(cfg_get NIXLLM_SAMPLE_ARGS "(launch default)")"
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
				context|ctx)
					if [ "$#" -eq 0 ]; then
						echo "context: $(cfg_get NIXLLM_CTX "${defCtx}") tokens"
						exit 0
					fi
					case "$1" in ""|*[!0-9]*) echo "usage: nixllm context <n-tokens>" >&2; exit 1 ;; esac
					cfg_set NIXLLM_CTX "$1"
					echo "nixllm: context -> $1"
					systemctl is-active --quiet nixllm && echo "nixllm: run 'nixllm restart' to apply" || true
					;;
				parallel|p)
					if [ "$#" -eq 0 ]; then
						v="$(cfg_get NIXLLM_PARALLEL "")"
						echo "parallel: ''${v:-auto (llama.cpp default)}"
						exit 0
					fi
					case "$1" in
						clear|auto|none|"")
							cfg_unset NIXLLM_PARALLEL
							echo "nixllm: parallel -> auto"
							;;
						*[!0-9]*)
							echo "usage: nixllm p [<n> | clear]" >&2; exit 1
							;;
						*)
							cfg_set NIXLLM_PARALLEL "$1"
							echo "nixllm: parallel -> $1"
							;;
					esac
					systemctl is-active --quiet nixllm && echo "nixllm: run 'nixllm restart' to apply" || true
					;;
				think)
					if [ "$#" -eq 0 ]; then
						echo "reasoning: $(cfg_get NIXLLM_REASONING "off")"
						exit 0
					fi
					case "$1" in
						off|low|full) cfg_set NIXLLM_REASONING "$1" ;;
						*[!0-9]*) echo "usage: nixllm think [off|low|full|<n-tokens>]" >&2; exit 1 ;;
						*) cfg_set NIXLLM_REASONING "$1" ;;
					esac
					echo "nixllm: reasoning -> $1"
					systemctl is-active --quiet nixllm && echo "nixllm: run 'nixllm restart' to apply" || true
					;;
				preset)
					[ "$#" -eq 1 ] || { echo "usage: nixllm preset <code|think|clear>" >&2; exit 1; }
					case "$1" in
						code)
							cfg_set NIXLLM_REASONING "off"
							cfg_set NIXLLM_SAMPLE_ARGS "--temp 0.7 --top-p 0.8 --top-k 20 --min-p 0 --presence-penalty 1.0"
							echo "nixllm: preset code (reasoning off, Qwen3 non-thinking sampling)"
							;;
						think)
							cfg_set NIXLLM_REASONING "full"
							cfg_set NIXLLM_SAMPLE_ARGS "--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0"
							echo "nixllm: preset think (reasoning on, Qwen3 thinking sampling)"
							;;
						clear)
							cfg_unset NIXLLM_REASONING
							cfg_unset NIXLLM_SAMPLE_ARGS
							echo "nixllm: preset cleared (back to launch defaults)"
							;;
						*)
							echo "nixllm: unknown preset '$1' (code|think|clear)" >&2; exit 1
							;;
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
				tps)
					h="$(host)"; [ "$h" = "0.0.0.0" ] && h="127.0.0.1"
					url="http://$h:$(port)/metrics"
					mauth=(); [ -s "$API_KEY_F" ] && mauth=(-H "Authorization: Bearer $(cat "$API_KEY_F")")
					if ! curl -fsS --max-time 2 "''${mauth[@]}" "$url" >/dev/null 2>&1; then
						echo "nixllm: /metrics unreachable at $url" >&2
						echo "note   : server needs --metrics (rebuild + 'nixllm restart'); if an api key is set it must be readable at $API_KEY_F" >&2
						exit 1
					fi
					par="$(cfg_get NIXLLM_PARALLEL "auto")"
					printf '\033[?1049h\033[?25l'
					trap 'printf "\033[?25h\033[?1049l"; exit 0' INT EXIT
					while :; do
						m="$(curl -fsS --max-time 2 "''${mauth[@]}" "$url" 2>/dev/null || true)"
						read -r in_s out_s act def kv ptot dtot <<EOF3
$(printf '%s\n' "$m" | awk '
					  $1=="llamacpp:prompt_tokens_seconds"    {a=$2}
					  $1=="llamacpp:predicted_tokens_seconds"  {b=$2}
					  $1=="llamacpp:requests_processing"       {c=$2}
					  $1=="llamacpp:requests_deferred"         {d=$2}
					  $1=="llamacpp:kv_cache_usage_ratio"      {e=$2}
					  $1=="llamacpp:prompt_tokens_total"       {f=$2}
					  $1=="llamacpp:tokens_predicted_total"    {g=$2}
					  END { printf "%s %s %s %s %s %s %s\n",
					        (a==""?"0":a),(b==""?"0":b),(c==""?"0":c),(d==""?"0":d),
					        (e==""?"0":e),(f==""?"0":f),(g==""?"0":g) }')
EOF3
						kvpct="$(printf '%s' "$kv" | awk '{printf "%d", $1*100}')"
						printf '\033[H\033[2J'
						echo "nixllm tps   $(date '+%H:%M:%S')   (Ctrl-C to exit)"
						echo
						printf '  in     %8.1f tok/s\n' "$in_s"
						printf '  out    %8.1f tok/s\n' "$out_s"
						printf '  reqs   active %s / %s   queued %s\n' "$act" "$par" "$def"
						printf '  kv     %s%% used\n' "$kvpct"
						printf '  total  prompt %s   predicted %s\n' "$ptot" "$dtot"
						sleep 1
					done
					;;
				gpu-monitor)
					command -v rocm-smi >/dev/null || { echo "nixllm: rocm-smi unavailable" >&2; exit 1; }
					HW="$(find_amdgpu_hwmon || true)"
					DEV=""; [ -n "$HW" ] && DEV="''${HW%/hwmon/*}"
					mh="$(host)"; [ "$mh" = "0.0.0.0" ] && mh="127.0.0.1"
					murl="http://$mh:$(port)/metrics"
					mauth=(); [ -s "$API_KEY_F" ] && mauth=(-H "Authorization: Bearer $(cat "$API_KEY_F")")
					mpar="$(cfg_get NIXLLM_PARALLEL "auto")"
					printf '\033[?1049h\033[?25l'
					trap 'printf "\033[?25h\033[?1049l"; exit 0' INT EXIT
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
						vram="n/a"; vpct="?"
						if [ -n "$DEV" ] && [ -r "$DEV/mem_info_vram_used" ] && [ -r "$DEV/mem_info_vram_total" ]; then
							vu="$(cat "$DEV/mem_info_vram_used" 2>/dev/null || echo 0)"
							vt="$(cat "$DEV/mem_info_vram_total" 2>/dev/null || echo 0)"
							case "$vu$vt" in
								*[!0-9]*|"") ;;
								*) if [ "$vt" -gt 0 ]; then
									vram="$(gib1 "$vu") / $(gib1 "$vt")"
									vpct="$(( vu * 100 / vt ))"
								fi ;;
							esac
						fi
						tok="n/a"
						m="$(curl -fsS --max-time 1 "''${mauth[@]}" "$murl" 2>/dev/null || true)"
						if [ -n "$m" ]; then
							read -r in_s out_s act def <<EOF4
$(printf '%s\n' "$m" | awk '
  $1=="llamacpp:prompt_tokens_seconds"   {a=$2}
  $1=="llamacpp:predicted_tokens_seconds"{b=$2}
  $1=="llamacpp:requests_processing"     {c=$2}
  $1=="llamacpp:requests_deferred"       {d=$2}
  END { printf "%s %s %s %s\n", (a==""?"0":a),(b==""?"0":b),(c==""?"0":c),(d==""?"0":d) }')
EOF4
							tok="$(printf 'in %.0f/s  out %.0f/s   active %s/%s  queued %s' \
								"$in_s" "$out_s" "$act" "$mpar" "$def")"
						fi
						printf '\033[H\033[2J'
						echo "nixllm gpu-monitor   $(date '+%H:%M:%S')   (Ctrl-C to exit)"
						echo
						printf '  temp     edge %s C   junction %s C   mem %s C\n' "$edge" "$junc" "$mem"
						printf '  fan      %s rpm   (%s%% pwm)\n' "$rpm" "$fanpct"
						printf '  power    %s W\n' "$pwr"
						printf '  util     %s %%\n' "$use"
						if [ "$vram" = "n/a" ]; then
							printf '  vram     n/a\n'
						else
							printf '  vram     %s GiB   (%s%%)\n' "$vram" "$vpct"
						fi
						printf '  tokens   %s\n' "$tok"
						sleep 1
					done
					;;
				headroom)
					HW="$(find_amdgpu_hwmon || true)"
					DEV=""; [ -n "$HW" ] && DEV="''${HW%/hwmon/*}"
					if [ -z "$DEV" ] || [ ! -r "$DEV/mem_info_vram_total" ]; then
						echo "nixllm: amdgpu VRAM sysfs not found" >&2; exit 1
					fi
					vt="$(cat "$DEV/mem_info_vram_total")"
					vu="$(cat "$DEV/mem_info_vram_used")"
					tot_mib=$(( vt / 1048576 ))
					used_mib=$(( vu / 1048576 ))
					free_mib=$(( tot_mib - used_mib ))
					printf 'gpu vram   : %s MiB total   %s used   %s free\n' "$tot_mib" "$used_mib" "$free_mib"

					nctx="$(cfg_get NIXLLM_CTX "${defCtx}")"
					par=1; unified=no
					jl="$(journalctl -u nixllm -b --no-pager 2>/dev/null || true)"
					pl="$(printf '%s\n' "$jl" | grep -oE 'n_parallel = [0-9]+' | tail -n1 | grep -oE '[0-9]+$' || true)"
					[ -n "$pl" ] && par="$pl"
					printf '%s\n' "$jl" | grep -q 'kv_unified = true' && unified=yes

					if ! systemctl is-active --quiet nixllm; then
						echo "server     : not running (config: n_ctx $nctx, parallel $par)"
						echo "note       : start nixllm, then re-run for the context estimate"
						exit 0
					fi

					# GGUF weights on disk are a close proxy for the model's VRAM footprint (Q4).
					model_mib=0
					if [ -s "$MODEL_F" ]; then
						mp="$(cat "$MODEL_F")"
						[ -f "$mp" ] && model_mib=$(( $(stat -c%s "$mp") / 1048576 ))
					fi
					# Everything the server holds on the GPU minus the weights ~= KV (x parallel slots) + compute buffers.
					kv_over=$(( used_mib - model_mib ))
					[ "$kv_over" -lt 1 ] && kv_over=1

					kvnote="shared pool across $par slots"
					[ "$unified" = no ] && kvnote="$par separate slots"
					printf 'server     : n_ctx %s   parallel %s (%s)   weights ~%s MiB   KV+buffers ~%s MiB\n' \
						"$nctx" "$par" "$kvnote" "$model_mib" "$kv_over"

					# Linear extrapolation on current KV+buffer cost per token. Keep 20% of VRAM
					# free - fragmentation and the prompt/compute buffers grow with context too.
					per_k=$(( kv_over * 1000 / nctx ))
					budget=$(( free_mib * 80 / 100 ))
					if [ "$per_k" -gt 0 ]; then
						extra=$(( budget * 1000 / per_k ))
						maxctx=$(( (nctx + extra) / 4096 * 4096 ))
						printf 'cost       : ~%s MiB per 1k tokens of context\n' "$per_k"
						printf 'fits       : ~%s more tokens  ->  nixllm context %s   (keeps 20%% VRAM free)\n' "$extra" "$maxctx"
						if [ "$unified" = yes ] && [ "$par" -gt 1 ]; then
							echo "note       : KV is one shared pool, so concurrent requests split n_ctx between them;"
							echo "             run 'nixllm p 1' if one client should always get all of it"
						fi
					fi
					;;
				help|-h|--help)
					banner
					cat <<EOF

nixllm - manage the llama.cpp server on this host

  nixllm start                 start the server (systemd) and wait for /health
  nixllm stop                  stop the server
  nixllm restart               restart (apply a new model / backend / config)
  nixllm status                service state, active model, backend, health
  nixllm gpu-monitor           live GPU temp / fan / power / util / vram (Ctrl-C to exit)
  nixllm tps                   live token throughput in/out, active/queued reqs, kv use
  nixllm headroom              VRAM budget + largest context that fits
  nixllm load <path.gguf>      select the active model
  nixllm backend <rocm|vulkan> choose the server backend (default: ${defBackend})
  nixllm context [<n>]         get/set context window in tokens (restart to apply)
  nixllm p [<n>|clear]         get/set --parallel request slots (default: auto)
  nixllm think [off|low|full|<n>]  Qwen3 reasoning budget (default: off)
  nixllm preset <code|think|clear> apply a sampling + reasoning bundle
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
  NIXLLM_PARALLEL  NIXLLM_REASONING (off)  NIXLLM_SAMPLE_ARGS  (see 'preset')
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
