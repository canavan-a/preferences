{ config, pkgs, lib, ... }:
let
	# Strata (github.com/Niko1221/Strata): an MoE engine that keeps Qwen3.8-Flash-Next's
	# experts in RAM and caches the hot ones on the GPUs. Built from source for the
	# 7900 XTXs (gfx1100) instead of upstream's setup.sh, which compiles into its own
	# repo folder and pip-installs into a .venv.
	strata = pkgs.callPackage ./strata/package.nix { };
	python = strata.python;
	share  = "${strata}/share/strata";

	stateDir   = "/var/lib/nixstrata";
	configF    = "${stateDir}/config";
	# GGUFs share nixllm's models folder, one subfolder per model: Strata only reads
	# them (its packs and MTP draft live in stateDir), and nixllm's menus glob
	# models/*.gguf non-recursively, so the shards stay out of them.
	modelsRoot = "/var/lib/nixllm/models";
	port       = 8080;
	# Super Badger station endpoint for Strata (strata/nixstrata-badger.py), up only while nixstrata runs
	badgerPort    = 9998;
	badgerStation = "strata";

	# Models nixstrata can pull / use / delete. To add one, add an entry.
	#   files:      every shard, as named in the repo (shard 1 first)
	#   pack_args:  tools/iq_pack.py flags (--compat-bf16: ordinary GGUFs quantize small
	#               projections Strata reads as BF16; docs/ORCA.md)
	#   prefill / context: starting engine settings (ORCA.md's validated ones)
	#   ram_gb:     the experts plus the engine around them, for the KV-streaming RAM rule
	orcaRepo = "orcarouter/Qwen3.8-Flash-Next-Uncensored-GGUF";
	catalog = {
		"orca-iq3_xxs" = {
			about = "OrcaRouter Uncensored IQ3_XXS, 85 GB (documented: docs/ORCA.md)";
			repo = orcaRepo;
			files = [
				"Qwen3.8-Flash-Next-Uncensored-IQ3_XXS-00001-of-00002.gguf"
				"Qwen3.8-Flash-Next-Uncensored-IQ3_XXS-00002-of-00002.gguf"
			];
			dir = "${modelsRoot}/orca-iq3_xxs";
			pack_args = [ "--compat-bf16" ];
			prefill = 512;
			context = 32768;
			ram_gb = 66;
		};
		"orca-iq4_xs" = {
			about = "OrcaRouter Uncensored IQ4_XS, 98 GB (EXPERIMENTAL: untested with Strata)";
			repo = orcaRepo;
			files = [
				"Qwen3.8-Flash-Next-Uncensored-IQ4_XS-00001-of-00003.gguf"
				"Qwen3.8-Flash-Next-Uncensored-IQ4_XS-00002-of-00003.gguf"
				"Qwen3.8-Flash-Next-Uncensored-IQ4_XS-00003-of-00003.gguf"
			];
			dir = "${modelsRoot}/orca-iq4_xs";
			pack_args = [ "--compat-bf16" ];
			prefill = 512;
			context = 32768;
			ram_gb = 82;   # estimate: no upstream figure for this quant
		};
	};
	catalogJson = pkgs.writeText "nixstrata-catalog.json" (builtins.toJSON catalog);

	hipblasltHeader = "${pkgs.rocmPackages.hipblaslt}/include/hipblaslt/hipblaslt-version.h";

	# ExecStartPre: settings -> strata.json (see strata/nixstrata-config.py).
	writeConfig = pkgs.writeShellScript "nixstrata-write-config" ''
		export NIXSTRATA_HIPBLASLT_HEADER=${hipblasltHeader}
		exec ${python}/bin/python ${./strata/nixstrata-config.py} ${stateDir} ${catalogJson} ${strata}
	'';

	nixstrataCli = pkgs.writeShellApplication {
		name = "nixstrata";
		runtimeInputs = with pkgs; [ curl coreutils gnugrep gnused gawk jq newt systemd findutils ];
		text = ''
			STATE="${stateDir}"
			CONFIG_F="${configF}"
			CATALOG="${catalogJson}"
			SHARE="${share}"
			PY="${python}/bin/python"
			PORT="${toString port}"
			API_KEY_F="$STATE/apikey"
			# the same token file as 'nixllm login', so one login covers both
			TOKEN_F="''${XDG_CONFIG_HOME:-$HOME/.config}/nixllm/token"
			export STRATA_GGUF_PY="${strata.llamaSrc}/gguf-py"

			die() { echo "nixstrata: $*" >&2; exit 1; }

			hf_token() {
				# precedence: env -> 'nixstrata/nixllm login' file -> huggingface-cli login file
				if [ -n "''${HF_TOKEN:-}" ]; then printf '%s' "$HF_TOKEN"; return; fi
				if [ -s "$TOKEN_F" ]; then cat "$TOKEN_F"; return; fi
				if [ -s "$HOME/.cache/huggingface/token" ]; then cat "$HOME/.cache/huggingface/token"; return; fi
			}

			cfg_get() {
				if [ -f "$CONFIG_F" ] && grep -q "^$1=" "$CONFIG_F"; then
					grep "^$1=" "$CONFIG_F" | tail -n1 | cut -d= -f2- | sed 's/^"//; s/"$//'
				else
					printf '%s' "$2"
				fi
			}
			cfg_set() {
				touch "$CONFIG_F"
				if grep -q "^$1=" "$CONFIG_F"; then
					sed -i "s|^$1=.*|$1=\"$2\"|" "$CONFIG_F"
				else
					printf '%s="%s"\n' "$1" "$2" >> "$CONFIG_F"
				fi
			}
			cfg_unset() { if [ -f "$CONFIG_F" ]; then sed -i "/^$1=/d" "$CONFIG_F"; fi; }
			restart_hint() {
				if systemctl is-active --quiet nixstrata; then echo "nixstrata: run 'nixstrata restart' to apply"; fi
			}

			# ---- catalog
			keys()      { jq -r 'keys[]' "$CATALOG"; }
			known()     { jq -e --arg k "$1" 'has($k)' "$CATALOG" >/dev/null; }
			field()     { jq -r --arg k "$1" ".[\$k].$2" "$CATALOG"; }
			files_of()  { jq -r --arg k "$1" '.[$k].files[]' "$CATALOG"; }
			dir_of()    { field "$1" dir; }
			need_key()  { known "$1" || die "unknown model '$1' (known: $(keys | tr '\n' ' '))"; }

			# ---- disk
			gb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1e9 }'; }
			free_bytes() { df --output=avail -B1 "$(dirname "${modelsRoot}")" | tail -n1 | tr -d ' '; }
			# bytes of a model on disk: finished shards + partial (.part) downloads
			have_bytes() {
				local d f n=0 s
				d="$(dir_of "$1")"
				while IFS= read -r f; do
					for p in "$d/$f" "$d/$f.part"; do
						if [ -f "$p" ]; then s="$(stat -c%s "$p")"; n=$(( n + s )); fi
					done
				done < <(files_of "$1")
				echo "$n"
			}
			# total size from the Hub's file listing (public even for gated repos)
			remote_bytes() {
				local repo
				repo="$(field "$1" repo)"
				curl -fsS --max-time 30 "https://huggingface.co/api/models/$repo/tree/main" \
					| jq --argjson want "$(jq -c --arg k "$1" '.[$k].files' "$CATALOG")" \
						'[.[] | select(.type == "file" and (.path as $p | $want | index($p))) | .size] | add // 0'
			}
			# "ready" (every shard finished), "partial", or "missing"
			status_of() {
				local d f all=1 any=0
				d="$(dir_of "$1")"
				while IFS= read -r f; do
					if [ -f "$d/$f" ]; then any=1; else all=0; fi
					if [ -f "$d/$f.part" ]; then any=1; fi
				done < <(files_of "$1")
				if [ "$all" = 1 ]; then echo ready; elif [ "$any" = 1 ]; then echo partial; else echo missing; fi
			}
			mtp_ready() { [ -f "$STATE/mtp/rt/experts.bin" ]; }

			# whiptail menu over model keys that pass a filter ("all", "ready", "present")
			pick() {
				local title="$1" filter="$2" k st args=()
				while IFS= read -r k; do
					st="$(status_of "$k")"
					case "$filter" in
						ready)   [ "$st" = ready ] || continue ;;
						present) [ "$st" != missing ] || continue ;;
					esac
					args+=("$k" "[$st] $(field "$k" about)")
				done < <(keys)
				[ "''${#args[@]}" -gt 0 ] || die "no models to choose from (see 'nixstrata models')"
				whiptail --title "nixstrata" --menu "$title" 20 100 10 "''${args[@]}" 3>&1 1>&2 2>&3
			}

			confirm() {
				local a
				printf '%s [y/N] ' "$1"
				read -r a
				case "$a" in y|Y|yes) return 0 ;; *) return 1 ;; esac
			}

			health() { curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null || true; }
			wait_health() {
				# loading ~50+ GB of experts into RAM takes minutes
				local i
				for i in $(seq 1 900); do
					if health | grep -q '"service": *"strata"'; then return 0; fi
					if ! systemctl is-active --quiet nixstrata; then return 1; fi
					if [ $(( i % 30 )) = 0 ]; then echo "nixstrata: still loading ($i s) ..."; fi
					sleep 1
				done
				return 1
			}

			# ---- pull
			pull() {
				local key="$1" repo d tok code total have need extra free f url
				repo="$(field "$key" repo)"
				d="$(dir_of "$key")"
				tok="$(hf_token)"
				auth=()
				if [ -n "$tok" ]; then auth=(-H "Authorization: Bearer $tok"); fi

				# the Orca repo is gated: check access before anything else
				url="https://huggingface.co/$repo/resolve/main/$(files_of "$key" | head -n1)"
				code="$(curl -s -o /dev/null -w '%{http_code}' -I "''${auth[@]}" "$url")"
				case "$code" in
					200|302|307) ;;
					401) die "Hugging Face says not logged in (401): run 'nixstrata login'" ;;
					403) die "no access yet (403): accept the terms at https://huggingface.co/$repo, then retry" ;;
					*)   die "unexpected HTTP $code checking $url" ;;
				esac

				total="$(remote_bytes "$key")"
				[ "$total" -gt 0 ] || die "could not read the file sizes of $repo"
				have="$(have_bytes "$key")"
				need=$(( total - have ))
				if [ "$need" -le 0 ] && [ "$(status_of "$key")" = ready ]; then
					echo "nixstrata: $key is already downloaded"; return 0
				fi
				# + the pack (~1.5 GB), the MTP draft once (~6 GB) and a 10 GB margin
				extra=$(( 1500000000 + 10000000000 ))
				if ! mtp_ready; then extra=$(( extra + 6000000000 )); fi
				free="$(free_bytes)"
				echo "model     : $key ($(field "$key" about))"
				echo "download  : $(gb "$total") GB total, $(gb "$have") GB already here, $(gb "$need") GB to go"
				echo "also      : $(gb "$extra") GB for the pack, MTP draft and a safety margin"
				echo "free disk : $(gb "$free") GB"
				if [ $(( need + extra )) -gt "$free" ]; then
					echo
					echo "nixstrata: not enough space: need $(gb $(( need + extra ))) GB, have $(gb "$free") GB" >&2
					local k other=0
					while IFS= read -r k; do
						if [ "$k" != "$key" ] && [ "$(status_of "$k")" != missing ]; then
							[ "$other" = 1 ] || echo "  downloaded models you could remove ('nixstrata delete'):" >&2
							other=1
							echo "    $k  $(gb "$(have_bytes "$k")") GB" >&2
						fi
					done < <(keys)
					exit 1
				fi
				confirm "download $(gb "$need") GB into $d?" || { echo "nixstrata: cancelled"; return 0; }

				mkdir -p "$d"
				while IFS= read -r f; do
					if [ -f "$d/$f" ]; then echo "nixstrata: $f done already"; continue; fi
					echo "nixstrata: $f"
					# .part until finished, so a cut-off download is never taken for a whole shard
					curl -fL -C - --progress-bar "''${auth[@]}" -o "$d/$f.part" \
						"https://huggingface.co/$repo/resolve/main/$f" || die "download failed: run 'nixstrata pull $key' again to resume"
					mv "$d/$f.part" "$d/$f"
				done < <(files_of "$key")
				echo "nixstrata: $key downloaded - run 'nixstrata use $key'"
			}

			# ---- use: pack + MTP draft (once), then select
			use() {
				local key="$1" d pack args=()
				[ "$(status_of "$key")" = ready ] || die "$key is not fully downloaded - run 'nixstrata pull $key'"
				d="$(dir_of "$key")"
				pack="$STATE/packs/$key"
				mapfile -t args < <(jq -r --arg k "$key" '.[$k].pack_args[]' "$CATALOG")
				if [ ! -f "$pack/native_experts.txt" ] || [ ! -f "$pack/tokenizer/vocab.json" ]; then
					echo "nixstrata: packing $key (dense weights + tokenizer; the experts stay in the GGUF) ..."
					mkdir -p "$STATE/packs"
					"$PY" "$SHARE/tools/iq_pack.py" --gguf "$d/$(files_of "$key" | head -n1)" --out "$pack" "''${args[@]}" \
						|| { rm -rf "$pack"; die "packing $key failed"; }
				fi
				if ! mtp_ready; then
					# the original Qwen checkpoint's MTP tensors (~5 GB, not gated), as setup.py does
					echo "nixstrata: building the MTP draft layer (one time) ..."
					mkdir -p "$STATE/mtp"
					"$PY" "$SHARE/tools/mtp_fetch.py" fetch --out "$STATE/mtp"
					"$PY" "$SHARE/tools/mtp_pack.py" --src "$STATE/mtp" --experts q2_0 --out "$STATE/mtp/mtp-q2_0.gguf"
					"$PY" "$SHARE/tools/mtp_rt.py" --gguf "$STATE/mtp/mtp-q2_0.gguf" --out "$STATE/mtp/rt"
				fi
				cp -f "$SHARE/data/draft_vocab.bin" "$STATE/mtp/rt/draft_vocab.bin"
				cfg_set STRATA_MODEL "$key"
				echo "nixstrata: active model -> $key"
				if systemctl is-active --quiet nixstrata && confirm "restart nixstrata now?"; then
					sudo systemctl restart nixstrata
					if wait_health; then echo "nixstrata: up at http://0.0.0.0:$PORT"; else die "did not come up - 'nixstrata logs'"; fi
				fi
			}

			# ---- delete
			delete() {
				local key="$1" d pack
				d="$(dir_of "$key")"
				pack="$STATE/packs/$key"
				if [ "$(cfg_get STRATA_MODEL "")" = "$key" ] && systemctl is-active --quiet nixstrata; then
					die "$key is running - 'nixstrata stop' first"
				fi
				[ -e "$d" ] || [ -e "$pack" ] || die "$key has nothing on disk"
				echo "will remove:"
				[ -e "$d" ] && du -sh "$d"
				[ -e "$pack" ] && du -sh "$pack"
				confirm "delete $key?" || { echo "nixstrata: cancelled"; return 0; }
				rm -rf -- "$d" "$pack"
				if [ "$(cfg_get STRATA_MODEL "")" = "$key" ]; then cfg_unset STRATA_MODEL; fi
				echo "nixstrata: $key deleted ($(gb "$(free_bytes)") GB free)"
			}

			usage() {
				cat <<-EOF
				nixstrata - Strata (Qwen3.8-Flash-Next MoE engine) on this machine, port $PORT
				Shares the port, both GPUs and the RAM with nixllm: starting one stops the other.

				  nixstrata models               what is downloaded, active, and the free disk
				  nixstrata login [token]        Hugging Face token (shared with nixllm; the Orca repo is gated)
				  nixstrata logout
				  nixstrata pull [model]         download a model (menu without one); checks access and disk first
				  nixstrata use [model]          pick the model to run (prepares it on first use)
				  nixstrata delete [model]       remove a model's files and pack
				  nixstrata start|stop|restart   the service
				  nixstrata status               service, settings and /health
				  nixstrata logs [engine]        service journal, or the engine's own log
				  nixstrata context [n]          max context in tokens (default: the model's, 32768 for Orca)
				  nixstrata gpus [0,1|0|1]       both cards (layer split, default) or one
				  nixstrata top                  live: both GPUs, RAM, tok/s, expert cache hit/miss
				  nixstrata monitor [on|off]     /api-monitor page: the last 100 API requests and answers
				  nixstrata apikey [show|set <k>|generate|clear]
				EOF
			}

			cmd="''${1:-help}"
			[ "$#" -gt 0 ] && shift || true

			case "$cmd" in
				models|ls)
					active="$(cfg_get STRATA_MODEL "")"
					printf '%-14s %-8s %9s  %s\n' MODEL STATUS "ON DISK" ABOUT
					while IFS= read -r k; do
						st="$(status_of "$k")"
						mark=""
						[ "$k" = "$active" ] && mark=" *active*"
						printf '%-14s %-8s %6s GB  %s%s\n' "$k" "$st" "$(gb "$(have_bytes "$k")")" "$(field "$k" about)" "$mark"
					done < <(keys)
					echo
					echo "free disk: $(gb "$(free_bytes)") GB    MTP draft: $(mtp_ready && echo built || echo 'not built')"
					;;
				login)
					if [ "$#" -eq 1 ]; then
						tok="$1"
					else
						echo "Accept the model's terms first: https://huggingface.co/${orcaRepo}" >&2
						echo "Token (read access): https://huggingface.co/settings/tokens" >&2
						printf 'Hugging Face token (input hidden): ' >&2
						read -rs tok
						echo >&2
					fi
					[ -n "$tok" ] || die "empty token"
					mkdir -p "$(dirname "$TOKEN_F")"
					( umask 077; printf '%s' "$tok" > "$TOKEN_F" )
					who="$(curl -fsS -H "Authorization: Bearer $tok" https://huggingface.co/api/whoami-v2 2>/dev/null | jq -r '.name // empty' || true)"
					if [ -n "$who" ]; then echo "nixstrata: logged in as $who (token in $TOKEN_F)"; else echo "nixstrata: token saved to $TOKEN_F, but Hugging Face did not accept it" >&2; fi
					;;
				logout)
					rm -f "$TOKEN_F"
					echo "nixstrata: removed $TOKEN_F (nixllm shares it)"
					;;
				pull)
					if [ "$#" -ge 1 ]; then key="$1"; else key="$(pick "Model to download" all)" || { echo "nixstrata: cancelled"; exit 0; }; clear; fi
					need_key "$key"
					pull "$key"
					;;
				use)
					if [ "$#" -ge 1 ]; then key="$1"; else key="$(pick "Model to run" ready)" || { echo "nixstrata: cancelled"; exit 0; }; clear; fi
					need_key "$key"
					use "$key"
					;;
				delete|rm)
					if [ "$#" -ge 1 ]; then key="$1"; else key="$(pick "Model to DELETE" present)" || { echo "nixstrata: cancelled"; exit 0; }; clear; fi
					need_key "$key"
					delete "$key"
					;;
				start|restart)
					[ -n "$(cfg_get STRATA_MODEL "")" ] || die "no model selected - run 'nixstrata use'"
					# Conflicts= stops nixllm (single, double) for us
					sudo systemctl "$cmd" nixstrata
					if wait_health; then
						echo "nixstrata: up at http://0.0.0.0:$PORT  ($(health))"
					else
						die "did not come up - check 'nixstrata logs' and 'nixstrata logs engine'"
					fi
					;;
				stop)
					sudo systemctl stop nixstrata
					echo "nixstrata: stopped"
					;;
				status)
					systemctl --no-pager --full status nixstrata || true
					echo
					echo "model   : $(cfg_get STRATA_MODEL "(none - run 'nixstrata use')")"
					echo "context : $(cfg_get STRATA_CTX "(model default)")"
					echo "gpus    : $(cfg_get STRATA_GPUS "0,1")"
					echo "endpoint: http://0.0.0.0:$PORT/v1"
					echo "badger  : http://0.0.0.0:${toString badgerPort}  ($(systemctl is-active nixstrata-badger || true))"
					echo "monitor : $(cfg_get STRATA_API_MONITOR off)"
					if [ -s "$API_KEY_F" ]; then echo "apikey  : set"; fi
					h="$(health)"
					echo "health  : ''${h:-unreachable}"
					;;
				logs)
					if [ "''${1:-}" = engine ]; then
						tail -n 200 -f "$STATE/strata.log"
					else
						journalctl -u nixstrata -n 200 -f
					fi
					;;
				context|ctx)
					if [ "$#" -eq 0 ]; then echo "context: $(cfg_get STRATA_CTX "(model default)")"; exit 0; fi
					case "$1" in
						default|clear) cfg_unset STRATA_CTX; echo "nixstrata: context -> model default" ;;
						""|*[!0-9]*) die "usage: nixstrata context <n-tokens|default>" ;;
						*) cfg_set STRATA_CTX "$1"; echo "nixstrata: context -> $1" ;;
					esac
					restart_hint
					;;
				gpus)
					if [ "$#" -eq 0 ]; then echo "gpus: $(cfg_get STRATA_GPUS "0,1")"; exit 0; fi
					case "$1" in
						0,1|1,0|0|1) cfg_set STRATA_GPUS "$1"; echo "nixstrata: gpus -> $1" ;;
						*) die "usage: nixstrata gpus <0,1|1,0|0|1>" ;;
					esac
					restart_hint
					;;
				top)
					# Live terminal dashboard: both GPUs (amdgpu sysfs - Strata's own Monitor tab reads
					# only GPU 0), system RAM, and the server's /metrics (speed, expert cache hits).
					mauth=()
					if [ -s "$API_KEY_F" ]; then mauth=(-H "Authorization: Bearer $(cat "$API_KEY_F")"); fi
					# a sysfs number, 0 when unreadable (a sleeping GPU answers EBUSY)
					num() { local v; v="$(cat "$1" 2>/dev/null || true)"; case "$v" in ""|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac; }
					bar() {   # bar <0-100> -> 20-char gauge
						awk -v p="$1" 'BEGIN { if (p == "" || p == "null") p = 0; n = int(p / 5 + 0.5); if (n > 20) n = 20
							s = ""; for (i = 0; i < 20; i++) s = s (i < n ? "#" : "."); printf "[%s]", s }'
					}
					printf '\033[?1049h\033[?25l'
					trap 'printf "\033[?25h\033[?1049l"; exit 0' INT TERM EXIT
					while :; do
						m="$(curl -fsS --max-time 2 "''${mauth[@]}" "http://127.0.0.1:$PORT/metrics" 2>/dev/null || true)"
						printf '\033[H\033[2J'
						echo "nixstrata top   $(date '+%H:%M:%S')   (Ctrl-C to exit)"
						echo

						# ---- GPUs
						i=0
						for d in /sys/class/drm/card*/device; do
							if ! grep -qs '^DRIVER=amdgpu$' "$d/uevent" || [ ! -r "$d/mem_info_vram_total" ]; then continue; fi
							util="$(num "$d/gpu_busy_percent")"; vu="$(num "$d/mem_info_vram_used")"; vt="$(num "$d/mem_info_vram_total")"
							[ "$vt" -gt 0 ] || vt=1
							temp="-"; pw="-"
							for h in "$d"/hwmon/hwmon*; do
								t="$(num "$h/temp1_input")"
								if [ "$t" -gt 0 ]; then temp="$(( t / 1000 ))C"; fi
								for pf in power1_average power1_input; do
									p="$(num "$h/$pf")"
									if [ "$p" -gt 0 ]; then pw="$(( p / 1000000 ))W"; break; fi
								done
							done
							printf 'GPU %d  load %s %3s%%   vram %s %5.1f / %4.1f GiB   %s  %s\n' "$i" \
								"$(bar "$util")" "$util" "$(bar $(( vu * 100 / vt )))" \
								"$(awk -v b="$vu" 'BEGIN{print b/1073741824}')" "$(awk -v b="$vt" 'BEGIN{print b/1073741824}')" "$temp" "$pw"
							i=$(( i + 1 ))
						done

						# ---- RAM (MemAvailable, as free -h's "available")
						read -r mt ma < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo)
						printf 'RAM    used %s %5.1f / %5.1f GiB\n' "$(bar $(( (mt - ma) * 100 / mt )))" \
							"$(awk -v k=$(( mt - ma )) 'BEGIN{print k/1048576}')" "$(awk -v k="$mt" 'BEGIN{print k/1048576}')"
						echo

						if [ -z "$m" ]; then
							echo "server: not reachable on :$PORT ('nixstrata status')"
							sleep 1; continue
						fi

						# ---- live
						printf '%s\n' "$m" | jq -r '
							.live as $l | .engine as $e |
							"model  \($e.model)   context \($e.max_context)   experts in VRAM \($e.expert_slots // "-")",
							"state  \($l.state)" +
							(if $l.state == "generating" then "   \($l.tok_s // "-") tok/s now, \($l.tok_s_mean // "-") mean   (\($l.generated // 0) tokens)"
							 elif $l.state == "reading" then "   prompt \($l.prompt_read // "?") / \($l.prompt_total // "?") tokens"
							 else "" end)'
						echo

						# ---- last finished request: speed and expert cache
						printf '%s\n' "$m" | jq -r '
							(.requests[0] // null) as $r |
							if $r == null then "last request: none yet" else
							"last request  \($r.prompt_tokens) in / \($r.output_tokens) out   \($r.duration_s)s",
							"  output      \($r.decode_tok_s // "-") tok/s",
							"  prompt      \(if $r.prompt_ms and $r.prompt_read then (($r.prompt_read / ($r.prompt_ms / 1000)) | floor | tostring) + " tok/s" else "-" end)",
							"  expert hit  \(if $r.hit_rate then (($r.hit_rate * 1000 | round) / 10 | tostring) + "% in VRAM,  miss " + (((1 - $r.hit_rate) * 1000 | round) / 10 | tostring) + "%" else "-" end)" +
							"\(if $r.pcie_share then "   (+" + (($r.pcie_share * 1000 | round) / 10 | tostring) + "% read over PCIe)" else "" end)",
							"  misses from RAM \($r.ram_blobs // "-")   from disk \($r.file_blobs // "-")",
							"  drafts      \(if $r.drafts_offered then "\($r.drafts_accepted)/\($r.drafts_offered) accepted (" + (($r.drafts_accepted * 100 / $r.drafts_offered) | floor | tostring) + "%)" else "-" end)"
							end'
						echo
						printf '%s\n' "$m" | jq -r '"since start: \(.totals.requests // 0) requests, \(.totals.prompt_tokens // 0) prompt tokens, \(.totals.output_tokens // 0) output tokens"'
						sleep 1
					done
					;;
				monitor)
					if [ "$#" -eq 0 ]; then
						echo "api monitor: $(cfg_get STRATA_API_MONITOR off)  (http://<host>:$PORT/api-monitor)"
						exit 0
					fi
					case "$1" in
						on)  cfg_set STRATA_API_MONITOR on
						     echo "nixstrata: api monitor on - the last 100 API requests (prompts and answers) are kept in memory"
						     echo "nixstrata: view at http://<host>:$PORT/api-monitor" ;;
						off) cfg_unset STRATA_API_MONITOR; echo "nixstrata: api monitor off" ;;
						*)   die "usage: nixstrata monitor [on|off]" ;;
					esac
					restart_hint
					;;
				apikey)
					sub="''${1:-show}"
					case "$sub" in
						show) if [ -s "$API_KEY_F" ]; then cat "$API_KEY_F"; echo; else echo "apikey: (none)"; fi ;;
						set)
							[ "$#" -eq 2 ] && [ -n "$2" ] || die "usage: nixstrata apikey set <key>"
							( umask 077; printf '%s' "$2" > "$API_KEY_F" ); chgrp wheel "$API_KEY_F"; chmod 640 "$API_KEY_F"
							echo "nixstrata: api key set"; restart_hint ;;
						generate|gen)
							k="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-40)"
							( umask 077; printf '%s' "$k" > "$API_KEY_F" ); chgrp wheel "$API_KEY_F"; chmod 640 "$API_KEY_F"
							echo "$k"; restart_hint ;;
						clear|rm) rm -f "$API_KEY_F"; echo "nixstrata: api key cleared"; restart_hint ;;
						*) die "usage: nixstrata apikey [show|set <k>|generate|clear]" ;;
					esac
					;;
				help|-h|--help) usage ;;
				*) usage; exit 1 ;;
			esac
		'';
	};
in
{
	environment.systemPackages = [ nixstrataCli strata ];

	networking.firewall.allowedTCPPorts = [ badgerPort ];

	# group-writable by wheel so the CLI needs no sudo, like nixllm's state dir
	systemd.tmpfiles.rules = [
		"d ${stateDir} 0775 llm wheel -"
	];

	# Started on demand by 'nixstrata start' - not in multi-user.target.
	systemd.services.nixstrata = {
		description = "Strata server (managed by the nixstrata CLI)";
		# Two-way: starting nixstrata stops these, starting any of them stops nixstrata.
		# They all want port ${toString port}, both GPUs and most of the RAM.
		conflicts = [
			"nixllm.service"
			"nixllm-single-a.service"
			"nixllm-single-b.service"
			"nixllm-double-a.service"
			"nixllm-double-b.service"
		];
		environment = {
			STRATA_GGUF_PY = "${strata.llamaSrc}/gguf-py";
		};
		serviceConfig = {
			ExecStartPre = writeConfig;
			ExecStart = "${python}/bin/python -m serve.server --engine strata --config ${stateDir}/strata.json --port ${toString port}";
			WorkingDirectory = share;
			User = "llm";
			Group = "llm";
			SupplementaryGroups = [ "video" "render" ];
			# the expert arena is pinned (page-locked) RAM
			LimitMEMLOCK = "infinity";
			Restart = "on-failure";
			RestartSec = 5;
			TimeoutStartSec = "15min";
			TimeoutStopSec = 30;
		};
	};

	# Super Badger Station Standard API for Strata on :${toString badgerPort}:
	# {"${badgerStation}": {tokens_per_sec, expert_hit_pct, gpu0_temp_c, ram_used_pct, ...}}.
	# wantedBy + partOf nixstrata.service: started and stopped (and restarted) with it,
	# so it is up exactly while Strata is - including while the model loads ("up": 0).
	systemd.services.nixstrata-badger = {
		description = "Super Badger station endpoint for nixstrata";
		wantedBy = [ "nixstrata.service" ];
		partOf = [ "nixstrata.service" ];
		after = [ "nixstrata.service" ];
		serviceConfig = {
			ExecStart = "${python}/bin/python ${./strata/nixstrata-badger.py} ${toString badgerPort} ${toString port} ${badgerStation} ${stateDir} ${share} ${strata}/libexec/strata/strata";
			User = "llm";
			Group = "llm";
			Restart = "on-failure";
			RestartSec = 2;
		};
	};
}
