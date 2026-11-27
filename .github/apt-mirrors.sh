#!/bin/sh
# Gives apt on Ubuntu a fallback list of mirrors through mirror+file:, so a
# host that fails or stalls moves apt on to the next one instead of failing
# the job: the Azure mirror GitHub's runners use, Ubuntu's own host, and an
# independent mirror. The priorities keep apt on the first that works;
# without them apt spreads files across all three, and an index from one
# mirror with package lists from another that is mid-sync hung apt-get
# update for 30 minutes. The archive and security pockets both come from
# the list, and apt retries each file. Runs as root, on a runner or in a
# container; on Debian it sets only the retries, and without apt it does
# nothing.
#
# apt starts every file at the first mirror again, so a first mirror that
# has stopped answering costs the timeout on each of a hundred files: the
# Azure mirror did that on 23 Nov and ran linux-smoke jobs to their
# 30-minute cap (KAP-316). So each mirror is timed fetching its release
# file first, and the list puts the ones that answered first, fastest
# first, and the rest after them in their usual order.
set -eu

[ -d /etc/apt/apt.conf.d ] || exit 0
cat > /etc/apt/apt.conf.d/80-retries <<'EOF'
Acquire::Retries "5";
Acquire::http::Timeout "10";
EOF

grep -qi '^ID=ubuntu' /etc/os-release || exit 0
case "$(dpkg --print-architecture)" in
  amd64 | i386)
    set -- http://azure.archive.ubuntu.com/ubuntu/ http://archive.ubuntu.com/ubuntu/ \
      http://mirrors.edge.kernel.org/ubuntu/ ;;
  *)
    set -- http://azure.ports.ubuntu.com/ubuntu-ports/ http://ports.ubuntu.com/ubuntu-ports/ \
      http://mirrors.mit.edu/ubuntu-ports/ ;;
esac

codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
probe=$(mktemp -d)
chmod 777 "$probe"
answered='' silent=''
for uri; do
  start=$(date +%s%N)
  if timeout 15 /usr/lib/apt/apt-helper -o Acquire::Retries=0 download-file \
    "${uri}dists/$codename/InRelease" "$probe/InRelease" >/dev/null 2>&1; then
    ms=$((($(date +%s%N) - start) / 1000000))
    echo "apt-mirrors.sh: $uri answered in $ms ms" >&2
    answered="$answered$ms $uri
"
  else
    echo "apt-mirrors.sh: $uri did not answer within 15 s; it goes last" >&2
    silent="$silent$uri
"
  fi
  rm -f "$probe/InRelease"
done
rm -rf "$probe"

printf '%s' "$answered" | sort -n | cut -d' ' -f2 | { cat; printf '%s' "$silent"; } |
  awk 'NF { printf "%s\tpriority:%d\n", $1, NR }' > /etc/apt/apt-mirrors.txt

for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  [ -f "$f" ] || continue
  sed -i -E 's#https?://([a-z0-9-]+\.)*(archive|security|ports)\.ubuntu\.com/ubuntu(-ports)?/?#mirror+file:/etc/apt/apt-mirrors.txt#g' "$f"
done

if grep -rhoE '([a-z0-9-]+\.)*(archive|security|ports)\.ubuntu\.com' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -q .; then
  echo "apt-mirrors.sh: a source still names an Ubuntu host directly" >&2
  exit 1
fi
