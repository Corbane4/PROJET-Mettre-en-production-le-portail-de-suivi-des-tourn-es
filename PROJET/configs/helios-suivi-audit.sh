#!/usr/bin/bash
# helios-suivi-audit.sh — conformite E1..E9, LECTURE SEULE. rc 0 si 9/9, sinon 1.
set -uo pipefail
export LC_ALL=C PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
readonly WWW=/srv/helios/suivi/www
readonly ARCH=/srv/helios/archives/suivi
readonly SUDOERS=/etc/sudoers.d/92-helios-suivi
readonly PUB=/usr/local/sbin/helios-suivi-publish.sh
readonly BCK=/usr/local/sbin/helios-suivi-backup.sh
FAILS=""
LAST=""

if [[ $EUID -ne 0 ]]; then echo "[KO] a lancer en root"; echo "Bilan : 0/9"; exit 1; fi

# need : commande absente => echec (jamais de faux OK)
need() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || { FAILS+="commande absente: ${c}; "; return 1; }; done; return 0; }
# t "description" commande... : echec => on note la raison
t() { local d="$1"; shift; "$@" >/dev/null 2>&1 || FAILS+="${d}; "; }
sd() { systemctl show -p "$1" --value "$2" 2>/dev/null; }

# ---------- E1
f_gid()    { [ "$(getent group suivi | cut -d: -f3)" = 5003 ]; }
f_lea()    { [ "$(id -u lea)" = 5104 ] && [ "$(id -g lea)" = 5003 ] && [ "$(getent passwd lea | cut -d: -f5)" = "Lea Fabre - responsable suivi des tournees" ]; }
f_aging()  { getent shadow lea | awk -F: '{exit !($4==1 && $5==90 && $6==14 && $7==7)}'; }
f_nogrp()  { id lea >/dev/null && ! id -nG lea | tr ' ' '\n' | grep -Eqx 'wheel|ssh-admins'; }
f_svc()    { local l sh; l=$(getent passwd helios-suivi) || return 1
             [ "$(cut -d: -f3 <<<"$l")" -lt 1000 ] || return 1
             [ "$(cut -d: -f6 <<<"$l")" = /srv/helios/suivi ] || return 1
             sh=$(cut -d: -f7 <<<"$l"); [[ "$sh" == */nologin || "$sh" == */false ]] || return 1
             [ ! -e /home/helios-suivi ]; }
e1() { need id getent cut awk tr grep || return
  t "groupe suivi gid 5003" f_gid; t "lea uid/gid/commentaire" f_lea
  t "vieillissement lea (1/90/14/7)" f_aging; t "lea dans wheel ou ssh-admins" f_nogrp
  t "compte systeme helios-suivi" f_svc; }

# ---------- E2
f_mode()  { [ "$(stat -c '%U:%G %a' "$WWW")" = "root:suivi 2770" ]; }
f_aclsvc(){ getfacl -p "$WWW" | grep -qx 'user:helios-suivi:rwx'; }
f_rwsvc() { runuser -u helios-suivi -- test -r "$WWW" && runuser -u helios-suivi -- test -w "$WWW" && runuser -u helios-suivi -- test -x "$WWW"; }
f_aclzbx(){ getfacl -p "$WWW" | grep -qx 'user:zabbix:--x'; }
f_zbx()   { runuser -u zabbix -- stat "$WWW/etat.json" && ! runuser -u zabbix -- ls "$WWW"; }
f_other() { getfacl -p "$WWW" | grep -qx 'other::---'; }
f_dflt()  { local a; a=$(getfacl -p "$WWW") && grep -qx 'default:other::---' <<<"$a" && grep -qx 'default:group::rwx' <<<"$a" && grep -q '^default:user:helios-suivi:' <<<"$a"; }
f_index() { [ "$(stat -c %U "$WWW/index.html")" = lea ]; }
e2() { need stat getfacl runuser grep || return
  t "www root:suivi 2770" f_mode; t "ACL helios-suivi rwx" f_aclsvc; t "helios-suivi rwx effectif" f_rwsvc
  t "ACL zabbix --x" f_aclzbx; t "zabbix: stat OK et ls refuse" f_zbx; t "other::---" f_other
  t "ACL par defaut (g rwx, o ---, helios-suivi)" f_dflt; t "index.html depose par lea" f_index; }

# ---------- E3
f_scr3() { [ -x "$PUB" ] && bash -n "$PUB"; }
f_rul3() { grep -q 'set -euo pipefail' "$PUB" && grep -q 'flock' "$PUB" && grep -q 'trap ' "$PUB" && grep -q 'helios-suivi-publish' "$PUB"; }
f_json() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert all(k in d for k in ("genere","hote","derniere_mesure","charge_1min","mem_dispo_ko","mesures"))' "$WWW/etat.json"; }
f_fresh(){ [ $(( $(date +%s) - $(stat -c %Y "$WWW/etat.json") )) -lt 300 ]; }
e3() { need python3 bash grep date stat || return
  t "script publication present/syntaxe" f_scr3; t "regles de production (strict, flock, trap, tag)" f_rul3
  t "etat.json JSON valide avec les champs" f_json; t "etat.json plus vieux de 5 min (ou absent)" f_fresh; }

# ---------- E4
f_http() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1")" = 200 ]; }
f_exec() { sd ExecStart helios-suivi.service | grep -q 'python3 -m http.server 8080 --bind 0.0.0.0 --directory /srv/helios/suivi/www'; }
f_rest() { case "$(sd Restart helios-suivi.service)" in always|on-failure) return 0;; *) return 1;; esac; }
f_res()  { [ "$(sd MemoryMax helios-suivi.service)" = 134217728 ] && [ "$(sd CPUQuotaPerSecUSec helios-suivi.service)" = 500ms ]; }
f_dep()  { systemctl list-dependencies helios.target --plain --no-pager | grep -q 'helios-suivi.service'; }
f_score(){ local s; s=$(systemd-analyze security helios-suivi.service --no-pager 2>/dev/null | grep -oE 'exposure level for [^:]+: [0-9.]+' | awk '{print $NF}') && [ -n "$s" ] && awk -v s="$s" 'BEGIN{exit !(s<=4.0)}'; }
f_pub()  { [ "$(sd User helios-suivi-publish.service)" = helios-suivi ] && [ "$(sd Type helios-suivi-publish.service)" = oneshot ] && [ "$(sd ProtectSystem helios-suivi-publish.service)" = strict ] && [ "$(sd ReadWritePaths helios-suivi-publish.service)" = "$WWW" ]; }
e4() { need systemctl systemd-analyze curl awk grep || return
  t "portail arrete (helios-suivi.service)" test "$(systemctl is-active helios-suivi.service)" = active
  t "portail non active au boot" test "$(systemctl is-enabled helios-suivi.service)" = enabled
  t "utilisateur != helios-suivi" test "$(sd User helios-suivi.service)" = helios-suivi
  t "commande imposee" f_exec; t "Restart" f_rest; t "MemoryMax/CPUQuota" f_res
  t "absent de helios.target" f_dep; t "exposition > 4.0" f_score
  t "HTTP / != 200" f_http http://127.0.0.1:8080/; t "HTTP /etat.json != 200" f_http http://127.0.0.1:8080/etat.json
  t "unit publication" f_pub; t "timer publication inactif" test "$(systemctl is-active helios-suivi-publish.timer)" = active; }

# ---------- E5
f_sud()  { [ -f "$SUDOERS" ] && visudo -c -f "$SUDOERS" && [ "$(stat -c '%a %U:%G' "$SUDOERS")" = "440 root:root" ]; }
f_nopw() { [ -f "$SUDOERS" ] && ! grep -q NOPASSWD "$SUDOERS"; }
f_nowild(){ [ -f "$SUDOERS" ] && ! grep -v '^[[:space:]]*#' "$SUDOERS" | grep -q '\*'; }
f_allow(){ sudo -l -U lea /usr/bin/systemctl restart helios-suivi.service && sudo -l -U lea /usr/bin/systemctl start helios-suivi-publish.service \
           && sudo -l -U lea /usr/bin/journalctl -u helios-suivi.service -n 100 --no-pager && sudo -l -U lea /usr/bin/journalctl -u helios-suivi-publish.service -n 100 --no-pager; }
f_deny() { ! sudo -l -U lea /usr/bin/systemctl restart sshd && ! sudo -l -U lea /usr/bin/systemctl restart sshd.service \
           && ! sudo -l -U lea /usr/bin/journalctl --vacuum-size=1K && ! sudo -l -U lea /usr/bin/systemctl stop helios-suivi.service; }
e5() { need sudo visudo stat grep || return
  t "sudoers invalide ou droits != 0440 root:root" f_sud; t "NOPASSWD present" f_nopw; t "joker * dans la delegation" f_nowild
  t "commandes autorisees manquantes" f_allow; t "delegation trop large (ex. restart sshd)" f_deny; }

# ---------- E6
e6() { need firewall-cmd || return
  firewall-cmd --state >/dev/null 2>&1 || { FAILS+="firewalld inactif; "; return; }
  [ "$(firewall-cmd --get-default-zone)" = drop ] || FAILS+="zone par defaut != drop; "
  firewall-cmd --zone=internal --query-port=8080/tcp >/dev/null 2>&1 || FAILS+="8080/tcp absent en runtime (internal); "
  firewall-cmd --permanent --zone=internal --query-port=8080/tcp >/dev/null 2>&1 || FAILS+="8080/tcp absent en permanent (internal); "
  local z m out
  for z in $(firewall-cmd --get-zones); do
    [ "$z" = internal ] && continue
    for m in "" "--permanent"; do
      if out=$(firewall-cmd $m --zone="$z" --list-all 2>/dev/null); then
        grep -Eq '(^|[^0-9])8080([^0-9]|$)' <<<"$out" && FAILS+="8080 present dans ${z} ${m}; "
      else FAILS+="zone ${z} illisible; "; fi
    done
  done; }

# ---------- E7
f_sshd() { local o; o=$(sshd -T 2>/dev/null) && grep -qx 'port 2242' <<<"$o" && grep -qx 'permitrootlogin no' <<<"$o" \
           && grep -qx 'passwordauthentication no' <<<"$o" && grep -qx 'allowgroups ssh-admins' <<<"$o"; }
f_leassh(){ id lea >/dev/null && ! id -nG lea | tr ' ' '\n' | grep -qx ssh-admins; }
e7() { need sshd systemctl id grep || return
  t "sshd -T (2242/root/mdp/allowgroups)" f_sshd; t "lea a acces SSH (ssh-admins)" f_leassh
  t "helios-watch-auth.timer inactif" test "$(systemctl is-active helios-watch-auth.timer)" = active
  t "journald non persistant" test -d "/var/log/journal/$(cat /etc/machine-id)"; }

# ---------- E8
f_zb()  { getent passwd zabbix && [ "$(systemctl is-active zabbix-agent2)" = active ] && [ "$(systemctl is-enabled zabbix-agent2)" = enabled ]; }
f_sar() { [ "$(systemctl is-active sysstat-collect.timer)" = active ] && [ "$(systemctl is-enabled sysstat-collect.timer)" = enabled ]; }
f_conf(){ grep -q '^UserParameter=helios.suivi.http,' /etc/zabbix/zabbix_agent2.d/helios-suivi.conf && grep -q '^UserParameter=helios.suivi.age,' /etc/zabbix/zabbix_agent2.d/helios-suivi.conf; }
f_zh()  { [ "$(zabbix_get -s 127.0.0.1 -k helios.suivi.http)" = 200 ]; }
f_za()  { local a; a=$(zabbix_get -s 127.0.0.1 -k helios.suivi.age) && [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -lt 300 ]; }
e8() { need zabbix_get getent systemctl grep || return
  t "agent2 inactif/non enabled" f_zb; t "sysstat-collect.timer inactif" f_sar; t "helios-suivi.conf incomplet" f_conf
  t "zabbix_get agent.ping != 1" test "$(zabbix_get -s 127.0.0.1 -k agent.ping)" = 1
  t "helios.suivi.http != 200" f_zh; t "helios.suivi.age absent ou >= 300" f_za; }

# ---------- E9
f_ad()  { [ "$(stat -c '%U:%G %a' /srv/helios/archives)" = "helios:helios 750" ]; }
f_bt()  { [ "$(systemctl is-active helios-suivi-backup.timer)" = active ] && systemctl cat helios-suivi-backup.timer | grep -q '^Persistent=true' && systemctl cat helios-suivi-backup.timer | grep -q '03:15'; }
f_bs()  { [ -x "$BCK" ] && bash -n "$BCK" && grep -q 'flock' "$BCK" && grep -q 'helios-suivi-backup' "$BCK"; }
f_last(){ LAST=$(find "$ARCH" -maxdepth 1 -name 'suivi-*.tar.gz' -printf '%f\n' 2>/dev/null | sort | tail -1); [ -n "$LAST" ] && [ -f "$ARCH/$LAST.sha256" ]; }
f_sum() { ( cd "$ARCH" && sha256sum -c --quiet -- "$LAST.sha256" ); }
f_cont(){ local l p; l=$(tar -tzf "$ARCH/$LAST") || return 1
  for p in srv/helios/suivi/www/ etc/sudoers.d/92-helios-suivi etc/zabbix/zabbix_agent2.d/helios-suivi.conf \
           usr/local/sbin/helios-suivi-publish.sh usr/local/sbin/helios-suivi-backup.sh \
           etc/systemd/system/helios-suivi.service etc/systemd/system/helios-suivi-publish.service etc/systemd/system/helios-suivi-publish.timer \
           etc/systemd/system/helios-suivi-backup.service etc/systemd/system/helios-suivi-backup.timer; do
    grep -qxF "$p" <<<"$l" || return 1
  done; }
f_keep(){ [ "$(find "$ARCH" -maxdepth 1 -name 'suivi-*.tar.gz' | wc -l)" -le 7 ]; }
e9() { need tar sha256sum find stat systemctl grep || return
  t "archives != helios:helios 0750" f_ad; t "script de sauvegarde" f_bs; t "timer sauvegarde (03:15, Persistent)" f_bt
  if f_last; then
    t "empreinte sha256 invalide" f_sum; t "archive incomplete" f_cont; t "plus de 7 archives" f_keep
  else FAILS+="aucune sauvegarde (ou .sha256 absent); "; fi; }

# ---------- Execution
ok=0
run() { FAILS=""; "$3"
  if [ -z "$FAILS" ]; then echo "[OK] E$1 - $2"; ok=$((ok+1)); else echo "[KO] E$1 - $2 : ${FAILS%; }"; fi; }
run 1 "Comptes et groupe" e1
run 2 "Repertoire publie (setgid, ACL)" e2
run 3 "Script de publication" e3
run 4 "Units systemd (portail durci, timer)" e4
run 5 "Delegation sudo" e5
run 6 "Pare-feu" e6
run 7 "Non-regression securite" e7
run 8 "Supervision Zabbix" e8
run 9 "Sauvegarde" e9
echo "Bilan : ${ok}/9"
if [ "$ok" -eq 9 ]; then exit 0; else exit 1; fi
