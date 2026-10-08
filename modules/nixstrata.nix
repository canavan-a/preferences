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
	# Super Badger: strata/nixstrata-control.py owns the public badger port (always on) and
	# serves the command list; station metrics pass through it to whichever adapter is up on
	# the localhost-only adapter port - nixllm's while Strata is stopped, or
	# strata/nixstrata-badger.py while a Strata server runs (same station map, so the station
	# names gpu-a, gpu-b, ... stay put whichever backend serves them).
	badgerPort        = 9999;
	badgerAdapterPort = 9997;   # keep in step with wrx80-local-ai.nix's
	badgerStationMap  = "/var/lib/nixllm/badger-stations";
	badgerApiKeyF     = "/var/lib/nixllm/badger-apikey";

	# nixstrata double: one Strata per GPU, the same ports as nixllm double (nginx's ip_hash
	# proxy on 8090, from wrx80-local-ai.nix, in front of 8091/8092), so clients don't change.
	# Both engines back their expert arena with one MAP_SHARED file (--shared-expert-arena),
	# so the ~50 GB of experts sit in RAM once, not twice. It lives on its own tmpfs, not
	# /dev/shm: logind's RemoveIPC empties a normal user's /dev/shm files at logout.
	arenaDir = "/run/nixstrata-arena";
	doubleInstances = {
		a = { gpu = 0; port = 8091; };
		b = { gpu = 1; port = 8092; };
	};
	nixllmUnits = [
		"nixllm.service" "nixllm-single-a.service" "nixllm-single-b.service"
		"nixllm-double-a.service" "nixllm-double-b.service"
	];

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

	# ExecStartPre: settings -> strata.json / strata-<instance>.json (see strata/nixstrata-config.py).
	writeConfig = instArgs: pkgs.writeShellScript "nixstrata-write-config" ''
		export NIXSTRATA_HIPBLASLT_HEADER=${hipblasltHeader}
		exec ${python}/bin/python ${./strata/nixstrata-config.py} ${stateDir} ${catalogJson} ${strata} ${instArgs}
	'';

	# ExecStopPost of a double instance: once neither is running, drop the shared arena so
	# its ~50 GB of tmpfs go back to the system (nixllm, the single server).
	arenaCleanup = pkgs.writeShellScript "nixstrata-arena-cleanup" ''
		for u in ${lib.concatMapStringsSep " " (n: "nixstrata-${n}") (lib.attrNames doubleInstances)}; do
			if ${pkgs.systemd}/bin/systemctl is-active --quiet "$u"; then exit 0; fi
		done
		${pkgs.coreutils}/bin/rm -f ${arenaDir}/*.arena
	'';

	# Every Strata server unit: the single one on ${toString port} (both GPUs, `nixstrata gpus`)
	# and the double instances. All of them exclude nixllm and each other ("conflicts" works
	# both ways) - they want the same GPUs and most of the RAM.
	mkStrataService = { description, configName, servicePort, instArgs ? "", conflicts, extra ? { } }:
		lib.recursiveUpdate {
			inherit description conflicts;
			wants = [ "nixstrata-badger.service" ];
			# a crash at start (bad config, arena error) gives up after 3 tries instead of
			# reloading ~50 GB every 5 s forever
			startLimitIntervalSec = 600;
			startLimitBurst = 3;
			environment.STRATA_GGUF_PY = "${strata.llamaSrc}/gguf-py";
			serviceConfig = {
				ExecStartPre = writeConfig instArgs;
				ExecStart = "${python}/bin/python -m serve.server --engine strata --config ${stateDir}/${configName} --port ${toString servicePort}";
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
		} extra;

	# the Strata servers the badger endpoint knows: PORT=UNIT:CONFIG (see strata/nixstrata-badger.py)
	badgerServers = [ "${toString port}=nixstrata.service:${stateDir}/strata.json" ]
		++ lib.mapAttrsToList (n: i: "${toString i.port}=nixstrata-${n}.service:${stateDir}/strata-${n}.json")
			doubleInstances;

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
			# every Strata server: "UNIT PORT", the single one first, then nixstrata double's
			SERVERS="nixstrata $PORT
			${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: i: "nixstrata-${n} ${toString i.port}") doubleInstances)}"
			DOUBLE_UNITS="${lib.concatMapStringsSep " " (n: "nixstrata-${n}") (lib.attrNames doubleInstances)}"
			read -ra DOUBLE_ARR <<< "$DOUBLE_UNITS"
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
			# the Strata servers running now, as "UNIT PORT" lines
			running() {
				local u p
				while read -r u p; do
					[ -n "$u" ] || continue
					if systemctl is-active --quiet "$u"; then echo "$u $p"; fi
				done <<< "$SERVERS"
			}
			double_running() { running | grep -q '^nixstrata-'; }
			restart_hint() {
				if double_running; then echo "nixstrata: run 'nixstrata double restart' to apply"
				elif [ -n "$(running)" ]; then echo "nixstrata: run 'nixstrata restart' to apply"; fi
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
				# NIXSTRATA_YES=1: answer yes (Super Badger's commands, via nixstrata-control)
				if [ "''${NIXSTRATA_YES:-}" = 1 ]; then echo "$1 [y/N] y"; return 0; fi
				printf '%s [y/N] ' "$1"
				read -r a
				case "$a" in y|Y|yes) return 0 ;; *) return 1 ;; esac
			}

			# health [port]
			health() { curl -fsS --max-time 2 "http://127.0.0.1:''${1:-$PORT}/health" 2>/dev/null || true; }
			# wait_health [unit] [port]: loading ~50+ GB of experts into RAM takes minutes
			wait_health() {
				local i unit="''${1:-nixstrata}" p="''${2:-$PORT}"
				for i in $(seq 1 900); do
					if health "$p" | grep -q '"service": *"strata"'; then return 0; fi
					if ! systemctl is-active --quiet "$unit"; then return 1; fi
					if [ $(( i % 30 )) = 0 ]; then echo "nixstrata: $unit still loading ($i s) ..."; fi
					sleep 1
				done
				return 1
			}

			# show_failure UNIT ENGINE-LOG: why a start failed, without a second command
			show_failure() {
				echo "---- journal: $1" >&2
				journalctl -u "$1" -n 25 --no-pager -o cat >&2 || true
				if [ -f "$2" ]; then
					echo "---- engine log: $2" >&2
					tail -n 25 "$2" >&2
				fi
				echo "----" >&2
			}

			# nixstrata double: a first (it writes the shared expert arena), b once a is up
			# (it finds the arena filled), then nginx's sticky proxy on 8090
			double_start() {
				local u p
				[ -n "$(cfg_get STRATA_MODEL "")" ] || die "no model selected - run 'nixstrata use'"
				# Conflicts= stops nixllm and the single nixstrata for us
				while read -r u p; do
					case "$u" in nixstrata-*) ;; *) continue ;; esac
					echo "nixstrata: starting $u (port $p) ..."
					# a deliberate start clears an earlier crash loop's start limit
					sudo systemctl reset-failed "$u" 2>/dev/null || true
					if ! sudo systemctl start "$u" || ! wait_health "$u" "$p"; then
						show_failure "$u" "$STATE/strata-''${u#nixstrata-}.log"
						die "$u did not come up - more: 'nixstrata logs ''${u#nixstrata-}' / 'nixstrata logs ''${u#nixstrata-} engine'"
					fi
					echo "nixstrata: $u up on :$p"
				done <<< "$SERVERS"
				sudo systemctl start nginx
				echo "nixstrata: double up - sticky proxy http://0.0.0.0:8090, or each instance directly"
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
				if double_running; then
					if confirm "restart nixstrata double now?"; then
						# both stop first, so the old model's shared arena is dropped
						sudo systemctl stop "''${DOUBLE_ARR[@]}"
						double_start
					fi
				elif systemctl is-active --quiet nixstrata && confirm "restart nixstrata now?"; then
					sudo systemctl restart nixstrata
					if wait_health; then echo "nixstrata: up at http://0.0.0.0:$PORT"; else die "did not come up - 'nixstrata logs'"; fi
				fi
			}

			# ---- delete
			delete() {
				local key="$1" d pack
				d="$(dir_of "$key")"
				pack="$STATE/packs/$key"
				if [ "$(cfg_get STRATA_MODEL "")" = "$key" ] && [ -n "$(running)" ]; then
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
				  nixstrata start|restart        one server on :$PORT across both GPUs
				  nixstrata double [start|restart|stop|status]
				                                 one server per GPU (:8091, :8092, sticky proxy :8090),
				                                 sharing one copy of the experts in RAM
				  nixstrata stop                 stop whichever is running
				  nixstrata status               services, settings and /health
				  nixstrata state                mode, settings and models as JSON (for nixstrata-control)
				  nixstrata logs [a|b] [engine]  service journal, or the engine's own log (a/b: double)
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
					# Conflicts= stops nixllm (single, double) and nixstrata double for us
					sudo systemctl reset-failed nixstrata 2>/dev/null || true
					if sudo systemctl "$cmd" nixstrata && wait_health; then
						echo "nixstrata: up at http://0.0.0.0:$PORT  ($(health))"
					else
						show_failure nixstrata "$STATE/strata.log"
						die "did not come up - more: 'nixstrata logs' / 'nixstrata logs engine'"
					fi
					;;
				double)
					sub="''${1:-start}"
					case "$sub" in
						start) double_start ;;
						restart) sudo systemctl stop "''${DOUBLE_ARR[@]}"; double_start ;;
						stop)
							sudo systemctl stop "''${DOUBLE_ARR[@]}"
							sudo systemctl stop nginx 2>/dev/null || true
							echo "nixstrata: double stopped (shared arena freed)" ;;
						status)
							systemctl --no-pager --full status "''${DOUBLE_ARR[@]}" || true
							echo
							du -sh ${arenaDir}/*.arena 2>/dev/null | sed 's/^/arena   : /' || echo "arena   : (none)" ;;
						*) die "usage: nixstrata double [start|restart|stop|status]" ;;
					esac
					;;
				stop)
					# whichever is running: the single server, or both double instances (+ their proxy)
					if double_running; then
						sudo systemctl stop "''${DOUBLE_ARR[@]}"
						sudo systemctl stop nginx 2>/dev/null || true
					fi
					sudo systemctl stop nixstrata
					echo "nixstrata: stopped"
					;;
				status)
					if double_running; then mode="double"; elif [ -n "$(running)" ]; then mode="single"; else mode="stopped"; fi
					echo "mode    : $mode"
					echo "model   : $(cfg_get STRATA_MODEL "(none - run 'nixstrata use')")"
					echo "context : $(cfg_get STRATA_CTX "(model default)")"
					echo "gpus    : $(cfg_get STRATA_GPUS "0,1") (single; double pins one per instance)"
					echo "badger  : http://0.0.0.0:${toString badgerPort}  (control $(systemctl is-active nixstrata-control || true), strata adapter $(systemctl is-active nixstrata-badger || true); nixllm's station map)"
					echo "monitor : $(cfg_get STRATA_API_MONITOR off)"
					if [ -s "$API_KEY_F" ]; then echo "apikey  : set"; fi
					while read -r u p; do
						h="$(health "$p")"
						echo "$u :$p  ''${h:-unreachable}"
					done < <(running)
					;;
				state)
					if double_running; then mode="double"; elif [ -n "$(running)" ]; then mode="single"; else mode="stopped"; fi
					models="$(while IFS= read -r k; do
						jq -n --arg k "$k" --arg s "$(status_of "$k")" --arg a "$(field "$k" about)" '{key: $k, status: $s, about: $a}'
					done < <(keys) | jq -s .)"
					jq -n --arg mode "$mode" --arg model "$(cfg_get STRATA_MODEL "")" --arg gpus "$(cfg_get STRATA_GPUS "0,1")" \
						--arg context "$(cfg_get STRATA_CTX "")" --argjson models "$models" \
						'{mode: $mode, model: $model, gpus: $gpus, context: $context, models: $models}'
					;;
				logs)
					unit="nixstrata"; log="$STATE/strata.log"
					case "''${1:-}" in
						a|b|nixstrata-a|nixstrata-b)
							i="''${1#nixstrata-}"; unit="nixstrata-$i"; log="$STATE/strata-$i.log"; shift ;;
					esac
					if [ "''${1:-}" = engine ]; then
						tail -n 200 -f "$log"
					else
						journalctl -u "$unit" -n 200 -f
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
						srv="$(running)"
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

						if [ -z "$srv" ]; then
							echo "no Strata server running ('nixstrata start' or 'nixstrata double')"
							sleep 1; continue
						fi

						# one block per server: the single one, or both double instances
						while read -r u p; do
						m="$(curl -fsS --max-time 2 "''${mauth[@]}" "http://127.0.0.1:$p/metrics" 2>/dev/null || true)"
						echo "== $u  :$p"
						if [ -z "$m" ]; then echo "not answering yet (still loading? 'nixstrata logs')"; echo; continue; fi

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
						echo
						done <<< "$srv"
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

	# The shared expert arena of nixstrata double: RAM-backed, sized for the largest catalog
	# model's arena (tmpfs only uses what is written; the cleanup above empties it).
	fileSystems."${arenaDir}" = {
		device = "tmpfs";
		fsType = "tmpfs";
		options = [ "size=72G" "mode=0750" "nosuid" "nodev" ];
	};

	# nixstrata-control runs the CLI as llm, and the CLI starts/stops its units through sudo:
	# exactly those systemctl calls, without a password. Both systemctl paths, since sudo
	# resolves it from the caller's PATH (the CLI's own systemd, or the system profile's).
	security.sudo.extraRules = [{
		users = [ "llm" ];
		commands = map (command: { inherit command; options = [ "NOPASSWD" ]; })
			(lib.concatMap (args: [
				"${pkgs.systemd}/bin/systemctl ${args}"
				"/run/current-system/sw/bin/systemctl ${args}"
			]) ([
				"start nixstrata" "restart nixstrata" "stop nixstrata" "reset-failed nixstrata"
				"start nginx" "stop nginx"
				"stop ${lib.concatMapStringsSep " " (n: "nixstrata-${n}") (lib.attrNames doubleInstances)}"
			] ++ lib.concatMap (n: [ "start nixstrata-${n}" "reset-failed nixstrata-${n}" ])
				(lib.attrNames doubleInstances)));
	}];

	# group-writable by wheel so the CLI needs no sudo, like nixllm's state dir
	systemd.tmpfiles.rules = [
		"d ${stateDir} 0775 llm wheel -"
		"d ${arenaDir} 0750 llm llm -"
	];

	# nixstrata double: one engine per GPU, started by 'nixstrata double' (b once a is up,
	# so a writes the shared arena first and b finds it filled).
	systemd.services = lib.mapAttrs' (n: i: lib.nameValuePair "nixstrata-${n}" (mkStrataService {
		description = "Strata server (nixstrata double, GPU ${toString i.gpu})";
		configName = "strata-${n}.json";
		servicePort = i.port;
		instArgs = "${n} ${toString i.gpu} ${toString i.port} ${arenaDir}";
		conflicts = nixllmUnits;
		extra = {
			unitConfig.RequiresMountsFor = arenaDir;
			serviceConfig = {
				# the tmpfs mounts root-owned (tmpfiles may run before the mount exists): hand it
				# to llm first ("+": this one step as root), then write the config as llm
				ExecStartPre = [
					"+${pkgs.coreutils}/bin/chown llm:llm ${arenaDir}"
					"${writeConfig "${n} ${toString i.gpu} ${toString i.port} ${arenaDir}"}"
				];
				ExecStopPost = arenaCleanup;
			};
		};
	})) doubleInstances // {

		# Started on demand by 'nixstrata start' - not in multi-user.target.
		nixstrata = mkStrataService {
			description = "Strata server (managed by the nixstrata CLI)";
			configName = "strata.json";
			servicePort = port;
			conflicts = nixllmUnits ++ map (n: "nixstrata-${n}.service") (lib.attrNames doubleInstances);
		};

		# Super Badger Station Standard API on the localhost adapter port, with nixllm's station
		# map (nixstrata-control passes metrics requests here). Wanted by every Strata server;
		# Conflicts= stops nixllm's adapter to free the port, and when no Strata server is left
		# this one exits cleanly and OnSuccess= starts nixllm's again.
		nixstrata-badger = {
			description = "Super Badger station endpoint for nixstrata (stands in for nixllm-badger-api)";
			conflicts = [ "nixllm-badger-api.service" ];
			after = [ "nixllm-badger-api.service" ];
			unitConfig.OnSuccess = [ "nixllm-badger-api.service" ];
			path = [ pkgs.systemd ];
			serviceConfig = {
				ExecStart = "${python}/bin/python ${./strata/nixstrata-badger.py} ${toString badgerAdapterPort} ${stateDir} ${share} ${strata}/libexec/strata/strata ${badgerStationMap} ${lib.escapeShellArgs badgerServers}";
				User = "llm";
				Group = "llm";
				Restart = "on-failure";
				RestartSec = 2;
			};
		};

		# Super Badger's front on the public badger port (strata/nixstrata-control.py): the
		# nixstrata commands (mode, GPUs, model, context) plus the station metrics passed
		# through to the adapter port. Always on, so the commands work with no model running
		# and a command that swaps the adapters keeps its connection.
		nixstrata-control = {
			description = "Super Badger front: nixstrata commands + station metrics passthrough";
			wantedBy = [ "multi-user.target" ];
			after = [ "network.target" ];
			# the CLI, and sudo from the setuid wrappers (NixOS services get a minimal PATH)
			path = [ nixstrataCli "/run/wrappers" ];
			environment.HOME = stateDir;
			serviceConfig = {
				ExecStart = "${pkgs.python3}/bin/python ${./strata/nixstrata-control.py} ${toString badgerPort} ${toString badgerAdapterPort} ${badgerApiKeyF}";
				User = "llm";
				Group = "llm";
				# metrics pass through here too: come straight back
				Restart = "always";
				RestartSec = 1;
			};
		};
	};
}
