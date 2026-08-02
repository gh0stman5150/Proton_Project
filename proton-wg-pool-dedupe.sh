#!/usr/bin/env bash
set -euo pipefail

# Move duplicate WireGuard pool profiles (identical PrivateKey+Address)
# Keeps one copy per unique (PrivateKey,Address) and preserves files
# currently referenced by /run/proton/*/current-server.env.

POOL_DIR="/etc/wireguard/proton-pool"
if [[ ! -d "$POOL_DIR" ]]; then
	echo "Pool directory not found: $POOL_DIR" >&2
	exit 0
fi

BACKUP_DIR="${POOL_DIR}/duplicates-$(date +%s)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

TMPMAP="$(mktemp)"
DUPLIST="/tmp/pool-duplicates-$$.tsv"
PRESERVE_FILE="/tmp/pool-preserve-$$.txt"

# Build preserve set from active selections
: >"$PRESERVE_FILE"
for env in /run/proton/*/current-server.env; do
	[[ -f "$env" ]] || continue
	selcfg="$(awk -F= '/^SELECTED_CONFIG=/ {print $2; exit}' "$env" | tr -d '"')"
	selbase="$(basename "$selcfg")"
	[[ -n "$selbase" ]] && echo "$selbase" >>"$PRESERVE_FILE"
done

if [[ -f "$PRESERVE_FILE" ]]; then
	mapfile -t PRESERVE_ARR < <(sort -u "$PRESERVE_FILE")
else
	PRESERVE_ARR=()
fi

shopt -s nullglob
files=("$POOL_DIR"/*.conf)
if [[ ${#files[@]} -eq 0 ]]; then
	echo "No .conf files in $POOL_DIR" >&2
	rm -f "$TMPMAP" "$DUPLIST" "$PRESERVE_FILE" 2>/dev/null || true
	exit 0
fi

# Build map of PrivateKey+Address -> filenames
for f in "${files[@]}"; do
	# skip files already in backup dir
	case "$f" in "$BACKUP_DIR"/*) continue ;; esac
	pk=$(awk -F= '/^[[:space:]]*PrivateKey[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$f" | tr -d '[:space:]')
	addr=$(awk -F= '/^[[:space:]]*Address[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$f" | tr -d '[:space:]')
	# only record if at least one of pk/addr present
	if [[ -n "$pk" || -n "$addr" ]]; then
		echo -e "${pk}	${addr}	$(basename "$f")" >>"$TMPMAP"
	fi
done

awk -F"\t" '{ key=$1 "|" $2; files[key]=files[key] " " $3; count[key]++ } END { for (k in count) if (count[k]>1) print k "\t" files[k] }' "$TMPMAP" >"$DUPLIST" || true

moved_count=0
while IFS=$'\t' read -r _ files_line; do
	files_line="${files_line# }"
	# split into array
	read -r -a filearr <<<"$files_line"
	# choose keeper: prefer currently-selected profile if present
	keeper=""
	for candidate in "${filearr[@]}"; do
		for p in "${PRESERVE_ARR[@]:-}"; do
			if [[ "$candidate" == "$p" ]]; then
				keeper="$candidate"
				break 2
			fi
		done
	done
	if [[ -z "$keeper" ]]; then
		keeper="${filearr[0]}"
	fi

	for fbasename in "${filearr[@]}"; do
		[[ "$fbasename" == "$keeper" ]] && continue
		src="$POOL_DIR/$fbasename"
		if [[ -f "$src" ]]; then
			mv -v -- "$src" "$BACKUP_DIR/" || true
			((moved_count++))
			# remove from pf lists if present
			if [[ -f /etc/proton/pf-capable-profiles.tsv ]]; then
				sed -i "\|$fbasename|d" /etc/proton/pf-capable-profiles.tsv || true
			fi
			if [[ -f /etc/proton/pf-incapable-profiles.tsv ]]; then
				sed -i "\|$fbasename|d" /etc/proton/pf-incapable-profiles.tsv || true
			fi
		fi
	done
done <"$DUPLIST"

echo "$BACKUP_DIR" >/run/proton/last-pool-dup-backup || true
echo "Moved $moved_count duplicate files to $BACKUP_DIR"

# cleanup
rm -f "$TMPMAP" "$DUPLIST" "$PRESERVE_FILE" 2>/dev/null || true

exit 0
