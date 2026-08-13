#!/usr/bin/env bash
# zcu-archaeology.sh -- READ ONLY. Find the stratum binary/source that actually
# merge-mined ZCU before 20 Jul 2026, and show what changed since.
#
#   curl -fsSL "https://pool.honest.money/install/zcu-archaeology.sh?v=$(date +%s)" | sudo bash
#
# WHY: an earlier hunt reported sub=0/gate=0/commit=0 for every binary on the
# box. That result was wrong twice over:
#   1. `strings` ran WITHOUT sudo inside the pipeline, so every /root/... path
#      returned "Permission denied" and was counted as 0.
#   2. The three symbols searched for (scrypt_submitAuxBlock / "ZCU full256
#      gate" / ZCUAUXCOMMIT) come from the *GitHub reference* tree. The build
#      that worked on 11 Jul most likely used the OLDER design: generic
#      getauxblock/submitauxblock with ZCU added to the allowlist in db.cpp.
#      That design leaves NONE of those three strings in the binary.
#
# So this script greps a WIDE symbol set, as root, over binaries, tarballs and
# source trees, and dates everything. Nothing is modified, started or stopped.
#
# VERSION LOG -- bump on every change, newest first.
#   v1  2026-08-13  First cut.
ARCH_VERSION="v1"
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
hr() { printf '\n=== %s ===\n' "$*"; }

echo "zcu-archaeology $ARCH_VERSION  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  host=$(hostname)"
echo "READ ONLY -- nothing is modified."

# Symbols, weakest evidence last.
NEW_SYMS='scrypt_submitAuxBlock|ZCU full256 gate|ZCUAUXCOMMIT|zcu_submit_from_ltc_parent|coind_create_template_zcu'
OLD_SYMS='submitauxblock|createauxblock|getauxblock'
NAME_SYMS='Zero Chill|ZCU'

scan_bin() { # scan_bin <path>
  local f="$1" s n o m
  s=$(strings -a "$f" 2>/dev/null)
  n=$(printf '%s' "$s" | grep -cEi "$NEW_SYMS")
  o=$(printf '%s' "$s" | grep -cEi "$OLD_SYMS")
  m=$(printf '%s' "$s" | grep -cE "$NAME_SYMS")
  printf '  %-16s new=%-4s aux=%-4s zcu=%-4s %s  %s\n' \
    "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')" \
    "$n" "$o" "$m" "$(sha256sum "$f" | cut -c1-12)" "$f"
}

hr "0. what is running right now"
systemctl cat stratum-aws-scrypt --no-pager 2>/dev/null | grep -E 'ExecStart|WorkingDirectory' | sed 's/^/   /'
ls -l /var/stratum/stratum 2>/dev/null | sed 's/^/   /'
PID=$(pgrep -f '/var/stratum/stratum' | head -1)
[ -n "${PID:-}" ] && readlink -f "/proc/$PID/exe" | sed 's/^/   running exe: /'
echo "   live binary symbols:"
[ -f /var/stratum/stratum ] && scan_bin /var/stratum/stratum

hr "1. EVERY stratum binary on the box (as root this time)"
echo "   new = reference-tree ZCU symbols | aux = generic auxblock RPC | zcu = 'ZCU'/'Zero Chill' literals"
find / -xdev -type f -name 'stratum*' -perm -u+x 2>/dev/null | while read -r f; do
  file "$f" 2>/dev/null | grep -q 'ELF' || continue
  scan_bin "$f"
done | sort

hr "2. binaries inside backup tarballs"
for t in /var/backups/*/*.tar.gz /var/backups/*.tar.gz /root/*.tar.gz /home/ubuntu/*.tar.gz; do
  [ -f "$t" ] || continue
  d=$(mktemp -d); tar xzf "$t" -C "$d" 2>/dev/null
  find "$d" -type f -name 'stratum*' -perm -u+x 2>/dev/null | while read -r f; do
    file "$f" 2>/dev/null | grep -q 'ELF' || continue
    echo "  [$(basename "$t")]"; scan_bin "$f"
  done
  rm -rf "$d"
done

hr "3. SOURCE trees that mention ZCU (the code may outlive the binary)"
for root in /home/ubuntu /root /opt /var/stratum /usr/local/src; do
  [ -d "$root" ] || continue
  grep -rlEi 'ZCUAUXCOMMIT|zcu_submit_from_ltc_parent|scrypt_submitAuxBlock' "$root" \
    --include='*.cpp' --include='*.h' 2>/dev/null | sed 's/^/   NEW-design: /'
  grep -rlEi '"ZCU"|Zero Chill' "$root" \
    --include='*.cpp' --include='*.h' 2>/dev/null | sed 's/^/   zcu-aware:  /'
done | sort -u

hr "4. db.cpp submitauxblock allowlist (the OLD ZCU design)"
for f in $(grep -rl 'submitauxblock' /home/ubuntu /root --include='db.cpp' 2>/dev/null); do
  echo "   -- $f  ($(date -r "$f" '+%Y-%m-%d %H:%M'))"
  grep -n -B3 -A8 'submitauxblock' "$f" | sed 's/^/      /'
done

hr "5. TIMELINE -- what happened around 11-20 Jul"
echo "   -- mtimes of every stratum binary, oldest first:"
find / -xdev -type f -name 'stratum' -perm -u+x 2>/dev/null \
  -printf '%TY-%Tm-%Td %TH:%TM  %p\n' | sort | sed 's/^/      /'
echo "   -- dpkg/apt + shell history around the change window:"
ls -la /var/log/apt/history.log* 2>/dev/null | sed 's/^/      /'
zgrep -h -A3 '2026-07-1[0-9]\|2026-07-20' /var/log/apt/history.log* 2>/dev/null | head -40 | sed 's/^/      /'
for h in /root/.bash_history /home/ubuntu/.bash_history; do
  [ -f "$h" ] || continue
  echo "      -- $h: install/make/systemctl lines"
  grep -nE 'install .*stratum|make |systemctl (restart|stop) stratum|cp .*stratum' "$h" 2>/dev/null | tail -40 | sed 's/^/         /'
done

hr "6. ZCU evidence in the pool DB (when did it last actually work?)"
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MYT() { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '^mysql:'; }
MYT "SELECT height, category, FROM_UNIXTIME(time) t FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='ZCU' ORDER BY b.time DESC LIMIT 10" | sed 's/^/   /'
MYT "SELECT id,symbol,enable,visible,auto_ready,rpchost,rpcport,rpcencoding FROM coins WHERE symbol='ZCU'" | sed 's/^/   /'

hr "7. instance / load sanity (the 11 Jul theory: it was CPU + disk, not code)"
echo "   instance-type: $(curl -s -m 3 -H "X-aws-ec2-metadata-token: $(curl -s -m 3 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null)"
echo "   cores=$(nproc)  load=$(cut -d' ' -f1-3 /proc/loadavg)"
df -h / /var 2>/dev/null | sed 's/^/   /'
echo "   biggest logs:"
du -sh /var/stratum/*.log /var/stratum/logs 2>/dev/null | sort -rh | head -5 | sed 's/^/   /'

echo
echo "READ THE RESULT LIKE THIS:"
echo "  * any binary with aux>0 AND zcu>0 dated before 20 Jul  = the build that worked. Keep it."
echo "  * source tree with ZCU code but a stale binary          = recompile THAT tree, no GitHub port."
echo "  * nothing anywhere                                      = ZCU lived in config only; check section 6."
echo "zcu-archaeology $ARCH_VERSION done -- nothing was modified."
