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
set -eu

[ -d /etc/apt/apt.conf.d ] || exit 0
cat > /etc/apt/apt.conf.d/80-retries <<'EOF'
Acquire::Retries "5";
Acquire::http::Timeout "30";
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
i=0
for uri; do
  i=$((i + 1))
  printf '%s\tpriority:%d\n' "$uri" "$i"
done > /etc/apt/apt-mirrors.txt

for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  [ -f "$f" ] || continue
  sed -i -E 's#https?://([a-z0-9-]+\.)*(archive|security|ports)\.ubuntu\.com/ubuntu(-ports)?/?#mirror+file:/etc/apt/apt-mirrors.txt#g' "$f"
done

if grep -rhoE '([a-z0-9-]+\.)*(archive|security|ports)\.ubuntu\.com' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -q .; then
  echo "apt-mirrors.sh: a source still names an Ubuntu host directly" >&2
  exit 1
fi
