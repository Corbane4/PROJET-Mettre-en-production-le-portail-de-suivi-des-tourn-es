#!/usr/bin/bash
# helios-suivi-publish.sh — publie www/etat.json à partir de la dernière ligne de télémétrie.
# Sortie : 0 OK · 1 erreur interne · 2 instance déjà en cours · 3 prérequis manquant
set -euo pipefail
IFS=$'\n\t'

readonly SRC=/var/lib/helios/telemetry.csv
readonly WWW=/srv/helios/suivi/www
readonly OUT="${WWW}/etat.json"
readonly TAG=helios-suivi-publish
readonly SELF=/usr/local/sbin/helios-suivi-publish.sh   # verrou posé sur ce fichier : aucune écriture requise

log() { logger -t "$TAG" -p "daemon.${1}" -- "$2" ; }
die() { log err "$1" ; exit "${2:-1}" ; }
cleanup() {
    local rc=$?
    if [[ -n "${TMP:-}" ]]; then rm -f -- "$TMP" ; fi
    log info "fin d execution rc=${rc}"
    return 0
}
trap cleanup EXIT
trap 'die "interrompu par signal" 1' INT TERM

# Verrou exclusif non bloquant
exec 9<"$SELF"
flock -n 9 || { log warning "une autre instance tourne deja" ; exit 2 ; }

# Prérequis (code 3)
for c in logger mktemp tail wc date hostname; do
    command -v "$c" >/dev/null || die "commande absente : $c" 3
done
[[ -r "$SRC" ]]                  || die "telemetrie illisible : $SRC" 3
[[ -d "$WWW" && -w "$WWW" ]]     || die "www non inscriptible pour $(id -un)" 3

# Dernière ligne : horodatage ISO 8601,charge,mem_kB
last="$(tail -n 1 -- "$SRC")"
re='^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}),([0-9]+\.[0-9]+),([0-9]+)$'
[[ "$last" =~ $re ]] || die "ligne de telemetrie invalide : '${last}'" 1
mesure="${BASH_REMATCH[1]}"
charge="${BASH_REMATCH[2]}"
mem="${BASH_REMATCH[3]}"
mesures=$(( $(wc -l < "$SRC") ))

# Écriture atomique : fichier temporaire dans www, puis rename
TMP="$(mktemp "${WWW}/.etat.json.XXXXXX")"
printf '{\n  "genere": "%s",\n  "hote": "%s",\n  "derniere_mesure": "%s",\n  "charge_1min": %s,\n  "mem_dispo_ko": %s,\n  "mesures": %s\n}\n' \
    "$(date --iso-8601=seconds)" "$(hostname)" "$mesure" "$charge" "$mem" "$mesures" > "$TMP"
chmod 0660 "$TMP"
mv -f -- "$TMP" "$OUT"
TMP=""

log info "etat.json publie (charge=${charge} mem=${mem} mesures=${mesures})"
exit 0
