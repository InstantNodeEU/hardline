#!/usr/bin/env bash
#
# Boots a cloud image in qemu, runs hardline in it and checks the result from
# the outside: the rollbacks when the connection drops, a full run, a reboot
# and --undo.
#
#   tests/vm.sh IMAGE-URL [NAME]
#
# Env: CACHE (image cache dir), DOCKER=1 (also test docker port filtering),
# KEEP=1 (leave the vm running), RATE (curl --limit-rate for the download).
# Needs qemu-system-x86_64 with kvm, qemu-img, python3, ssh, curl.

set -eEuo pipefail

url=$1
name=${2:-$(basename "$url")}
repo=$(cd "$(dirname "$0")/.." && pwd)
cache=${CACHE:-$HOME/.cache/hardline-vm}
work=$(mktemp -d)
base=$((20000 + RANDOM % 20000))
p22=$base p2222=$((base + 1)) p80=$((base + 2)) p8080=$((base + 3)) pseed=$((base + 4))
p8081=$((base + 5)) p8082=$((base + 6))
pids=()

say() { printf '\n\e[1m[%s] %s\e[0m\n' "$name" "$*"; }
fail() { printf '\n\e[31m[%s] FAIL: %s\e[0m\n' "$name" "$*" >&2; tail -n 30 "$work/console.log" >&2 || true; exit 1; }

cleanup() {
	if [[ -z ${KEEP:-} && -f $work/qemu.pid ]]; then
		kill "$(cat "$work/qemu.pid")" 2>/dev/null || true
	fi
	kill "${pids[@]}" 2>/dev/null || true
	[[ -n ${KEEP:-} ]] || rm -rf "$work"
}
trap cleanup EXIT
# anything that ends the test without a FAIL line says where it happened
trap 'printf "\n[%s] FAIL: exit %s at line %s: %s\n" "$name" "$?" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ------------------------------------------------------------------ image

mkdir -p "$cache"
img=$cache/${url##*/}
if [[ ! -s $img ]]; then
	say "downloading $url"
	curl -fsSL --retry 3 --speed-limit 1024 --speed-time 60 ${RATE:+--limit-rate "$RATE"} -o "$img.part" "$url"
	mv "$img.part" "$img"
fi
qemu-img create -q -f qcow2 -F qcow2 -b "$img" "$work/disk.qcow2" 12G

ssh-keygen -q -t ed25519 -N '' -C hardline-test -f "$work/key"
pub=$(cat "$work/key.pub")
mkdir "$work/seed"
printf 'instance-id: hardline-%s\nlocal-hostname: hardline-test\n' "$RANDOM" >"$work/seed/meta-data"
cat >"$work/seed/user-data" <<EOF
#cloud-config
disable_root: false
ssh_pwauth: true
users: []
ssh_authorized_keys:
  - $pub
chpasswd:
  expire: false
  users:
    - {name: root, password: hardline-test-pw, type: text}
runcmd:
  - [sh, -c, "command -v apk >/dev/null && apk add -q bash python3"]
EOF
python3 -m http.server --bind 127.0.0.1 --directory "$work/seed" "$pseed" >/dev/null 2>&1 &
pids+=($!)

# nocloud-net, not nocloud: cloud-init 22.4 (Debian 12) only knows the old name
boot() {
	qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 \
		-drive file="$work/disk.qcow2",if=virtio \
		-netdev user,id=n0,hostfwd=tcp:127.0.0.1:$p22-:22,hostfwd=tcp:127.0.0.1:$p2222-:2222,hostfwd=tcp:127.0.0.1:$p80-:80,hostfwd=tcp:127.0.0.1:$p8080-:8080,hostfwd=tcp:127.0.0.1:$p8081-:8081,hostfwd=tcp:127.0.0.1:$p8082-:8082 \
		-device virtio-net-pci,netdev=n0 \
		-smbios "type=1,serial=ds=nocloud-net;s=http://10.0.2.2:$pseed/" \
		-display none -serial "file:$work/console.log" \
		-daemonize -pidfile "$work/qemu.pid"
}

# ------------------------------------------------------------------ ssh

opts=(-i "$work/key" -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
# reuse one connection per user and port, the firewall rate limits new ones
mux=(-o ControlMaster=auto -o "ControlPath=$work/cm-%r-%p" -o ControlPersist=120)

# on PORT USER CMD... runs a command in the vm
on() {
	local port=$1 user=$2
	shift 2
	ssh "${opts[@]}" "${mux[@]}" -p "$port" "$user@127.0.0.1" "$@"
}
# can_login PORT USER: a fresh connection, no multiplexing
can_login() {
	ssh "${opts[@]}" -o ControlPath=none -p "$1" "$2@127.0.0.1" true 2>/dev/null
}
forget() { ssh "${opts[@]}" -o "ControlPath=$work/cm-%r-%p" -O exit -p "$1" "$2@127.0.0.1" 2>/dev/null || true; }

wait_login() {
	local port=$1 user=$2 _
	for _ in $(seq 1 90); do
		can_login "$port" "$user" && return 0
		sleep 5
	done
	fail "no ssh login as $user on port $port"
}

http_ok() {
	[[ $(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$1/") =~ ^[2-4] ]]
}
# python takes a few seconds to start on a cold, niced vm
wait_http() {
	local _
	for _ in $(seq 30); do http_ok "$1" && return 0; sleep 1; done
	return 1
}

# audit_clean PORT USER WHEN: --audit must find nothing open. Services like
# fail2ban can take a while after a boot, so it gets a minute.
audit_clean() {
	local _
	for _ in $(seq 12); do
		on "$1" "$2" 'sudo bash /root/hardline.sh --audit' >"$work/audit.txt" && return 0
		sleep 5
	done
	cat "$work/audit.txt"
	on "$1" "$2" 'sudo sh -c "systemctl status fail2ban --no-pager 2>/dev/null || { rc-service fail2ban status; grep -v \"^ *$\" /var/log/rc.log | tail -n 60; }; tail -n 20 /var/log/fail2ban.log; grep -n -E \"rc-update|fail2ban|apk\" /var/log/hardline.log | tail -n 40"' || true
	fail "audit $3 finds something open"
}

hl() { # hl ARGS... runs hardline as root, interactive answers via drive.py
	python3 "$repo/tests/drive.py" "$@"
}

# ------------------------------------------------------------------ tests

say "booting (host clock $(date -u '+%F %T') UTC)"
boot
wait_login "$p22" root
on "$p22" root 'cloud-init status --wait >/dev/null 2>&1 || true'
# alpine installs bash and python3 (for the test web servers) from runcmd
on "$p22" root 'for _ in $(seq 60); do command -v bash && command -v python3 && exit 0; sleep 2; done; exit 1' >/dev/null ||
	fail "bash or python3 missing in the image"
on "$p22" root 'cat >/root/hardline.sh && chmod 700 /root/hardline.sh' <"$repo/hardline.sh"
on "$p22" root 'grep PRETTY_NAME /etc/os-release'

say "audit is read-only and exits 2 while things are open"
rc=0
on "$p22" root 'bash /root/hardline.sh --json' >"$work/audit.json" || rc=$?
[[ $rc = 2 ]] || fail "--json exit code $rc, wanted 2"
python3 -m json.tool "$work/audit.json" >/dev/null || fail "--json is not valid JSON"
python3 - "$work/audit.json" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1]))["checks"]
for k, v in c.items():
    print(f"  {k:15} {v['state']:5} {v['value']}")
EOF
on "$p22" root 'test ! -e /var/log/hardline.log' || fail "--audit wrote a log file"
# images that come with ufw/firewalld running get those configured instead
fw=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["checks"]["firewall"]["value"])' "$work/audit.json")

if [[ $fw = none ]]; then

say "firewall rolls back when the connection dies"
hl 'Start hardening\?=y' 'ports to allow=' 'Use ufw instead=n' 'Filter docker=y' 'Set up nftables=y' \
	'Still able to connect\?=KILL' -- \
	ssh -tt "${opts[@]}" -o ControlPath=none -p "$p22" root@127.0.0.1 \
	'bash /root/hardline.sh --skip user,ssh,bruteforce,updates,swap,extras'
on "$p22" root 'nft list table inet hardline >/dev/null' || fail "firewall was not applied"
sleep 70
on "$p22" root '! nft list table inet hardline >/dev/null 2>&1' || fail "firewall still there after the deadman timer"
on "$p22" root 'test ! -e /etc/hardline/firewall.nft' || fail "unconfirmed rules were saved"
else
	say "skipping the nftables rollback test, the image runs $fw"
fi

say "ssh rolls back when the connection dies"
hl 'Start hardening\?=y' 'SSH port \[=2222' 'Limit ssh logins=n' 'Apply SSH settings\?=y' \
	'Did the new login work\?=KILL' -- \
	ssh -tt "${opts[@]}" -o ControlPath=none -p "$p22" root@127.0.0.1 \
	'bash /root/hardline.sh --skip user,firewall,bruteforce,updates,swap,extras'
wait_login "$p2222" root
sleep 70
can_login "$p22" root || fail "port 22 not back after the deadman timer"
can_login "$p2222" root && fail "sshd still on 2222 after the deadman timer"
on "$p22" root 'test ! -e /etc/ssh/sshd_config.d/00-hardline.conf' || fail "00-hardline.conf still there"

if [[ ${DOCKER:-} = 1 ]]; then
	say "installing docker with two published ports"
	on "$p22" root 'DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker.io >/dev/null &&
		docker run -d --rm -p 8081:80 busybox httpd -f -p 80 >/dev/null &&
		docker run -d --rm -p 8082:80 busybox httpd -f -p 80 >/dev/null'
	wait_http "$p8081" || fail "docker port 8081 not reachable before hardening"
fi

say "full run"
# test only: lets the checks below use sudo as deploy
on "$p22" root 'mkdir -p /etc/sudoers.d; echo "deploy ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/zz-hardline-test; chmod 440 /etc/sudoers.d/zz-hardline-test'
on "$p22" root 'for p in 80 8080; do setsid python3 -m http.server $p --directory /tmp >/dev/null 2>&1 </dev/null & done; sleep 1'
wait_http "$p8080" || fail "test server on 8080 not reachable before hardening"
wait_http "$p80" || fail "test server on 80 not reachable before hardening"
flags="--yes --user deploy --key '$pub' --ssh-port 2222 --allow 80,8082 --ssh-groups --timezone Europe/Berlin --swap 512M"
[[ ${DOCKER:-} = 1 ]] && flags+=" --docker"
on "$p22" root "bash /root/hardline.sh $flags" || fail "full run failed"
forget "$p22" root

say "checking from outside"
wait_login "$p2222" deploy
can_login "$p2222" root && fail "root can still log in"
can_login "$p22" deploy && fail "port 22 still open"
http_ok "$p80" || fail "allowed port 80 is closed"
http_ok "$p8080" && fail "port 8080 is reachable through the firewall"
if [[ ${DOCKER:-} = 1 ]]; then
	http_ok "$p8082" || fail "allowed docker port 8082 is closed"
	http_ok "$p8081" && fail "docker port 8081 is reachable through the firewall"
fi
on "$p2222" deploy 'sudo sshd -T' >"$work/sshd-all.txt" || fail "sudo sshd -T as deploy failed"
# OpenSSH 10.6 prints the keys in CamelCase
grep -iE '^(port|permitrootlogin|passwordauthentication|allowgroups|kexalgorithms|macs) ' "$work/sshd-all.txt" | tee "$work/sshd.txt"
grep -qix 'passwordauthentication no' "$work/sshd.txt" || fail "password login still on"
if ! on "$p2222" deploy 'test -e /etc/crypto-policies/back-ends/opensshserver.config'; then
	grep -i kexalgorithms "$work/sshd.txt" | grep -q nistp && fail "nistp kex still offered"
fi
audit_clean "$p2222" deploy "after the run"

say "second run changes nothing"
on "$p2222" deploy 'sudo cat /etc/hardline/manifest' >"$work/m1"
on "$p2222" deploy "sudo bash /root/hardline.sh $flags" >"$work/run2.txt" || { cat "$work/run2.txt"; fail "second run failed"; }
on "$p2222" deploy 'sudo cat /etc/hardline/manifest' >"$work/m2"
diff "$work/m1" "$work/m2" || { grep -a 'changed files' -A 20 "$work/run2.txt"; fail "second run rewrote files"; }

say "reboot"
# test only: keep OpenRC's boot output for the diagnostics below. Without it
# fail2ban didn't come up after the reboot on Alpine in CI (4 of 4 runs, never
# locally) and nothing was logged; with it, it does. Cause not found yet.
on "$p2222" deploy 'test ! -f /etc/rc.conf || echo rc_logger=YES | sudo tee -a /etc/rc.conf >/dev/null'
on "$p2222" deploy 'sudo reboot' || true
forget "$p2222" deploy
sleep 10
wait_login "$p2222" deploy
can_login "$p22" deploy && fail "port 22 open after reboot"
if [[ $fw = none ]]; then
	on "$p2222" deploy 'sudo nft list table inet hardline >/dev/null' || fail "nft table missing after reboot"
fi
on "$p2222" deploy 'test "$(awk "/SwapTotal/ {print \$2}" /proc/meminfo)" -gt 0' || fail "no swap after reboot"
audit_clean "$p2222" deploy "after reboot"

say "undo"
on "$p2222" deploy 'sudo bash /root/hardline.sh --undo --yes' || fail "--undo failed"
forget "$p2222" deploy
wait_login "$p22" root
on "$p22" root '! nft list table inet hardline >/dev/null 2>&1' || fail "nft table still there after undo"
on "$p22" root 'test ! -e /etc/ssh/sshd_config.d/00-hardline.conf' || fail "ssh config still there after undo"
on "$p22" root 'sshd -T | grep -qix "passwordauthentication yes"' || fail "password login not restored"
on "$p22" root '! { systemctl is-active -q fail2ban 2>/dev/null || rc-service fail2ban status >/dev/null 2>&1; }' ||
	fail "fail2ban still running after undo"

say "all good"
