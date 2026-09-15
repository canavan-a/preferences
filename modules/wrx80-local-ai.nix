{ config, pkgs, lib, ... }:
let
	# Both builds ship. A GGUF model is backend-agnostic: the same file runs
	# under ROCm, Vulkan or CPU - only the llama-server binary changes.
	llamaCppRocm   = pkgs.llama-cpp.override { rocmSupport = true; };
	llamaCppVulkan = pkgs.llama-cpp.override { vulkanSupport = true; };

	stateDir     = "/var/lib/nixllm";
	modelsDir    = "${stateDir}/models";
	configF      = "${stateDir}/config";
	modelF       = "${stateDir}/model";
	mmprojF      = "${stateDir}/mmproj";
	apiKeyF      = "${stateDir}/apikey";
	doubleModelF = "${stateDir}/double-model";

	# Super Badger Station Standard API adapter: replaces the old plain GPU
	# JSON dump on :9999 with one endpoint that fronts both the GPU data and
	# each running llama-server's /metrics, speaking the spec super-badger's
	# server polls: {"<station>": {"<key>": <num>}}.
	badgerStationMapF = "${stateDir}/badger-stations";
	badgerApiKeyF     = "${stateDir}/badger-apikey";
	badgerPort        = "9999";
	badgerPortInt     = 9999;

	# nixllm double: two full model copies, one pinned per GPU, fronted by an
	# nginx ip_hash proxy for session-sticky routing. Backends are
	# localhost-only; only doublePort is exposed.
	doublePort     = "8090";
	doublePortInt  = 8090;
	doublePortA    = "8091";
	doublePortB    = "8092";
	doublePortAInt = 8091;
	doublePortBInt = 8092;

	# rocm-smi needs libdrm on LD_LIBRARY_PATH; wrap once and reuse for both the
	# system package and the nixllm CLI's 'gpu-monitor'.
	rocmSmiWrapped = pkgs.writeShellScriptBin "rocm-smi" ''
		export LD_LIBRARY_PATH=${pkgs.libdrm.out}/lib:$LD_LIBRARY_PATH
		exec ${pkgs.rocmPackages.rocm-smi}/bin/rocm-smi "$@"
	'';

	# Same per-GPU data 'nixllm gpu-monitor' displays (temp/fan/power/util/vram),
	# gathered the same way (rocm-smi --json + sysfs), but as one JSON document
	# instead of a live TUI. Backs the :9999 HTTP endpoint below.
	gpuMonitorJson = pkgs.writeShellScript "nixllm-gpu-monitor-json" ''
		set -euo pipefail
		export PATH=${lib.makeBinPath [ pkgs.jq pkgs.gnugrep pkgs.gnused pkgs.coreutils rocmSmiWrapped ]}

		j="$(rocm-smi --showtemp --showpower --showuse --showbus --json 2>/dev/null || echo '{}')"

		for d in /sys/class/drm/card*/device; do
			[ -r "$d/uevent" ] || continue
			grep -q '^DRIVER=amdgpu$' "$d/uevent" || continue
			cn="$(basename "$(dirname "$d")")"
			pci="$(sed -n 's/^PCI_SLOT_NAME=//p' "$d/uevent")"
			hw="-"
			for h in "$d"/hwmon/hwmon*; do
				[ -r "$h/name" ] && [ "$(cat "$h/name")" = "amdgpu" ] && { hw="$h"; break; }
			done

			key="$(printf '%s' "$j" | jq -r --arg p "$pci" '
			  to_entries[] | select((.value["PCI Bus"] // "" | ascii_downcase) == ($p | ascii_downcase)) | .key' 2>/dev/null | head -n1 || true)"
			[ -n "$key" ] || key="$cn"

			rpm="null"
			if [ "$hw" != "-" ] && [ -r "$hw/fan1_input" ]; then
				rv="$(cat "$hw/fan1_input" 2>/dev/null || true)"
				case "$rv" in ""|*[!0-9]*) ;; *) rpm="$rv" ;; esac
			fi
			fanpct="null"
			if [ "$hw" != "-" ] && [ -r "$hw/pwm1" ]; then
				p="$(cat "$hw/pwm1" 2>/dev/null || true)"
				case "$p" in ""|*[!0-9]*) ;; *) fanpct="$(( p * 100 / 255 ))" ;; esac
			fi

			vram_used="null"
			vram_total="null"
			if [ -r "$d/mem_info_vram_used" ] && [ -r "$d/mem_info_vram_total" ]; then
				vu="$(cat "$d/mem_info_vram_used" 2>/dev/null || true)"
				vt="$(cat "$d/mem_info_vram_total" 2>/dev/null || true)"
				case "$vu" in ""|*[!0-9]*) ;; *) vram_used="$vu" ;; esac
				case "$vt" in ""|*[!0-9]*) ;; *) vram_total="$vt" ;; esac
			fi

			jq -cn \
				--argjson data "$j" \
				--arg key "$key" \
				--arg card "$cn" \
				--arg pci "$pci" \
				--argjson fan_rpm "$rpm" \
				--argjson fan_pct "$fanpct" \
				--argjson vram_used_bytes "$vram_used" \
				--argjson vram_total_bytes "$vram_total" \
				'($data[$key] // {}) as $c |
				 {
				   card: $card,
				   pci: $pci,
				   temp_edge_c: ($c["Temperature (Sensor edge) (C)"] // null),
				   temp_junction_c: ($c["Temperature (Sensor junction) (C)"] // null),
				   temp_memory_c: ($c["Temperature (Sensor memory) (C)"] // null),
				   power_w: ($c["Average Graphics Package Power (W)"] // null),
				   util_pct: ($c["GPU use (%)"] // null),
				   fan_rpm: $fan_rpm,
				   fan_pct: $fan_pct,
				   vram_used_bytes: $vram_used_bytes,
				   vram_total_bytes: $vram_total_bytes
				 }'
		done | jq -s '{generated_at: (now | todate), gpus: .}'
	'';

	# Super Badger Station Standard API body: {"<station>": {"gpu_temp_c":..,
	# "gpu_util_pct":.., "tokens_per_sec":..}, ...}. Stations are read from
	# ${badgerStationMapF}, one "NAME=PORT[:GPUINDEX]" per line (managed by
	# 'nixllm badger map ...'); GPUINDEX picks which entry of the GPU JSON's
	# "gpus" array to attribute to that station (defaults to gpus[0] on a
	# single-GPU box, or when the station's own GPU isn't known).
	badgerJson = pkgs.writeShellScript "nixllm-badger-json" ''
		set -euo pipefail
		export PATH=${lib.makeBinPath [ pkgs.jq pkgs.gnugrep pkgs.gnused pkgs.coreutils pkgs.curl pkgs.gawk ]}

		gpus_json="$(${gpuMonitorJson})"
		mauth=()
		[ -s "${apiKeyF}" ] && mauth=(-H "Authorization: Bearer $(cat "${apiKeyF}")")

		out="{}"
		if [ -s "${badgerStationMapF}" ]; then
			while IFS= read -r line; do
				[ -z "$line" ] && continue
				case "$line" in \#*) continue ;; esac
				name="''${line%%=*}"
				rest="''${line#*=}"
				port="''${rest%%:*}"
				gidx=""
				case "$rest" in *:*) gidx="''${rest##*:}" ;; esac

				tps="0"
				m="$(curl -fsS --max-time 2 "''${mauth[@]}" "http://127.0.0.1:$port/metrics" 2>/dev/null || true)"
				if [ -n "$m" ]; then
					v="$(printf '%s\n' "$m" | awk '$1=="llamacpp:predicted_tokens_seconds"{print $2}')"
					[ -n "$v" ] && tps="$v"
				fi

				if [ -n "$gidx" ]; then
					gpu="$(printf '%s' "$gpus_json" | jq -c --argjson i "$gidx" '.gpus[$i] // {}')"
				else
					gpu="$(printf '%s' "$gpus_json" | jq -c '.gpus[0] // {}')"
				fi

				entry="$(jq -cn --argjson gpu "$gpu" --arg tps "$tps" \
					'{gpu_temp_c: ($gpu.temp_edge_c // null), gpu_util_pct: ($gpu.util_pct // null), tokens_per_sec: ($tps | tonumber)}')"
				out="$(printf '%s' "$out" | jq -c --arg name "$name" --argjson entry "$entry" '. + {($name): $entry}')"
			done < "${badgerStationMapF}"
		fi
		printf '%s' "$out"
	'';

	# Same drain-then-respond pattern as gpuMonitorHttp, but checks an optional
	# Bearer key (${badgerApiKeyF}) first since this aggregates data across
	# every configured station rather than exposing one box-wide GPU dump.
	badgerHttp = pkgs.writeShellScript "nixllm-badger-http" ''
		set -euo pipefail
		provided=""
		while IFS= read -r -t 5 line; do
			line="''${line%$'\r'}"
			[ -z "$line" ] && break
			case "$line" in
				[Aa]uthorization:*) provided="''${line#*: }"; provided="''${provided%$'\r'}" ;;
			esac
		done
		if [ -s "${badgerApiKeyF}" ]; then
			expected="Bearer $(cat "${badgerApiKeyF}")"
			if [ "$provided" != "$expected" ]; then
				printf 'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
				exit 0
			fi
		fi
		body="$(${badgerJson})"
		len=''${#body}
		printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$len" "$body"
	'';

	# Derivation defaults. Each is overridable by a line in ${configF}.
	defHost      = "0.0.0.0";
	defPort      = "8080";
	defPortInt   = 8080;
	defCtx       = "4096";
	defNgl       = "999";
	defBackend   = "rocm";
	defFlashAttn = "auto";
	defExtraArgs = "";

	# ExecStart for the systemd unit(s). Sources the config file over the
	# defaults, resolves the active model and execs the chosen backend.
	# port/modelFile let the same generator serve the single-instance
	# "nixllm" service and the two "nixllm double" instances; gpuIndex, when
	# set, pins the process to one GPU via ROCR/HIP_VISIBLE_DEVICES so a
	# double pair can each own a distinct 7900XTX.
	mkNixllmLaunch = { port, modelFile ? modelF, gpuIndex ? null }: pkgs.writeShellScript "nixllm-launch" ''
		set -euo pipefail

		NIXLLM_HOST="${defHost}"
		NIXLLM_PORT="${port}"
		NIXLLM_CTX="${defCtx}"
		NIXLLM_NGL="${defNgl}"
		NIXLLM_BACKEND="${defBackend}"
		NIXLLM_FLASH_ATTN="${defFlashAttn}"
		NIXLLM_EXTRA_ARGS="${defExtraArgs}"
		NIXLLM_PARALLEL=""
		NIXLLM_REASONING="off"
		NIXLLM_SAMPLE_ARGS="--temp 0.7 --top-p 0.8 --top-k 20 --min-p 0 --presence-penalty 1.0"
		NIXLLM_GPU_ORDER=""

		if [ -f "${configF}" ]; then
			# shellcheck disable=SC1090
			. "${configF}"
		fi

		DEVICE_ARGS=""
		${if gpuIndex != null then ''
		# --device/--split-mode is backend-agnostic (unlike ROCR/HIP_VISIBLE_DEVICES,
		# which only the ROCm backend honours - the Vulkan backend ignores them
		# and silently layer-splits across every visible GPU instead of pinning).
		case "$NIXLLM_BACKEND" in
			rocm)   DEVICE_ARGS="--device ROCm${toString gpuIndex} --split-mode none" ;;
			vulkan) DEVICE_ARGS="--device Vulkan${toString gpuIndex} --split-mode none" ;;
		esac
		'' else ''
		# layer-split order across GPUs; "nixllm swap" flips this so the
		# other card is enumerated first (gets more/fewer layers as needed).
		# ROCm-only: the Vulkan backend doesn't read these env vars.
		if [ -n "$NIXLLM_GPU_ORDER" ] && [ "$NIXLLM_BACKEND" = "rocm" ]; then
			export ROCR_VISIBLE_DEVICES="$NIXLLM_GPU_ORDER"
			export HIP_VISIBLE_DEVICES="$NIXLLM_GPU_ORDER"
		fi
		''}

		if [ ! -s "${modelFile}" ]; then
			echo "nixllm: no model selected - run 'nixllm load <path-to-gguf>'" >&2
			exit 1
		fi
		MODEL="$(cat "${modelFile}")"
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

		case "$NIXLLM_FLASH_ATTN" in
			on|1)     FA_ARGS="--flash-attn on" ;;
			off|0)    FA_ARGS="--flash-attn off" ;;
			auto|"")  FA_ARGS="--flash-attn auto" ;;
			*)        echo "nixllm: bad NIXLLM_FLASH_ATTN: $NIXLLM_FLASH_ATTN (on|off|auto)" >&2; exit 1 ;;
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
			$DEVICE_ARGS \
			$FA_ARGS \
			$MMPROJ_ARGS \
			$APIKEY_ARGS \
			$PARALLEL_ARGS \
			$REASON_ARGS \
			$NIXLLM_SAMPLE_ARGS \
			$NIXLLM_EXTRA_ARGS
	'';

	nixllmLaunch      = mkNixllmLaunch { port = defPort; };
	nixllmDoubleLaunchA = mkNixllmLaunch { port = doublePortA; modelFile = doubleModelF; gpuIndex = 0; };
	nixllmDoubleLaunchB = mkNixllmLaunch { port = doublePortB; modelFile = doubleModelF; gpuIndex = 1; };

	# nixllm single: GPU-pinned launch on the main port (defPort), no nginx -
	# a drop-in replacement for the plain "nixllm" service that just pins one
	# GPU. Only one of {nixllm, nixllm-single-a, nixllm-single-b} ever runs at
	# a time, since they all share defPort.
	nixllmSingleLaunchA = mkNixllmLaunch { port = defPort; gpuIndex = 0; };
	nixllmSingleLaunchB = mkNixllmLaunch { port = defPort; gpuIndex = 1; };

	nixllmCli = pkgs.writeShellApplication {
		name = "nixllm";
		runtimeInputs = (with pkgs; [ curl coreutils gnugrep gnused gawk systemd jq newt ]) ++ [ rocmSmiWrapped ];
		text = ''
			MODELS_DIR="${modelsDir}"
			CONFIG_F="${configF}"
			MODEL_F="${modelF}"
			MMPROJ_F="${mmprojF}"
			API_KEY_F="${apiKeyF}"
			DOUBLE_MODEL_F="${doubleModelF}"
			DOUBLE_PORT="${doublePort}"
			DOUBLE_PORT_A="${doublePortA}"
			DOUBLE_PORT_B="${doublePortB}"
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
   +--------------------------------------------------+
   |         _      _ _                               |
   |   _ __ (_)_  _| | |_ __ ___                      |
   |  | '_ \| \ \/ / | | '_ ` _ \                     |
   |  | | | | |>  <| | | | | | | |                    |
   |  |_| |_|_/_/\_\_|_|_| |_| |_|                    |
   |                                                  |
   |  llama.cpp server on this machine                |
   |  run  'nixllm help'  for commands                |
   +--------------------------------------------------+
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

			# health/wait_health on an arbitrary localhost port (used by double instances).
			health_on() {
				curl -fsS --max-time 2 "http://127.0.0.1:$1/health" 2>/dev/null || true
			}

			wait_health_on() {
				for _ in $(seq 1 60); do
					if health_on "$1" | grep -q '"status"'; then return 0; fi
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

			# One line per amdgpu card: "cardN <pci-addr> <hwmon-dir|-> <device-dir>".
			# Lets gpu-monitor report every GPU in the box, not just the first card.
			list_amdgpu_gpus() {
				for d in /sys/class/drm/card*/device; do
					[ -r "$d/uevent" ] || continue
					grep -q '^DRIVER=amdgpu$' "$d/uevent" || continue
					cn="$(basename "$(dirname "$d")")"
					pci="$(sed -n 's/^PCI_SLOT_NAME=//p' "$d/uevent")"
					hw="-"
					for h in "$d"/hwmon/hwmon*; do
						[ -r "$h/name" ] && [ "$(cat "$h/name")" = "amdgpu" ] && { hw="$h"; break; }
					done
					printf '%s %s %s %s\n' "$cn" "''${pci:--}" "$hw" "$d"
				done
			}

			cmd="''${1:-help}"
			[ "$#" -gt 0 ] && shift || true

			case "$cmd" in
				start)
					if systemctl is-active --quiet nixllm-double-a || systemctl is-active --quiet nixllm-double-b; then
						echo "nixllm: stopping double (GPUs must not be shared with the single-instance service)"
						sudo systemctl stop nixllm-double-a nixllm-double-b nginx 2>/dev/null || true
					fi
					if systemctl is-active --quiet nixllm-single-a || systemctl is-active --quiet nixllm-single-b; then
						echo "nixllm: stopping single (shares the main port with the single-instance service)"
						sudo systemctl stop nixllm-single-a nixllm-single-b 2>/dev/null || true
					fi
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
					if systemctl is-active --quiet nixllm-double-a || systemctl is-active --quiet nixllm-double-b; then
						echo "nixllm: stopping double (GPUs must not be shared with the single-instance service)"
						sudo systemctl stop nixllm-double-a nixllm-double-b nginx 2>/dev/null || true
					fi
					if systemctl is-active --quiet nixllm-single-a || systemctl is-active --quiet nixllm-single-b; then
						echo "nixllm: stopping single (shares the main port with the single-instance service)"
						sudo systemctl stop nixllm-single-a nixllm-single-b 2>/dev/null || true
					fi
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
					echo "flash   : $(cfg_get NIXLLM_FLASH_ATTN "${defFlashAttn}")"
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
				swap)
					cur="$(cfg_get NIXLLM_GPU_ORDER "")"
					if [ "$cur" = "1,0" ]; then
						cfg_unset NIXLLM_GPU_ORDER
						echo "nixllm: gpu order -> 0,1 (default enumeration)"
					else
						cfg_set NIXLLM_GPU_ORDER "1,0"
						echo "nixllm: gpu order -> 1,0 (swapped)"
					fi
					echo "nixllm: this only affects the single-instance layer-split ('nixllm double' pins GPUs directly)"
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
				fa|flash)
					if [ "$#" -eq 0 ]; then
						echo "flash-attn: $(cfg_get NIXLLM_FLASH_ATTN "${defFlashAttn}")"
						exit 0
					fi
					case "$1" in
						on|off|auto) cfg_set NIXLLM_FLASH_ATTN "$1"; echo "nixllm: flash-attn -> $1" ;;
						*) echo "usage: nixllm fa [on|off|auto]" >&2; exit 1 ;;
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
				badger)
					sub="''${1:-map}"
					[ "$#" -gt 0 ] && shift || true
					STATION_MAP_F="${badgerStationMapF}"
					BADGER_KEY_F="${badgerApiKeyF}"
					case "$sub" in
						map)
							msub="''${1:-show}"
							case "$msub" in
								show|"")
									if [ -s "$STATION_MAP_F" ]; then
										cat "$STATION_MAP_F"
									else
										echo "badger: no stations mapped"
									fi
									;;
								set)
									[ "$#" -eq 3 ] || { echo "usage: nixllm badger map set <name> <port>[:<gpu-index>]" >&2; exit 1; }
									name="$2"; spec="$3"
									touch "$STATION_MAP_F"
									sed -i "/^$name=/d" "$STATION_MAP_F"
									printf '%s=%s\n' "$name" "$spec" >> "$STATION_MAP_F"
									echo "nixllm: badger station '$name' -> $spec"
									;;
								clear|rm)
									[ "$#" -eq 2 ] || { echo "usage: nixllm badger map clear <name>" >&2; exit 1; }
									[ -f "$STATION_MAP_F" ] && sed -i "/^$2=/d" "$STATION_MAP_F"
									echo "nixllm: badger station '$2' removed"
									;;
								*)
									echo "nixllm: unknown badger map subcommand '$msub' (show|set <name> <port>[:<gpu-index>]|clear <name>)" >&2
									exit 1
									;;
							esac
							;;
						apikey)
							asub="''${1:-show}"
							case "$asub" in
								show|"")
									if [ -s "$BADGER_KEY_F" ]; then cat "$BADGER_KEY_F"; echo; else echo "badger apikey: (none)"; fi
									;;
								set)
									[ "$#" -eq 2 ] || { echo "usage: nixllm badger apikey set <key>" >&2; exit 1; }
									( umask 077; printf '%s' "$2" > "$BADGER_KEY_F" )
									chgrp wheel "$BADGER_KEY_F" && chmod 640 "$BADGER_KEY_F"
									echo "nixllm: badger apikey set"
									;;
								generate|gen)
									k="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-40)"
									( umask 077; printf '%s' "$k" > "$BADGER_KEY_F" )
									chgrp wheel "$BADGER_KEY_F" && chmod 640 "$BADGER_KEY_F"
									echo "$k"
									;;
								clear|none|rm)
									rm -f "$BADGER_KEY_F"
									echo "nixllm: badger apikey cleared"
									;;
								*)
									echo "nixllm: unknown badger apikey subcommand '$asub' (show|set <k>|generate|clear)" >&2
									exit 1
									;;
							esac
							;;
						*)
							echo "nixllm: unknown badger subcommand '$sub' (map|apikey)" >&2
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
					mh="$(host)"; [ "$mh" = "0.0.0.0" ] && mh="127.0.0.1"
					murl="http://$mh:$(port)/metrics"
					mauth=(); [ -s "$API_KEY_F" ] && mauth=(-H "Authorization: Bearer $(cat "$API_KEY_F")")
					mpar="$(cfg_get NIXLLM_PARALLEL "auto")"
					GPUS="$(list_amdgpu_gpus)"
					[ -n "$GPUS" ] || { echo "nixllm: no amdgpu cards found" >&2; exit 1; }
					printf '\033[?1049h\033[?25l'
					trap 'printf "\033[?25h\033[?1049l"; exit 0' INT EXIT
					while :; do
						j="$(rocm-smi --showtemp --showpower --showuse --showbus --json 2>/dev/null || true)"
						printf '\033[H\033[2J'
						echo "nixllm gpu-monitor   $(date '+%H:%M:%S')   (Ctrl-C to exit)"
						while read -r cn pci hw dev; do
							[ -n "$cn" ] || continue
							# Match sysfs card -> rocm-smi entry by PCI bus (json key order is not sysfs order).
							key="$(printf '%s' "$j" | jq -r --arg p "$pci" '
							  to_entries[] | select((.value["PCI Bus"] // "" | ascii_downcase) == ($p | ascii_downcase)) | .key' 2>/dev/null | head -n1 || true)"
							[ -n "$key" ] || key="$cn"
							read -r edge junc mem pwr use <<EOF2
$(printf '%s' "$j" | jq -r --arg k "$key" '
  (.[$k] // {}) as $c |
  [ ($c["Temperature (Sensor edge) (C)"]     // "n/a"),
    ($c["Temperature (Sensor junction) (C)"] // "n/a"),
    ($c["Temperature (Sensor memory) (C)"]   // "n/a"),
    ($c["Average Graphics Package Power (W)"] // "n/a"),
    ($c["GPU use (%)"]                        // "n/a") ] | @tsv' 2>/dev/null)
EOF2
							[ -n "$edge" ] || edge="n/a"
							rpm="n/a"; fanpct="n/a"
							if [ "$hw" != "-" ] && [ -r "$hw/fan1_input" ]; then
								rpm="$(cat "$hw/fan1_input" 2>/dev/null || echo n/a)"
								if [ -r "$hw/pwm1" ]; then
									p="$(cat "$hw/pwm1" 2>/dev/null || echo 0)"
									case "$p" in ""|*[!0-9]*) fanpct="n/a" ;; *) fanpct="$(( p * 100 / 255 ))" ;; esac
								fi
							fi
							vram="n/a"; vpct="?"
							if [ -r "$dev/mem_info_vram_used" ] && [ -r "$dev/mem_info_vram_total" ]; then
								vu="$(cat "$dev/mem_info_vram_used" 2>/dev/null || echo 0)"
								vt="$(cat "$dev/mem_info_vram_total" 2>/dev/null || echo 0)"
								case "$vu$vt" in
									*[!0-9]*|"") ;;
									*) if [ "$vt" -gt 0 ]; then
										vram="$(gib1 "$vu") / $(gib1 "$vt")"
										vpct="$(( vu * 100 / vt ))"
									fi ;;
								esac
							fi
							echo
							printf '  %s  %s\n' "$cn" "$pci"
							printf '    temp   edge %s C   junction %s C   mem %s C\n' "$edge" "$junc" "$mem"
							printf '    fan    %s rpm   (%s%% pwm)\n' "$rpm" "$fanpct"
							printf '    power  %s W\n' "$pwr"
							printf '    util   %s %%\n' "$use"
							if [ "$vram" = "n/a" ]; then
								printf '    vram   n/a\n'
							else
								printf '    vram   %s GiB   (%s%%)\n' "$vram" "$vpct"
							fi
						done <<EOF3
$GPUS
EOF3
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
						echo
						printf '  server   %s\n' "$tok"
						sleep 1
					done
					;;
				double)
					sub="''${1:-}"
					[ "$#" -gt 0 ] && shift || true
					case "$sub" in
						stop)
							sudo systemctl stop nixllm-double-a nixllm-double-b nginx 2>/dev/null || true
							echo "nixllm: double stopped"
							;;
						status)
							systemctl --no-pager --full status nixllm-double-a nixllm-double-b nginx || true
							echo
							echo "gpu-a (port $DOUBLE_PORT_A): $(health_on "$DOUBLE_PORT_A")"
							echo "gpu-b (port $DOUBLE_PORT_B): $(health_on "$DOUBLE_PORT_B")"
							;;
						""|start)
							shopt -s nullglob
							found=("$MODELS_DIR"/*.gguf)
							if [ ''${#found[@]} -eq 0 ]; then
								echo "nixllm: no models in $MODELS_DIR - run 'nixllm pull' first" >&2
								exit 1
							fi
							args=()
							for f in "''${found[@]}"; do
								args+=("$f" "$(basename "$f") ($(du -h "$f" | cut -f1))")
							done
							model="$(whiptail --title "nixllm double" --menu \
								"Select a model to run on BOTH GPUs (duplicate mode)" 20 78 10 \
								"''${args[@]}" 3>&1 1>&2 2>&3)" || { echo "nixllm: cancelled"; exit 0; }
							clear
							printf '%s' "$model" > "$DOUBLE_MODEL_F"
							echo "nixllm: double model -> $model"
							if systemctl is-active --quiet nixllm; then
								echo "nixllm: stopping single-instance nixllm service (GPUs must not be shared with double)"
								sudo systemctl stop nixllm
							fi
							if systemctl is-active --quiet nixllm-single-a || systemctl is-active --quiet nixllm-single-b; then
								echo "nixllm: stopping single (GPUs must not be shared with double)"
								sudo systemctl stop nixllm-single-a nixllm-single-b 2>/dev/null || true
							fi
							echo "nixllm: starting nixllm-double-a, nixllm-double-b, nginx ..."
							sudo systemctl restart nixllm-double-a nixllm-double-b
							sudo systemctl restart nginx
							if wait_health_on "$DOUBLE_PORT_A" && wait_health_on "$DOUBLE_PORT_B"; then
								echo "nixllm: double up"
								echo "nixllm:   gpu-a -> http://0.0.0.0:$DOUBLE_PORT_A  (point one client here)"
								echo "nixllm:   gpu-b -> http://0.0.0.0:$DOUBLE_PORT_B  (point the other client here)"
								echo "nixllm:   auto ip_hash proxy also available at http://0.0.0.0:$DOUBLE_PORT"
							else
								echo "nixllm: double started but a /health check did not come up - check 'nixllm double status'" >&2
								exit 1
							fi

							command -v rocm-smi >/dev/null || { echo "nixllm: rocm-smi unavailable" >&2; exit 1; }
							GPUS="$(list_amdgpu_gpus)"
							[ -n "$GPUS" ] || { echo "nixllm: no amdgpu cards found" >&2; exit 1; }
							mauth=(); [ -s "$API_KEY_F" ] && mauth=(-H "Authorization: Bearer $(cat "$API_KEY_F")")
							LOG="/var/log/nginx/nixllm-double.log"
							start_off=0
							[ -r "$LOG" ] && start_off="$(stat -c%s "$LOG" 2>/dev/null || echo 0)"

							cleanup() {
								printf '\033[?25h\033[?1049l'
								echo "nixllm: stopping double ..."
								sudo systemctl stop nixllm-double-a nixllm-double-b nginx 2>/dev/null || true
								exit 0
							}
							printf '\033[?1049h\033[?25l'
							trap cleanup INT TERM EXIT
							while :; do
								j="$(rocm-smi --showtemp --showpower --showuse --showbus --json 2>/dev/null || true)"
								printf '\033[H\033[2J'
								echo "nixllm double   $(date '+%H:%M:%S')   (Ctrl-C to stop and exit)"
								echo "model: $(cat "$DOUBLE_MODEL_F" 2>/dev/null || echo -)"
								i=0
								while read -r cn pci hw dev; do
									[ -n "$cn" ] || continue
									label="gpu $i"
									key="$(printf '%s' "$j" | jq -r --arg p "$pci" '
									  to_entries[] | select((.value["PCI Bus"] // "" | ascii_downcase) == ($p | ascii_downcase)) | .key' 2>/dev/null | head -n1 || true)"
									[ -n "$key" ] || key="$cn"
									read -r edge pwr use <<EOF2
$(printf '%s' "$j" | jq -r --arg k "$key" '
  (.[$k] // {}) as $c |
  [ ($c["Temperature (Sensor edge) (C)"]      // "n/a"),
    ($c["Average Graphics Package Power (W)"] // "n/a"),
    ($c["GPU use (%)"]                        // "n/a") ] | @tsv' 2>/dev/null)
EOF2
									[ -n "$edge" ] || edge="n/a"
									vram="n/a"
									if [ -r "$dev/mem_info_vram_used" ] && [ -r "$dev/mem_info_vram_total" ]; then
										vu="$(cat "$dev/mem_info_vram_used" 2>/dev/null || echo 0)"
										vt="$(cat "$dev/mem_info_vram_total" 2>/dev/null || echo 0)"
										case "$vu$vt" in
											*[!0-9]*|"") ;;
											*) [ "$vt" -gt 0 ] && vram="$(gib1 "$vu") / $(gib1 "$vt") GiB" ;;
										esac
									fi
									echo
									printf '  %s (%s, %s)\n' "$label" "$cn" "$pci"
									printf '    temp %s C   power %s W   util %s %%   vram %s\n' "$edge" "$pwr" "$use" "$vram"
									i=$(( i + 1 ))
								done <<EOF3
$GPUS
EOF3
								echo
								for lbl in "A:$DOUBLE_PORT_A" "B:$DOUBLE_PORT_B"; do
									name="''${lbl%%:*}"; p="''${lbl##*:}"
									m="$(curl -fsS --max-time 3 "''${mauth[@]}" "http://127.0.0.1:$p/metrics" 2>/dev/null || true)"
									if [ -n "$m" ]; then
										read -r in_s out_s act <<EOF4
$(printf '%s\n' "$m" | awk '
  $1=="llamacpp:prompt_tokens_seconds"   {a=$2}
  $1=="llamacpp:predicted_tokens_seconds"{b=$2}
  $1=="llamacpp:requests_processing"     {c=$2}
  END { printf "%s %s %s\n", (a==""?"0":a),(b==""?"0":b),(c==""?"0":c) }')
EOF4
										printf '  instance %s (:%s)  in %.0f/s  out %.0f/s  active %s\n' "$name" "$p" "$in_s" "$out_s" "$act"
									else
										printf '  instance %s (:%s)  unreachable\n' "$name" "$p"
									fi
								done
								if [ -r "$LOG" ]; then
									cnt_a="$(tail -c "+$(( start_off + 1 ))" "$LOG" 2>/dev/null | grep -c ":$DOUBLE_PORT_A" || true)"
									cnt_b="$(tail -c "+$(( start_off + 1 ))" "$LOG" 2>/dev/null | grep -c ":$DOUBLE_PORT_B" || true)"
									echo
									printf '  routed since start   A: %s   B: %s\n' "$cnt_a" "$cnt_b"
								fi
								sleep 1
							done
							;;
						*)
							echo "nixllm: unknown double subcommand '$sub' (start|stop|status)" >&2
							exit 1
							;;
					esac
					;;
				single)
					sub="''${1:-}"
					[ "$#" -gt 0 ] && shift || true
					case "$sub" in
						stop)
							which="''${1:-}"
							case "$which" in
								a) unit=nixllm-single-a ;;
								b) unit=nixllm-single-b ;;
								"")
									a_active=false; b_active=false
									systemctl is-active --quiet nixllm-single-a && a_active=true
									systemctl is-active --quiet nixllm-single-b && b_active=true
									if [ "$a_active" = true ] && [ "$b_active" = false ]; then which=a; unit=nixllm-single-a
									elif [ "$b_active" = true ] && [ "$a_active" = false ]; then which=b; unit=nixllm-single-b
									elif [ "$a_active" = true ] && [ "$b_active" = true ]; then
										echo "nixllm: both gpu-a and gpu-b are active - specify 'nixllm single stop a' or 'nixllm single stop b'" >&2
										exit 1
									else
										echo "nixllm: single not running"
										exit 0
									fi
									;;
								*) echo "nixllm: unknown gpu '$which' (a|b)" >&2; exit 1 ;;
							esac
							sudo systemctl stop "$unit" 2>/dev/null || true
							echo "nixllm: single ($which) stopped"
							;;
						status)
							which="''${1:-}"
							case "$which" in
								a) systemctl --no-pager --full status nixllm-single-a || true
									echo; echo "gpu-a (port $(port)): $(health)" ;;
								b) systemctl --no-pager --full status nixllm-single-b || true
									echo; echo "gpu-b (port $(port)): $(health)" ;;
								"") systemctl --no-pager --full status nixllm-single-a nixllm-single-b || true
									echo
									echo "gpu-a/gpu-b share port $(port) - at most one runs at a time: $(health)" ;;
								*) echo "nixllm: unknown gpu '$which' (a|b)" >&2; exit 1 ;;
							esac
							;;
						""|start)
							shopt -s nullglob
							found=("$MODELS_DIR"/*.gguf)
							if [ ''${#found[@]} -eq 0 ]; then
								echo "nixllm: no models in $MODELS_DIR - run 'nixllm pull' first" >&2
								exit 1
							fi
							args=()
							for f in "''${found[@]}"; do
								args+=("$f" "$(basename "$f") ($(du -h "$f" | cut -f1))")
							done
							model="$(whiptail --title "nixllm single" --menu \
								"Select a model" 20 78 10 \
								"''${args[@]}" 3>&1 1>&2 2>&3)" || { echo "nixllm: cancelled"; exit 0; }
							clear

							gpu="$(whiptail --title "nixllm single" --menu \
								"Select which GPU to run on (the other GPU is left untouched)" 15 70 2 \
								a "GPU 0 (nixllm-single-a)" \
								b "GPU 1 (nixllm-single-b)" \
								3>&1 1>&2 2>&3)" || { echo "nixllm: cancelled"; exit 0; }
							clear

							case "$gpu" in
								a) unit=nixllm-single-a; other=nixllm-single-b ;;
								b) unit=nixllm-single-b; other=nixllm-single-a ;;
							esac

							printf '%s' "$model" > "$MODEL_F"
							echo "nixllm: single model -> $model"
							if systemctl is-active --quiet nixllm; then
								echo "nixllm: stopping single-instance nixllm service (shares the main port)"
								sudo systemctl stop nixllm
							fi
							if systemctl is-active --quiet "$other"; then
								echo "nixllm: stopping $other (shares the main port)"
								sudo systemctl stop "$other"
							fi
							echo "nixllm: starting $unit ..."
							sudo systemctl restart "$unit"
							if wait_health; then
								echo "nixllm: single up on gpu-$gpu -> http://$(host):$(port)"
							else
								echo "nixllm: single started but /health did not come up - check 'nixllm single status $gpu'" >&2
								exit 1
							fi

							command -v rocm-smi >/dev/null || { echo "nixllm: rocm-smi unavailable" >&2; exit 1; }
							GPUS="$(list_amdgpu_gpus)"
							[ -n "$GPUS" ] || { echo "nixllm: no amdgpu cards found" >&2; exit 1; }
							mauth=(); [ -s "$API_KEY_F" ] && mauth=(-H "Authorization: Bearer $(cat "$API_KEY_F")")

							cleanup() {
								printf '\033[?25h\033[?1049l'
								echo "nixllm: stopping single ($unit) ..."
								sudo systemctl stop "$unit" 2>/dev/null || true
								exit 0
							}
							printf '\033[?1049h\033[?25l'
							trap cleanup INT TERM EXIT
							while :; do
								j="$(rocm-smi --showtemp --showpower --showuse --showbus --json 2>/dev/null || true)"
								printf '\033[H\033[2J'
								echo "nixllm single (gpu-$gpu)   $(date '+%H:%M:%S')   (Ctrl-C to stop and exit)"
								echo "model: $(cat "$MODEL_F" 2>/dev/null || echo -)"
								i=0
								while read -r cn pci hw dev; do
									[ -n "$cn" ] || continue
									case "$i" in 0) lbl=a ;; 1) lbl=b ;; *) lbl="$i" ;; esac
									mark=""; [ "$lbl" = "$gpu" ] && mark=" (running)"
									key="$(printf '%s' "$j" | jq -r --arg p "$pci" '
									  to_entries[] | select((.value["PCI Bus"] // "" | ascii_downcase) == ($p | ascii_downcase)) | .key' 2>/dev/null | head -n1 || true)"
									[ -n "$key" ] || key="$cn"
									read -r edge pwr use <<EOF2
$(printf '%s' "$j" | jq -r --arg k "$key" '
  (.[$k] // {}) as $c |
  [ ($c["Temperature (Sensor edge) (C)"]      // "n/a"),
    ($c["Average Graphics Package Power (W)"] // "n/a"),
    ($c["GPU use (%)"]                        // "n/a") ] | @tsv' 2>/dev/null)
EOF2
									[ -n "$edge" ] || edge="n/a"
									vram="n/a"
									if [ -r "$dev/mem_info_vram_used" ] && [ -r "$dev/mem_info_vram_total" ]; then
										vu="$(cat "$dev/mem_info_vram_used" 2>/dev/null || echo 0)"
										vt="$(cat "$dev/mem_info_vram_total" 2>/dev/null || echo 0)"
										case "$vu$vt" in
											*[!0-9]*|"") ;;
											*) [ "$vt" -gt 0 ] && vram="$(gib1 "$vu") / $(gib1 "$vt") GiB" ;;
										esac
									fi
									echo
									printf '  gpu-%s (%s, %s)%s\n' "$lbl" "$cn" "$pci" "$mark"
									printf '    temp %s C   power %s W   util %s %%   vram %s\n' "$edge" "$pwr" "$use" "$vram"
									i=$(( i + 1 ))
								done <<EOF3
$GPUS
EOF3
								echo
								m="$(curl -fsS --max-time 3 "''${mauth[@]}" "http://127.0.0.1:$(port)/metrics" 2>/dev/null || true)"
								if [ -n "$m" ]; then
									read -r in_s out_s act <<EOF4
$(printf '%s\n' "$m" | awk '
  $1=="llamacpp:prompt_tokens_seconds"   {a=$2}
  $1=="llamacpp:predicted_tokens_seconds"{b=$2}
  $1=="llamacpp:requests_processing"     {c=$2}
  END { printf "%s %s %s\n", (a==""?"0":a),(b==""?"0":b),(c==""?"0":c) }')
EOF4
									printf '  instance gpu-%s (:%s)  in %.0f/s  out %.0f/s  active %s\n' "$gpu" "$(port)" "$in_s" "$out_s" "$act"
								else
									printf '  instance gpu-%s (:%s)  unreachable\n' "$gpu" "$(port)"
								fi
								sleep 1
							done
							;;
						*)
							echo "nixllm: unknown single subcommand '$sub' (start|stop|status)" >&2
							exit 1
							;;
					esac
					;;
				headroom)
					GPUS="$(list_amdgpu_gpus)"
					[ -n "$GPUS" ] || { echo "nixllm: amdgpu VRAM sysfs not found" >&2; exit 1; }
					tot_mib=0; used_mib=0; ngpu=0
					while read -r cn pci hw dev; do
						[ -n "$cn" ] || continue
						[ -r "$dev/mem_info_vram_total" ] || continue
						ct=$(( $(cat "$dev/mem_info_vram_total") / 1048576 ))
						cu=$(( $(cat "$dev/mem_info_vram_used")  / 1048576 ))
						tot_mib=$(( tot_mib + ct )); used_mib=$(( used_mib + cu )); ngpu=$(( ngpu + 1 ))
						printf 'gpu %-7s: %6s MiB total   %6s used   %6s free   (%s)\n' \
							"$cn" "$ct" "$cu" "$(( ct - cu ))" "$pci"
					done <<EOF5
$GPUS
EOF5
					[ "$ngpu" -gt 0 ] || { echo "nixllm: amdgpu VRAM sysfs not found" >&2; exit 1; }
					free_mib=$(( tot_mib - used_mib ))
					[ "$ngpu" -gt 1 ] && printf 'gpu total  : %6s MiB total   %6s used   %6s free   (%s GPUs, model is layer-split)\n' \
						"$tot_mib" "$used_mib" "$free_mib" "$ngpu"

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
  nixllm double [start]        TUI: pick a model, run one copy per GPU
                                (stops the single-instance nixllm service)
                                gpu-a: port ${doublePortA}   gpu-b: port ${doublePortB}   auto ip_hash proxy: port ${doublePort}
  nixllm double stop           stop both double instances + nginx
  nixllm double status         double service state + per-instance health
  nixllm single [start]        TUI: pick a model and ONE GPU, leaves the other GPU untouched
                                runs on the main port (${defPort}), no nginx routing
  nixllm single stop [a|b]     stop the single instance (infers gpu if only one is running)
  nixllm single status [a|b]   single service state + health
  nixllm load <path.gguf>      select the active model
  nixllm backend <rocm|vulkan> choose the server backend (default: ${defBackend})
  nixllm swap                  flip which GPU is enumerated first in the layer-split (restart to apply)
  nixllm context [<n>]         get/set context window in tokens (restart to apply)
  nixllm p [<n>|clear]         get/set --parallel request slots (default: auto)
  nixllm think [off|low|full|<n>]  Qwen3 reasoning budget (default: off)
  nixllm fa [on|off|auto]      flash attention (default: ${defFlashAttn}, restart to apply)
  nixllm preset <code|think|clear> apply a sampling + reasoning bundle
  nixllm mmproj [add <p>|clear] attach/detach a vision projector (mmproj gguf)
  nixllm apikey [show|set <k>|generate|clear]  require Bearer auth on the HTTP endpoint
  nixllm badger map [show|set <name> <port>[:<gpu-index>]|clear <name>]
                                map a station name to a llama-server port for :${badgerPort}
  nixllm badger apikey [show|set <k>|generate|clear]  require Bearer auth on :${badgerPort}
  nixllm pull <hf-url>         download a gguf into $MODELS_DIR
  nixllm pull <repo> <file>    download huggingface.co/<repo>/resolve/main/<file>
  nixllm models                list downloaded models
  nixllm login [token]         save a Hugging Face token (prompts if omitted)
  nixllm logout                delete the saved token
  nixllm help                  this text

Config file ($CONFIG_F), KEY="VALUE" per line, overrides derivation defaults:
  NIXLLM_HOST (${defHost})  NIXLLM_PORT (${defPort})  NIXLLM_CTX (${defCtx})
  NIXLLM_NGL (${defNgl})  NIXLLM_BACKEND (${defBackend})  NIXLLM_FLASH_ATTN (${defFlashAttn})  NIXLLM_EXTRA_ARGS
  NIXLLM_PARALLEL  NIXLLM_REASONING (off)  NIXLLM_SAMPLE_ARGS  (see 'preset')  NIXLLM_GPU_ORDER (see 'swap')
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

	# Bash tab completion for the nixllm CLI. NixOS enables bash-completion by
	# default and auto-sources any share/bash-completion/completions/<name> that
	# a system package installs, so shipping this file is all that is needed.
	nixllmCompletion = pkgs.writeTextFile {
		name = "nixllm-completion.bash";
		destination = "/share/bash-completion/completions/nixllm";
		text = ''
			_nixllm() {
				local cur prev cword
				if ! _get_comp_words_by_ref -n : cur prev cword 2>/dev/null; then
					cur="''${COMP_WORDS[COMP_CWORD]}"
					prev="''${COMP_WORDS[COMP_CWORD-1]}"
					cword=$COMP_CWORD
				fi

				local cmds="start stop restart status gpu-monitor tps headroom double single load \
					backend swap context ctx parallel p think fa flash preset mmproj apikey \
					pull models login logout help"

				if [ "$cword" -eq 1 ]; then
					mapfile -t COMPREPLY < <(compgen -W "$cmds" -- "$cur")
					return
				fi

				local sub="''${COMP_WORDS[1]}"
				case "$sub" in
					backend)     mapfile -t COMPREPLY < <(compgen -W "rocm vulkan" -- "$cur") ;;
					fa|flash)    mapfile -t COMPREPLY < <(compgen -W "on off auto" -- "$cur") ;;
					think)       mapfile -t COMPREPLY < <(compgen -W "off low full" -- "$cur") ;;
					preset)      mapfile -t COMPREPLY < <(compgen -W "code think clear" -- "$cur") ;;
					parallel|p)  mapfile -t COMPREPLY < <(compgen -W "clear auto" -- "$cur") ;;
					double)
						[ "$cword" -eq 2 ] && mapfile -t COMPREPLY < <(compgen -W "start stop status" -- "$cur") ;;
					single)
						if [ "$cword" -eq 2 ]; then
							mapfile -t COMPREPLY < <(compgen -W "start stop status" -- "$cur")
						elif [ "$cword" -eq 3 ] && { [ "$prev" = "stop" ] || [ "$prev" = "status" ]; }; then
							mapfile -t COMPREPLY < <(compgen -W "a b" -- "$cur")
						fi ;;
					apikey)
						[ "$cword" -eq 2 ] && mapfile -t COMPREPLY < <(compgen -W "show set generate clear" -- "$cur") ;;
					badger)
						if [ "$cword" -eq 2 ]; then
							mapfile -t COMPREPLY < <(compgen -W "map apikey" -- "$cur")
						elif [ "$cword" -eq 3 ]; then
							case "$prev" in
								map)    mapfile -t COMPREPLY < <(compgen -W "show set clear" -- "$cur") ;;
								apikey) mapfile -t COMPREPLY < <(compgen -W "show set generate clear" -- "$cur") ;;
							esac
						fi ;;
					mmproj)
						if [ "$cword" -eq 2 ]; then
							mapfile -t COMPREPLY < <(compgen -W "show add clear help" -- "$cur")
						else
							_filedir gguf
						fi ;;
					load)        _filedir gguf ;;
					*)           ;;
				esac
			}
			complete -F _nixllm nixllm
		'';
	};
in
{
	environment.systemPackages = (with pkgs; [
		nixllmCli
		nixllmCompletion
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
	# nixllm double exposes each GPU instance directly (doublePortAInt/B) for
	# manual per-session routing, plus an nginx ip_hash proxy on doublePortInt
	# for automatic client-IP-based sticky routing if you want it instead.
	networking.firewall.allowedTCPPorts = [ defPortInt doublePortInt doublePortAInt doublePortBInt badgerPortInt ];

	# State dir is group-writable by wheel so 'nixllm load/backend/pull' need no sudo.
	systemd.tmpfiles.rules = [
		"d ${stateDir} 0775 llm wheel -"
		"d ${modelsDir} 0775 llm wheel -"
	];

	# Default Super Badger station map: gpu-a is GPU 0 (nixllm double's port
	# ${doublePortA}), gpu-b is GPU 1 (port ${doublePortB}) — matches
	# nixllmDoubleLaunchA/B's gpuIndex pinning above. Only seeded if the file
	# doesn't exist yet, so 'nixllm badger map set ...' edits made on the box
	# are never overwritten by a rebuild.
	system.activationScripts.nixllmBadgerStations = ''
		if [ ! -e ${badgerStationMapF} ]; then
			mkdir -p ${stateDir}
			cat > ${badgerStationMapF} <<-EOF
			gpu-a=${doublePortA}:0
			gpu-b=${doublePortB}:1
			EOF
			chown llm:llm ${badgerStationMapF}
			chmod 664 ${badgerStationMapF}
		fi
	'';

	# nixllm double: one llama-server per GPU (ROCR/HIP_VISIBLE_DEVICES pinned),
	# same model, fronted by nginx ip_hash for session-sticky routing. Started
	# and stopped together by 'nixllm double', never at boot.
	systemd.services.nixllm-double-a = {
		description = "llama.cpp server (nixllm double, GPU 0)";
		serviceConfig = {
			ExecStart = nixllmDoubleLaunchA;
			User = "llm";
			Group = "llm";
			Restart = "on-failure";
			RestartSec = 2;
			# llama-server won't exit while it has in-flight requests to cancel;
			# a client that keeps retrying against a stopping instance can wedge
			# a graceful shutdown indefinitely. Force it after a short grace
			# period so 'stop'/'restart'/Ctrl-C never hangs for minutes.
			TimeoutStopSec = 15;
			SupplementaryGroups = [ "video" "render" ];
			Environment = [
				"VK_ICD_FILENAMES=/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json"
			];
		};
	};
	systemd.services.nixllm-double-b = {
		description = "llama.cpp server (nixllm double, GPU 1)";
		serviceConfig = {
			ExecStart = nixllmDoubleLaunchB;
			User = "llm";
			Group = "llm";
			Restart = "on-failure";
			RestartSec = 2;
			# llama-server won't exit while it has in-flight requests to cancel;
			# a client that keeps retrying against a stopping instance can wedge
			# a graceful shutdown indefinitely. Force it after a short grace
			# period so 'stop'/'restart'/Ctrl-C never hangs for minutes.
			TimeoutStopSec = 15;
			SupplementaryGroups = [ "video" "render" ];
			Environment = [
				"VK_ICD_FILENAMES=/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json"
			];
		};
	};

	# nixllm single: one GPU-pinned llama-server on the main port (defPort),
	# no nginx. Only one of these (or plain "nixllm") ever runs at a time,
	# since they share defPort. Started/stopped by 'nixllm single'.
	systemd.services.nixllm-single-a = {
		description = "llama.cpp server (nixllm single, GPU 0)";
		serviceConfig = {
			ExecStart = nixllmSingleLaunchA;
			User = "llm";
			Group = "llm";
			Restart = "on-failure";
			RestartSec = 2;
			TimeoutStopSec = 15;
			SupplementaryGroups = [ "video" "render" ];
			Environment = [
				"VK_ICD_FILENAMES=/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json"
			];
		};
	};
	systemd.services.nixllm-single-b = {
		description = "llama.cpp server (nixllm single, GPU 1)";
		serviceConfig = {
			ExecStart = nixllmSingleLaunchB;
			User = "llm";
			Group = "llm";
			Restart = "on-failure";
			RestartSec = 2;
			TimeoutStopSec = 15;
			SupplementaryGroups = [ "video" "render" ];
			Environment = [
				"VK_ICD_FILENAMES=/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json"
			];
		};
	};

	# Reverse proxy for double only. ip_hash keeps a given client on the
	# same backend so its KV cache is actually reused turn-to-turn (llama.cpp
	# instances share no context with each other). Never auto-started - the
	# 'nixllm double' subcommand starts/stops it alongside the two instances.
	# 'nixllm single' does not use nginx at all - it binds the main port
	# (defPort) directly, no proxy in front.
	services.nginx = {
		enable = true;
		recommendedProxySettings = true;
		upstreams.nixllm_double = {
			extraConfig = "ip_hash;";
			servers = {
				"127.0.0.1:${doublePortA}" = {};
				"127.0.0.1:${doublePortB}" = {};
			};
		};
		virtualHosts."nixllm-double" = {
			listen = [ { addr = "0.0.0.0"; port = doublePortInt; } ];
			locations."/".proxyPass = "http://nixllm_double";
			extraConfig = ''
				access_log /var/log/nginx/nixllm-double.log combined_upstream;
			'';
		};
		# appendHttpConfig is emitted after virtualHosts in the generated
		# nginx.conf, so a log_format there is defined too late for the
		# access_log directive that references it - commonHttpConfig is
		# emitted before virtualHosts instead.
		commonHttpConfig = ''
			log_format combined_upstream '$remote_addr - $remote_user [$time_local] '
				'"$request" $status $body_bytes_sent "$http_referer" '
				'"$http_user_agent" -> $upstream_addr';
		'';
	};
	systemd.services.nginx.wantedBy = lib.mkForce [ ];

	# Super Badger Station Standard API adapter - replaces the old plain GPU
	# JSON dump on :9999. GET any path returns {"<station>": {"gpu_temp_c":..,
	# "gpu_util_pct":.., "tokens_per_sec":..}} for every station in
	# ${badgerStationMapF} (see 'nixllm badger map'). Optional Bearer auth via
	# ${badgerApiKeyF} ('nixllm badger apikey').
	systemd.services.nixllm-badger-api = {
		description = "Super Badger Station Standard API adapter";
		wantedBy = [ "multi-user.target" ];
		serviceConfig = {
			ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:${badgerPort},fork,reuseaddr,bind=0.0.0.0 EXEC:${badgerHttp}";
			Restart = "on-failure";
			RestartSec = 2;
			User = "llm";
			Group = "llm";
			SupplementaryGroups = [ "video" "render" ];
		};
	};

	# Started on demand by 'nixllm start' - deliberately not in multi-user.target.
	systemd.services.nixllm = {
		description = "llama.cpp server (managed by the nixllm CLI)";
		serviceConfig = {
			ExecStart = nixllmLaunch;
			User = "llm";
			Group = "llm";
			Restart = "on-failure";
			RestartSec = 2;
			# llama-server won't exit while it has in-flight requests to cancel;
			# a client that keeps retrying against a stopping instance can wedge
			# a graceful shutdown indefinitely. Force it after a short grace
			# period so 'stop'/'restart'/Ctrl-C never hangs for minutes.
			TimeoutStopSec = 15;
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
