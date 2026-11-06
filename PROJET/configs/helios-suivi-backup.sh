#!/usr/bin/bash
# helios-suivi-backup.sh — sauvegarde du portail (ACL, empreinte, retention 7)
# Sortie : 0 OK · 1 erreur interne · 2 instance deja en cours · 3 prerequis manquant
set -euo pipefail
IFS=$'\n\t'
readonly TAG=helios-suivi-backup
readonly ARCH=/srv/helios/archives
readonly DEST="${ARCH}/suivi"
readonly KEEP=7
readonly LOCK=/run/helios-suivi-backup.lock
readonly -a ITEMS=(
  srv/helios/suivi
  etc/systemd/system/helios-suivi.service
  etc/systemd/system/helios-suivi-publish.service
  etc/systemd/system/helios-suivi-publish.timer
  etc/systemd/system/helios-suivi-backup.service
  etc/systemd/system/helios-suivi-backup.timer
  etc/sudoers.d/92-helios-suivi
  etc/zabbix/zabbix_agent2.d/helios-suivi.conf
  usr/local/sbin/helios-suivi-publish.sh
  usr/local/sbin/helios-suivi-backup.sh
)

log() { logger -t "$TAG" -p "daemon.${1}" -- "$2" ; }
die() { log err "$1" ; exit "${2:-1}" ; }
cleanup() {
    local rc=$?
    if [[ -n "${TMPF:-}" ]]; then rm -f -- "$TMPF" ; fi
    log info "fin d execution rc=${rc}"
    return 0
}
trap cleanup EXIT
trap 'die "interrompu par signal" 1' INT TERM

exec 9>"$LOCK"
flock -n 9 || { log warning "une autre instance tourne deja" ; exit 2 ; }

for c in tar sha256sum gzip logger find; do
    command -v "$c" >/dev/null || die "commande absente : $c" 3
done
[[ -d "$ARCH" ]] || die "repertoire absent : $ARCH" 3
for p in "${ITEMS[@]}"; do
    [[ -e "/${p}" ]] || die "element a sauvegarder absent : /${p}" 3
done

log info "demarrage"
install -d -m 0750 -o helios -g helios "$DEST"
name="suivi-$(date +%Y%m%d-%H%M%S).tar.gz"
TMPF="${DEST}/.${name}.part"

# tar rend 1 si un fichier change pendant la lecture (etat.json) : toléré
set +e
tar --acls --xattrs -C / -czpf "$TMPF" "${ITEMS[@]}"
trc=$?
set -e
(( trc <= 1 )) || die "tar a echoue (rc=${trc})" 1
tar -tzf "$TMPF" >/dev/null || die "archive illisible" 1

mv -f -- "$TMPF" "${DEST}/${name}"
TMPF=""
( cd "$DEST" && sha256sum -- "$name" > "${name}.sha256" )
chown helios:helios "${DEST}/${name}" "${DEST}/${name}.sha256"
chmod 0640 "${DEST}/${name}" "${DEST}/${name}.sha256"
( cd "$DEST" && sha256sum -c --quiet -- "${name}.sha256" ) || die "empreinte invalide" 1
log info "archive ${DEST}/${name} creee"

# Retention : on garde les KEEP plus recentes (le nom porte l'horodatage)
mapfile -t old < <(find "$DEST" -maxdepth 1 -name 'suivi-*.tar.gz' -printf '%f\n' | sort -r | tail -n +$((KEEP + 1)))
for f in "${old[@]}"; do
    rm -f -- "${DEST}/${f}" "${DEST}/${f}.sha256"
    log info "purge ${f}"
done
exit 0
