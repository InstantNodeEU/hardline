#!/usr/bin/env bash
#
# hardline - harden a fresh VPS in one interactive pass
#
# Copyright (c) 2026 luxend / InstantNode
# MIT license, see LICENSE

set -euo pipefail
# with pipefail, a reader that stops early (grep -q, awk exit, head) can kill
# the writer with SIGPIPE and fail the whole pipeline, so pipelines here read
# their input to the end and simple checks use [[ ]] instead

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

HARDLINE_VERSION=0.2.0
LOGFILE=/var/log/hardline.log
REPORT=/root/hardline-report-$(date +%Y%m%d-%H%M).txt
NFT_RULES=/etc/hardline/firewall.nft
MANIFEST=/etc/hardline/manifest
DEADMAN_SECS=60

ASSUME_YES=0
DRY_RUN=0
AUDIT_ONLY=0
JSON=0
UNDO=0
OPT_USER=""
OPT_GITHUB=""
OPT_KEY=""
OPT_COPY_ROOT_KEYS=0
OPT_SSH_PORT=""
OPT_ALLOW=""
OPT_BRUTE=""
OPT_UPDATES=1
OPT_SWAP=""
OPT_TZ=""
OPT_DOCKER=0
OPT_SSH_GROUPS=0
SKIP=","

FAMILY=""
INIT=""
OS_ID=""
OS_NAME=""
SSH_PORT=22
ADMIN_USER=""
GENERATED_PW=""
PKG_UPDATED=0
CHANGED=()
NOTES=()
OURS=()
declare -A BEFORE=() AFTER=()

KEY_RE='(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) [A-Za-z0-9+/]+=*'

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
	c_red=$'\e[31m' c_grn=$'\e[32m' c_yel=$'\e[33m' c_dim=$'\e[2m' c_bold=$'\e[1m' c_off=$'\e[0m'
else
	c_red="" c_grn="" c_yel="" c_dim="" c_bold="" c_off=""
fi

log() {
	[[ $DRY_RUN = 1 || $AUDIT_ONLY = 1 ]] && return 0
	printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOGFILE"
}
say()  { printf '%s\n' "$*"; log "$*"; }
ok()   { printf '  %s[ok]%s %s\n' "$c_grn" "$c_off" "$*"; log "ok: $*"; }
warn() { printf '  %s[warn]%s %s\n' "$c_yel" "$c_off" "$*" >&2; log "warn: $*"; }
die()  { printf '%s[error]%s %s\n' "$c_red" "$c_off" "$*" >&2; log "error: $*"; exit 1; }
step() { printf '\n%s== %s ==%s\n' "$c_bold" "$*" "$c_off"; log "== $*"; }
note() { NOTES+=("$*"); }

run() {
	if [[ $DRY_RUN = 1 ]]; then
		printf '  %s[dry-run]%s %s\n' "$c_dim" "$c_off" "$*"
		return 0
	fi
	log "+ $*"
	if ! "$@" >>"$LOGFILE" 2>&1; then
		warn "failed: $* (see $LOGFILE)"
		return 1
	fi
}

ask() {
	local q=$1 def=${2:-n} hint ans
	if [[ $ASSUME_YES = 1 ]]; then
		[[ $def = y ]]
		return
	fi
	[[ $def = y ]] && hint="[Y/n]" || hint="[y/N]"
	while true; do
		printf '%s %s ' "$q" "$hint" >/dev/tty
		read -r ans </dev/tty || ans=""
		case ${ans,,} in
			"") [[ $def = y ]]; return ;;
			y|yes) return 0 ;;
			n|no) return 1 ;;
		esac
	done
}

prompt() {
	local q=$1 def=${2:-} ans
	if [[ $ASSUME_YES = 1 ]]; then
		printf '%s' "$def"
		return
	fi
	if [[ -n $def ]]; then
		printf '%s [%s]: ' "$q" "$def" >/dev/tty
	else
		printf '%s: ' "$q" >/dev/tty
	fi
	read -r ans </dev/tty || ans=""
	printf '%s' "${ans:-$def}"
}

backup() {
	[[ -e $1 && ! -e $1.hardline.bak ]] || return 0
	run cp -a "$1" "$1.hardline.bak"
}

# put_file PATH [MODE] < content. Leaves the file alone if nothing changed.
put_file() {
	local path=$1 mode=${2:-644} content
	content=$(cat)
	if [[ -f $path && "$(cat "$path")" == "$content" ]]; then
		return 0
	fi
	if [[ $DRY_RUN = 1 ]]; then
		printf '  %s[dry-run]%s write %s\n' "$c_dim" "$c_off" "$path"
		printf '%s\n' "$content" | sed "s/^/      ${c_dim}/; s/\$/${c_off}/"
		return 0
	fi
	local kind=new
	[[ -e $path ]] && kind=edit
	backup "$path"
	mkdir -p "$(dirname "$path")"
	printf '%s\n' "$content" >"$path"
	chmod "$mode" "$path"
	CHANGED+=("$path")
	remember "$kind" "$path"
	log "wrote $path"
}

# remember new|edit|svc PATH-OR-SERVICE. The manifest tells --undo what we
# created, what we edited (original in .hardline.bak) and which services we
# turned on. The checksum shows whether someone changed a file after us.
remember() {
	[[ $DRY_RUN = 1 ]] && return 0
	local kind=$1 what=$2 sum=- old
	[[ -f $what ]] && sum=$(sha256sum "$what" | cut -d' ' -f1)
	mkdir -p "${MANIFEST%/*}"
	old=$(awk -v w="$what" '$3 == w {print $1}' "$MANIFEST" 2>/dev/null)
	# a file we created stays ours even when a later run rewrites it
	[[ $old = new ]] && kind=new
	# replace the entry in place, so an unchanged file leaves the manifest alone
	{ cat "$MANIFEST" 2>/dev/null || true; } | awk -v w="$what" -v l="$kind $sum $what" '
		$3 == w {print l; done = 1; next} {print} END {if (!done) print l}' >"$MANIFEST.tmp"
	mv "$MANIFEST.tmp" "$MANIFEST"
}

# deadman_arm NAME < shell script. Runs the script after DEADMAN_SECS unless
# deadman_confirm disarms it first. setsid moves the timer out of this
# session, so it still fires when the ssh connection dies and takes us along.
deadman_arm() {
	local f=/run/hardline-$1.undo
	cat >"$f"
	setsid sh -c "sleep $DEADMAN_SECS; [ -f $f ] && sh $f >>$LOGFILE 2>&1; rm -f $f" </dev/null >/dev/null 2>&1 &
}

# deadman_confirm NAME QUESTION. Yes keeps the change, anything else
# (including no answer) runs the rollback right away.
deadman_confirm() {
	local f=/run/hardline-$1.undo ans
	printf '%s (rolls back in %ss) [y/N] ' "$2" "$DEADMAN_SECS" >/dev/tty
	# a few seconds less than the timer, so a late yes can't race the rollback
	read -r -t $((DEADMAN_SECS - 5)) ans </dev/tty || { ans=""; echo >/dev/tty; }
	if [[ ${ans,,} == y* ]]; then
		rm -f "$f"
		return 0
	fi
	[[ -f $f ]] && sh "$f" >>"$LOGFILE" 2>&1
	rm -f "$f"
	return 1
}

join() {
	local IFS=, s
	s="$*"
	printf '%s' "${s//,/, }"
}

fetch() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --max-time 20 "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO- -T 20 "$1"
	else
		return 1
	fi
}

detect_os() {
	[[ -r /etc/os-release ]] || die "/etc/os-release not found, unsupported system"
	# shellcheck disable=SC1091
	. /etc/os-release
	OS_ID=${ID:-unknown}
	OS_NAME=${PRETTY_NAME:-$OS_ID}
	case " $OS_ID ${ID_LIKE:-} " in
		*" debian "*|*" ubuntu "*) FAMILY=debian ;;
		*" rhel "*|*" fedora "*|*" centos "*) FAMILY=rhel ;;
		*" arch "*) FAMILY=arch ;;
		*" alpine "*) FAMILY=alpine ;;
		*" suse "*|*" opensuse "*) FAMILY=suse ;;
		*) die "unsupported distribution: $OS_NAME" ;;
	esac

	if [[ -d /run/systemd/system ]]; then
		INIT=systemd
	elif command -v openrc >/dev/null 2>&1 && [[ -d /run/openrc ]]; then
		INIT=openrc
	else
		INIT=none
	fi
}

pkg_has() {
	case $FAMILY in
		debian) [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == *"ok installed"* ]] ;;
		rhel|suse) rpm -q "$1" >/dev/null 2>&1 ;;
		arch) pacman -Q "$1" >/dev/null 2>&1 ;;
		alpine) apk info -e "$1" >/dev/null 2>&1 ;;
	esac
}

pkg_refresh() {
	[[ $PKG_UPDATED = 1 ]] && return 0
	case $FAMILY in
		debian) run env DEBIAN_FRONTEND=noninteractive apt-get update -q ;;
		rhel) run dnf -q makecache ;;
		# partial upgrades are not supported on arch, so refreshing means upgrading
		arch) say "  arch can't install packages without a full upgrade, running pacman -Syu"
			run pacman -Syu --noconfirm ;;
		alpine) run apk update -q ;;
		suse) run zypper -n -q --gpg-auto-import-keys refresh ;;
	esac || return 1
	PKG_UPDATED=1
}

pkg_install() {
	local missing=() p
	for p in "$@"; do
		pkg_has "$p" || missing+=("$p")
	done
	[[ ${#missing[@]} = 0 ]] && return 0
	pkg_refresh || return 1
	say "  installing ${missing[*]}"
	case $FAMILY in
		debian) run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${missing[@]}" ;;
		rhel) run dnf install -y -q "${missing[@]}" ;;
		arch) run pacman -S --needed --noconfirm "${missing[@]}" ;;
		alpine) run apk add -q "${missing[@]}" ;;
		suse) run zypper -n -q install "${missing[@]}" ;;
	esac
}

# svc enable|restart|reload|is-active NAME
svc() {
	local action=$1 name=$2
	if [[ $action = enable && $INIT != none ]]; then
		if [[ " ${OURS[*]} " == *" $name "* ]] || ! svc is-enabled "$name"; then
			remember svc "$name"
		fi
	fi
	case $INIT in
		systemd)
			case $action in
				enable) run systemctl enable --now "$name" ;;
				disable) run systemctl disable --now "$name" ;;
				is-enabled) systemctl is-enabled --quiet "$name" 2>/dev/null ;;
				is-active) systemctl is-active --quiet "$name" 2>/dev/null ;;
				*) run systemctl "$action" "$name" ;;
			esac
			;;
		openrc)
			case $action in
				enable) run rc-update add "$name" default && run rc-service "$name" restart ;;
				disable) run rc-service "$name" stop; run rc-update del "$name" default ;;
				is-enabled) [[ $(rc-update show default 2>/dev/null) =~ (^|[[:space:]])${name}[[:space:]] ]] ;;
				is-active) rc-service "$name" status >/dev/null 2>&1 ;;
				*) run rc-service "$name" "$action" ;;
			esac
			;;
		none)
			[[ $action = is-* ]] && return 1
			warn "no init system, skipping $action $name"
			;;
	esac
}

# ours SERVICE...: remember services that are off now. Debian's packages
# enable their service during install, so asking after pkg_install is too late.
ours() {
	local s
	for s in "$@"; do
		svc is-enabled "$s" || OURS+=("$s")
	done
}

user_home() { awk -F: -v u="$1" '$1 == u {print $6}' /etc/passwd; }
user_exists() { [[ -n $(user_home "$1") ]]; }

sudo_group() {
	if [[ $FAMILY = debian ]]; then echo sudo; else echo wheel; fi
}

sudo_users() {
	awk -F: -v g="$(sudo_group)" '$1 == g {gsub(",", " ", $4); print $4}' /etc/group
}

user_has_key() {
	local home
	home=$(user_home "$1")
	[[ -n $home ]] || return 1
	grep -qsE "^$KEY_RE" "$home/.ssh/authorized_keys"
}

server_ip() {
	local ip=""
	if command -v ip >/dev/null 2>&1; then
		ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}') || true
	fi
	printf '%s' "${ip:-<server-ip>}"
}

# ---------------------------------------------------------------- audit

listening_ports() {
	{
		if command -v ss >/dev/null 2>&1; then
			ss -Htuln 2>/dev/null | awk '{print $1, $5}'
		elif command -v netstat >/dev/null 2>&1; then
			netstat -tuln 2>/dev/null | awk '$1 ~ /^(tcp|udp)/ {print $1, $4}'
		fi
	} | awk '{
		n = split($2, a, ":"); port = a[n]
		addr = substr($2, 1, length($2) - length(port) - 1)
		proto = $1; sub(/6$/, "", proto)
		if (addr ~ /^(127\.|\[::1\]|::1$)/ || addr ~ /%lo$/) next
		print port "/" proto
	}' | sort -u | sort -t/ -k1,1n | paste -sd' ' - || true
}

sshd_grep() {
	local key=${1,,} f v files=()
	if [[ -d /etc/ssh/sshd_config.d ]]; then
		files+=(/etc/ssh/sshd_config.d/*.conf)
	fi
	files+=(/etc/ssh/sshd_config)
	for f in "${files[@]}"; do
		[[ -r $f ]] || continue
		v=$(awk -v k="$key" '
			/^[[:space:]]*#/ {next}
			tolower($1) == "match" {exit}
			tolower($1) == k {print $2; exit}' "$f")
		if [[ -n $v ]]; then
			printf '%s' "${v,,}"
			return
		fi
	done
}

sshd_value() {
	local key=$1 v=""
	command -v sshd >/dev/null 2>&1 || { printf 'n/a'; return; }
	# OpenSSH 10.6 prints the keys in CamelCase, older versions in lowercase
	v=$(sshd -T 2>/dev/null | awk -v k="${key,,}" 'tolower($1) == k && !v {v = $2} END {print v}') || true
	v=${v,,}
	[[ -n $v ]] || v=$(sshd_grep "$key")
	if [[ -z $v ]]; then
		case ${key,,} in
			permitrootlogin) v=prohibit-password ;;
			passwordauthentication) v=yes ;;
			port) v=22 ;;
		esac
	fi
	printf '%s' "$v"
}

login_users() {
	awk -F: '$7 !~ /(nologin|false|sync|shutdown|halt)$/ && ($3 == 0 || ($3 >= 1000 && $3 != 65534)) {print $1}' /etc/passwd | paste -sd' ' -
}

empty_pw_users() {
	{ awk -F: '$2 == "" {print $1}' /etc/shadow 2>/dev/null || true; } | paste -sd' ' -
}

nopasswd_sudo() {
	{ grep -rhsE '^[^#]*NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null || true; } | awk '{print $1}' | sort -u | paste -sd' ' -
}

firewall_state() {
	if command -v nft >/dev/null 2>&1 && nft list table inet hardline >/dev/null 2>&1; then
		echo nftables
	elif command -v ufw >/dev/null 2>&1 && [[ $(ufw status 2>/dev/null) == *"Status: active"* ]]; then
		echo ufw
	elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		echo firewalld
	elif command -v nft >/dev/null 2>&1 && nft list chains 2>/dev/null | awk '/hook input.*policy drop/ {n++} END {exit !n}'; then
		echo nftables
	elif command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | awk '/^-P INPUT (DROP|REJECT)/ {n++} END {exit !n}'; then
		echo iptables
	else
		echo none
	fi
}

pending_updates() {
	local n="?"
	case $FAMILY in
		debian) n=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true) ;;
		rhel) n=$(dnf -q check-update 2>/dev/null | grep -cE '^[^[:space:]]+\.[^[:space:]]+[[:space:]]' || true) ;;
		arch) command -v checkupdates >/dev/null 2>&1 && n=$(checkupdates 2>/dev/null | wc -l) ;;
		alpine) n=$(apk version -l '<' 2>/dev/null | tail -n +2 | wc -l) ;;
		suse) n=$(zypper -q lu 2>/dev/null | grep -c '^v ' || true) ;;
	esac
	printf '%s' "${n// /}"
}

swap_mb() { awk '/^SwapTotal:/ {print int($2 / 1024)}' /proc/meminfo; }
ram_mb() { awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo; }

timer_enabled() {
	command -v systemctl >/dev/null 2>&1 && systemctl is-enabled --quiet "$1" 2>/dev/null
}

autoupdates_state() {
	case $FAMILY in
		debian)
			if pkg_has unattended-upgrades && grep -qsE 'Unattended-Upgrade[[:space:]]+"1"' /etc/apt/apt.conf.d/*; then
				echo on
			else
				echo off
			fi
			;;
		rhel)
			if timer_enabled dnf-automatic-install.timer || timer_enabled dnf-automatic.timer || timer_enabled dnf5-automatic.timer; then
				echo on
			else
				echo off
			fi
			;;
		alpine)
			if [[ -x /etc/periodic/daily/hardline-apk-upgrade ]]; then echo on; else echo off; fi
			;;
		*) echo n/a ;;
	esac
}

bruteforce_state() {
	local s=""
	if svc is-active fail2ban || pgrep -f fail2ban-server >/dev/null 2>&1; then s+="fail2ban "; fi
	if svc is-active crowdsec || pgrep -x crowdsec >/dev/null 2>&1; then s+="crowdsec "; fi
	s=${s% }
	printf '%s' "${s:-none}"
}

# Ports docker publishes on all addresses, e.g. "5432/tcp 8080/tcp". They go
# through DNAT and the forward path, so an input firewall never sees them.
docker_ports() {
	command -v docker >/dev/null 2>&1 || return 1
	docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' |
		sed -nE 's/^ *(0\.0\.0\.0|\[::\]|::):([0-9]+(-[0-9]+)?)->[^/]+\/(tcp|udp)$/\2\/\4/p' |
		sort -u | sort -t/ -k1,1n | paste -sd' ' -
}

docker_state() {
	local p
	p=$(docker_ports) || { echo n/a; return; }
	if [[ -z $p ]]; then
		echo none
	elif command -v nft >/dev/null 2>&1 && nft list chain inet hardline docker >/dev/null 2>&1; then
		echo "filtered $p"
	else
		echo "$p"
	fi
}

# yes when a newer kernel or core library is installed than the one running
reboot_state() {
	local newest
	if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -cq; then
		echo n/a    # containers share the host kernel
	elif [[ -f /var/run/reboot-required ]]; then
		echo yes
	elif command -v needs-restarting >/dev/null 2>&1; then
		if needs-restarting -r >/dev/null 2>&1; then echo no; else echo yes; fi
	elif [[ -d /lib/modules ]]; then
		newest=$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n1)
		if [[ -z $newest ]]; then echo n/a    # container, no own kernel
		elif [[ $newest != "$(uname -r)" ]]; then echo yes
		else echo no
		fi
	else
		echo n/a
	fi
}

audit() {
	local -n out=$1
	out["ports"]=$(listening_ports)
	out["ports"]=${out["ports"]:-none}
	out["ssh_port"]=$(sshd_value Port)
	out["root_login"]=$(sshd_value PermitRootLogin)
	out["password_auth"]=$(sshd_value PasswordAuthentication)
	out["login_users"]=$(login_users)
	out["empty_pw"]=$(empty_pw_users)
	out["empty_pw"]=${out["empty_pw"]:-none}
	out["nopasswd"]=$(nopasswd_sudo)
	out["nopasswd"]=${out["nopasswd"]:-none}
	out["firewall"]=$(firewall_state)
	out["updates"]=$(pending_updates)
	out["swap"]="$(swap_mb) MB"
	out["autoupdates"]=$(autoupdates_state)
	out["bruteforce"]=$(bruteforce_state)
	out["docker"]=$(docker_state)
	out["reboot"]=$(reboot_state)
}

AUDIT_KEYS=(ports ssh_port root_login password_auth login_users empty_pw nopasswd firewall docker bruteforce updates autoupdates reboot swap)
declare -A LABEL=(
	[ports]="listening ports"
	[ssh_port]="ssh port"
	[root_login]="root login"
	[password_auth]="password login"
	[login_users]="users with a shell"
	[empty_pw]="empty passwords"
	[nopasswd]="sudo without password"
	[firewall]="firewall"
	[docker]="docker published ports"
	[reboot]="reboot needed"
	[bruteforce]="brute force protection"
	[updates]="pending updates"
	[autoupdates]="automatic updates"
	[swap]="swap"
)

# ok, warn, open or info
judge() {
	local key=$1 v=$2
	case $key in
		root_login)
			case $v in no) echo ok ;; prohibit-password|without-password|forced-commands-only) echo warn ;; n/a) echo info ;; *) echo open ;; esac ;;
		password_auth)
			case $v in no) echo ok ;; n/a) echo info ;; *) echo open ;; esac ;;
		empty_pw)
			[[ $v = none ]] && echo ok || echo open ;;
		bruteforce|firewall)
			[[ $v = none ]] && echo open || echo ok ;;
		nopasswd)
			[[ $v = none ]] && echo ok || echo warn ;;
		docker)
			case $v in none|filtered*) echo ok ;; n/a) echo info ;; *) echo warn ;; esac ;;
		reboot)
			case $v in no) echo ok ;; yes) echo warn ;; *) echo info ;; esac ;;
		updates)
			case $v in 0) echo ok ;; "?") echo info ;; *) echo warn ;; esac ;;
		autoupdates)
			case $v in on) echo ok ;; off) echo open ;; *) echo info ;; esac ;;
		swap)
			[[ $v = "0 MB" ]] && echo warn || echo ok ;;
		*) echo info ;;
	esac
}

paint() {
	case $1 in
		ok|fixed) printf '%s%s%s' "$c_grn" "$1" "$c_off" ;;
		warn) printf '%s%s%s' "$c_yel" "$1" "$c_off" ;;
		open) printf '%s%s%s' "$c_red" "$1" "$c_off" ;;
		*) printf '%s' "$1" ;;
	esac
}

short() {
	local s=$1 max=${2:-26}
	if (( ${#s} > max )); then
		printf '%s...' "${s:0:max-3}"
	else
		printf '%s' "$s"
	fi
}

print_audit() {
	local -n a=$1
	local k st
	for k in "${AUDIT_KEYS[@]}"; do
		st=$(judge "$k" "${a[$k]}")
		printf '  %-24s %-30s %s\n' "${LABEL[$k]}" "$(short "${a[$k]}" 30)" "$(paint "$st")"
	done
}

# ---------------------------------------------------------------- admin user

# add_keys USER < lines. Strips options like command="..." that cloud
# images put in front of root's keys.
add_keys() {
	local user=$1 home file line key added=0 known=0
	home=$(user_home "$user")
	file=$home/.ssh/authorized_keys
	while IFS= read -r line; do
		key=$(grep -oE "$KEY_RE( .*)?\$" <<<"$line" || true)
		[[ -n $key ]] || continue
		if [[ -f $file ]] && grep -qF "$(cut -d' ' -f2 <<<"$key")" "$file"; then
			known=$((known + 1))
			continue
		fi
		added=$((added + 1))
		if [[ $DRY_RUN = 1 ]]; then
			printf '  %s[dry-run]%s add key %s\n' "$c_dim" "$c_off" "$(short "$key" 50)"
			continue
		fi
		mkdir -p "$home/.ssh"
		printf '%s\n' "$key" >>"$file"
	done
	if ((added == 0 && known > 0)); then
		ok "key already present for $user"
		return 0
	elif ((added == 0)); then
		warn "no valid public key found"
		return 1
	fi
	if [[ $DRY_RUN = 0 ]]; then
		chmod 700 "$home/.ssh"
		chmod 600 "$file"
		chown -R "$user:$(id -gn "$user")" "$home/.ssh"
		command -v restorecon >/dev/null 2>&1 && restorecon -R "$home/.ssh" 2>/dev/null
		CHANGED+=("$file")
	fi
	ok "$added key(s) added for $user"
}

import_github_keys() {
	local user=$1 gh=$2 keys
	[[ $gh =~ ^[A-Za-z0-9-]+$ ]] || { warn "not a valid github username: $gh"; return 1; }
	keys=$(fetch "https://github.com/$gh.keys") || { warn "could not fetch keys for $gh"; return 1; }
	[[ -n $keys ]] || { warn "github user $gh has no public keys"; return 1; }
	add_keys "$user" <<<"$keys"
}

pick_keys() {
	local user=$1 choice root_keys=0 k gh
	[[ -f /root/.ssh/authorized_keys ]] && root_keys=$(grep -cE "$KEY_RE" /root/.ssh/authorized_keys || true)
	while true; do
		echo "  Add an SSH key for $user:"
		echo "    1) paste a public key"
		echo "    2) import from a GitHub account"
		[[ $root_keys -gt 0 ]] && echo "    3) copy root's keys ($root_keys found)"
		echo "    s) skip"
		choice=$(prompt "  choice" "$([[ $root_keys -gt 0 ]] && echo 3 || echo 1)")
		case $choice in
			1) k=$(prompt "  public key"); add_keys "$user" <<<"$k" || true ;;
			2) gh=$(prompt "  GitHub username"); import_github_keys "$user" "$gh" || true ;;
			3) add_keys "$user" </root/.ssh/authorized_keys || true ;;
			s|S) return 0 ;;
			*) continue ;;
		esac
		ask "  Add another key?" n || return 0
	done
}

set_password() {
	local user=$1 shadow_pw
	shadow_pw=$(awk -F: -v u="$user" '$1 == u {print $2}' /etc/shadow 2>/dev/null)
	if [[ -n $shadow_pw && $shadow_pw != "!"* && $shadow_pw != "*"* ]]; then
		return 0
	fi
	[[ $DRY_RUN = 1 ]] && { printf '  %s[dry-run]%s set password for %s\n' "$c_dim" "$c_off" "$user"; return 0; }

	# sudo needs a password, and on alpine a locked account can't log in at all
	if [[ $ASSUME_YES = 0 ]] && ask "  Set a password for $user now? (no = generate one)" y; then
		local tries=0
		until passwd "$user" </dev/tty >/dev/tty 2>&1; do
			tries=$((tries + 1))
			((tries < 3)) || break
		done
		((tries < 3)) && return 0
	fi
	GENERATED_PW=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-20)
	printf '%s:%s\n' "$user" "$GENERATED_PW" | chpasswd
	log "generated password for $user"
	warn "generated password for $user: $GENERATED_PW (change it with passwd)"
}

enable_wheel() {
	[[ $FAMILY = debian || $FAMILY = rhel ]] && return 0
	grep -qsE '^[[:space:]]*%wheel[[:space:]]+ALL' /etc/sudoers /etc/sudoers.d/* && return 0
	put_file /etc/sudoers.d/10-hardline-wheel 440 < <(
		echo "%wheel ALL=(ALL:ALL) ALL"
		# openSUSE's sudo asks for root's password unless told otherwise
		[[ $FAMILY = suse ]] && echo "Defaults:%wheel !targetpw"
	)
	if [[ $DRY_RUN = 0 ]] && ! visudo -cf /etc/sudoers.d/10-hardline-wheel >/dev/null 2>&1; then
		rm -f /etc/sudoers.d/10-hardline-wheel
		warn "sudoers drop-in did not validate, removed it"
	fi
}

step_user() {
	step "Admin user"
	local name existing group shell
	existing=$(sudo_users)
	if [[ -n $OPT_USER ]]; then
		name=$OPT_USER
	elif [[ $ASSUME_YES = 1 ]]; then
		say "  no --user given, skipping"
		return 0
	else
		[[ -n $existing ]] && say "  existing sudo users: $existing"
		ask "Create or update a non-root admin user?" y || return 0
		name=$(prompt "  username" "${existing%% *}")
		name=${name:-admin}
	fi
	[[ $name =~ ^[a-z_][a-z0-9_-]{0,31}$ && $name != root ]] || { warn "invalid username: $name"; return 1; }

	group=$(sudo_group)
	shell=$(command -v bash)
	pkg_install sudo || return 1

	if user_exists "$name"; then
		say "  $name exists, making sure it is in $group"
		if [[ $FAMILY = alpine ]]; then
			[[ " $(id -nG "$name") " == *" $group "* ]] || run addgroup "$name" "$group"
		else
			run usermod -aG "$group" "$name"
		fi
	else
		if [[ $FAMILY = alpine ]]; then
			run adduser -D -s "$shell" "$name" && run addgroup "$name" "$group"
		else
			run useradd -m -s "$shell" -G "$group" "$name"
		fi || return 1
		ok "created user $name"
	fi
	enable_wheel
	ADMIN_USER=$name

	if [[ $DRY_RUN = 1 ]] && ! user_exists "$name"; then
		printf '  %s[dry-run]%s set password and add keys for %s\n' "$c_dim" "$c_off" "$name"
		return 0
	fi
	set_password "$name"

	[[ -n $OPT_KEY ]] && { add_keys "$name" <<<"$OPT_KEY" || true; }
	[[ -n $OPT_GITHUB ]] && { import_github_keys "$name" "$OPT_GITHUB" || true; }
	[[ $OPT_COPY_ROOT_KEYS = 1 && -f /root/.ssh/authorized_keys ]] && { add_keys "$name" </root/.ssh/authorized_keys || true; }
	if [[ $ASSUME_YES = 0 && -z $OPT_KEY$OPT_GITHUB && $OPT_COPY_ROOT_KEYS = 0 ]]; then
		pick_keys "$name"
	fi
	user_has_key "$name" || warn "$name has no SSH key yet, password login will stay on"
}

# ---------------------------------------------------------------- ssh

openssh_version() {
	ssh -V 2>&1 | sed -nE 's/^OpenSSH_([0-9]+)\.([0-9]+).*/\1\2/p'
}

ssh_service() {
	if [[ $INIT = systemd ]] && systemctl cat ssh.service >/dev/null 2>&1; then
		echo ssh
	else
		echo sshd
	fi
}

# Make sure the new port is reachable before sshd moves there.
fw_open_port() {
	local port=$1
	case $(firewall_state) in
		ufw) run ufw allow "$port/tcp" ;;
		firewalld) run firewall-cmd --permanent --add-port="$port/tcp" && run firewall-cmd --reload ;;
		nftables)
			if nft list table inet hardline >/dev/null 2>&1; then
				run nft add rule inet hardline input tcp dport "$port" accept
			else
				warn "nftables already filters input, make sure tcp/$port is allowed"
			fi
			;;
		iptables) run iptables -I INPUT -p tcp --dport "$port" -j ACCEPT ;;
	esac
}

selinux_ssh_port() {
	local port=$1
	command -v getenforce >/dev/null 2>&1 || return 0
	[[ $(getenforce 2>/dev/null) = Disabled ]] && return 0
	command -v semanage >/dev/null 2>&1 || pkg_install policycoreutils-python-utils || return 1
	run semanage port -a -t ssh_port_t -p tcp "$port" || run semanage port -m -t ssh_port_t -p tcp "$port"
}

# Shell commands that make sshd pick up a new config. Kept as text so the
# deadman rollback can run exactly the same thing on its own.
ssh_reload_cmds() {
	if [[ $INIT = systemd ]] && systemctl is-active --quiet ssh.socket 2>/dev/null; then
		# ubuntu 22.10+ socket activation takes the port from a generator
		echo "systemctl daemon-reload; systemctl restart ssh.socket; systemctl try-reload-or-restart ssh.service"
	elif [[ $INIT = systemd ]]; then
		echo "systemctl reload $(ssh_service) || systemctl restart $(ssh_service)"
	elif [[ $INIT = openrc ]]; then
		echo "rc-service sshd reload || rc-service sshd restart"
	fi
}

# Drops what is known to be weak and keeps everything else from the
# OpenSSH defaults, so any client from the last ~8 years still gets in.
ssh_crypto() {
	local ver=$1 pubkey=PubkeyAcceptedAlgorithms
	if [[ -e /etc/crypto-policies/back-ends/opensshserver.config ]]; then
		return 0    # RHEL and Fedora manage this with crypto-policies, leave it to them
	fi
	((ver < 85)) && pubkey=PubkeyAcceptedKeyTypes
	echo "KexAlgorithms -diffie-hellman-group1-sha1,diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1,ecdh-sha2-nistp*"
	echo "Ciphers -*-cbc"
	echo "MACs -hmac-md5*,hmac-sha1*,umac-64*"
	echo "HostKeyAlgorithms -ssh-rsa,ssh-rsa-cert-v01@openssh.com"
	echo "$pubkey -ssh-rsa,ssh-rsa-cert-v01@openssh.com"
}

add_to_group() {
	local user=$1 group=$2
	[[ " $(id -nG "$user" 2>/dev/null) " == *" $group "* ]] && return 0
	if [[ $FAMILY = alpine ]]; then
		run addgroup "$user" "$group"
	else
		run usermod -aG "$group" "$user"
	fi
}

step_ssh() {
	step "SSH"
	if ! command -v sshd >/dev/null 2>&1; then
		say "  sshd is not installed, skipping"
		return 0
	fi
	local cur_port new_port root_mode="" pass_mode="" u keyuser="" others="" groups="" ver
	local conf=/etc/ssh/sshd_config.d/00-hardline.conf main=/etc/ssh/sshd_config snap=/run/hardline-ssh
	local changed=${#CHANGED[@]}

	cur_port=$SSH_PORT
	new_port=${OPT_SSH_PORT:-$(prompt "  SSH port" "$cur_port")}
	if [[ ! $new_port =~ ^[0-9]+$ ]] || ((new_port < 1 || new_port > 65535)); then
		warn "invalid port: $new_port"
		return 1
	fi

	if [[ $DRY_RUN = 1 && -n $ADMIN_USER && -n $OPT_KEY$OPT_GITHUB ]]; then
		keyuser=$ADMIN_USER
	fi
	for u in $ADMIN_USER $(sudo_users); do
		[[ -n $keyuser ]] && break
		[[ $u = root ]] && continue
		if user_has_key "$u"; then keyuser=$u; break; fi
	done
	if [[ -n $keyuser ]]; then
		root_mode=no
		pass_mode=no
	elif user_has_key root; then
		root_mode=prohibit-password
		pass_mode=no
		warn "no admin user with a key, root keeps key-only login"
	else
		warn "no SSH keys found for root or any sudo user"
		warn "password login stays enabled so you don't lock yourself out"
	fi

	# AllowGroups: users created later (by an app installer, say) can't
	# log in over ssh until someone adds them to sshusers on purpose
	others=$(login_users | tr ' ' '\n' | grep -vx root | paste -sd' ' -)
	if [[ $OPT_SSH_GROUPS = 1 ]]; then
		groups=yes
	elif [[ $ASSUME_YES = 0 ]]; then
		say "  AllowGroups can limit ssh logins to the $(sudo_group) group and a new group sshusers."
		[[ -n $others ]] && say "  These users would be added to sshusers and keep access: $others"
		ask "  Limit ssh logins to those groups?" y && groups=yes
	fi

	say "  planned: port $new_port${root_mode:+, PermitRootLogin $root_mode}${pass_mode:+, PasswordAuthentication $pass_mode}${groups:+, AllowGroups}, no weak ciphers"
	ask "Apply SSH settings?" y || return 0

	if [[ $DRY_RUN = 0 ]]; then
		rm -rf "$snap"
		mkdir -p "$snap"
		[[ -f $main ]] && cp -a "$main" "$snap/"
		[[ -f $conf ]] && cp -a "$conf" "$snap/"
	fi

	# no sshd_config at all means the vendor file in /usr/etc (openSUSE) is
	# used, it already includes sshd_config.d. Creating one would replace it.
	if [[ -f $main ]] && ! grep -qsE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$main"; then
		backup "$main"
		if [[ $DRY_RUN = 0 ]]; then
			{ echo "Include /etc/ssh/sshd_config.d/*.conf"; cat "$snap/sshd_config"; } >"$main"
			CHANGED+=("$main")
			remember edit "$main"
		else
			printf '  %s[dry-run]%s add Include line to %s\n' "$c_dim" "$c_off" "$main"
		fi
	fi

	# Port is additive in sshd, a second Port line would keep 22 open
	if [[ $new_port != "$cur_port" ]] && grep -qsE '^[[:space:]]*Port[[:space:]]' "$main"; then
		backup "$main"
		run sed -i -E 's/^([[:space:]]*Port[[:space:]])/#\1/' "$main"
		CHANGED+=("$main")
		remember edit "$main"
	fi

	if [[ -n $groups ]]; then
		if ! grep -q '^sshusers:' /etc/group; then
			if [[ $FAMILY = alpine ]]; then run addgroup sshusers; else run groupadd sshusers; fi
		fi
		for u in $others; do add_to_group "$u" sshusers; done
	fi

	local kbd=KbdInteractiveAuthentication
	ver=$(openssh_version || true)
	ver=${ver:-0}
	((ver < 87)) && kbd=ChallengeResponseAuthentication

	put_file "$conf" 600 < <(
		echo "# written by hardline, original files are kept as *.hardline.bak"
		[[ $new_port != 22 || $cur_port != 22 ]] && echo "Port $new_port"
		[[ -n $root_mode ]] && echo "PermitRootLogin $root_mode"
		if [[ -n $pass_mode ]]; then
			echo "PasswordAuthentication $pass_mode"
			echo "$kbd no"
		fi
		echo "PubkeyAuthentication yes"
		if [[ -n $groups ]]; then
			# AllowGroups applies to root too, so root stays in while it may log in
			if [[ $root_mode = no ]]; then
				echo "AllowGroups $(sudo_group) sshusers"
			else
				echo "AllowGroups root $(sudo_group) sshusers"
			fi
		fi
		echo "MaxAuthTries 4"
		echo "LoginGraceTime 30"
		echo "ClientAliveInterval 300"
		echo "ClientAliveCountMax 2"
		echo "X11Forwarding no"
		ssh_crypto "$ver"
	)

	[[ $DRY_RUN = 1 ]] && return 0
	[[ $FAMILY = debian ]] && mkdir -p /run/sshd
	if ! sshd -t 2>>"$LOGFILE"; then
		warn "sshd -t failed, rolling back ssh changes"
		[[ -f $snap/sshd_config ]] && cp -a "$snap/sshd_config" "$main"
		if [[ -f $snap/${conf##*/} ]]; then cp -a "$snap/${conf##*/}" "$conf"; else rm -f "$conf"; fi
		[[ -f $main ]] && remember edit "$main"
		return 1
	fi
	if ((${#CHANGED[@]} == changed)); then
		ok "sshd already set up like this"
		return 0
	fi

	if [[ $new_port != "$cur_port" ]]; then
		fw_open_port "$new_port" || true
		selinux_ssh_port "$new_port" || warn "could not label port $new_port for selinux, sshd may fail to bind"
	fi

	local interactive=0
	[[ $ASSUME_YES = 0 && $INIT != none ]] && interactive=1
	if ((interactive)); then
		deadman_arm ssh <<-EOF
			[ -f $snap/sshd_config ] && cp -a $snap/sshd_config $main
			if [ -f $snap/${conf##*/} ]; then cp -a $snap/${conf##*/} $conf; else rm -f $conf; fi
			$(ssh_reload_cmds)
		EOF
	fi
	[[ -n $(ssh_reload_cmds) ]] && { run sh -c "$(ssh_reload_cmds)" || true; }
	SSH_PORT=$new_port
	ok "sshd configured"

	if ((interactive)); then
		echo
		say "  ${c_bold}Keep this session open.${c_off} Test from a second terminal:"
		say "    ssh -p $new_port ${keyuser:-root}@$(server_ip)"
		if ! deadman_confirm ssh "Did the new login work?"; then
			[[ -f $main ]] && remember edit "$main"
			warn "ssh changes rolled back"
			SSH_PORT=$cur_port
			return 1
		fi
	fi
}

# ---------------------------------------------------------------- firewall

# "80, 443 51820/udp 8000-8100" -> "80/tcp 443/tcp 51820/udp 8000-8100/tcp"
parse_ports() {
	local p out=()
	for p in ${1//,/ }; do
		[[ $p == */* ]] || p="$p/tcp"
		if [[ ! $p =~ ^[0-9]+(-[0-9]+)?/(tcp|udp)$ ]]; then
			warn "ignoring invalid port: $p"
			continue
		fi
		out+=("$p")
	done
	printf '%s' "${out[*]}"
}

nft_main_conf() {
	case $FAMILY in
		rhel) echo /etc/sysconfig/nftables.conf ;;
		alpine) echo /etc/nftables.nft ;;
		suse) echo /etc/nftables/rules/main.nft ;;
		*) echo /etc/nftables.conf ;;
	esac
}

# nft_ruleset DOCKER PORT/PROTO... DOCKER=1 adds the forward chain that puts
# docker's published ports behind the same list.
nft_ruleset() {
	local docker=$1 tcp=() udp=() p
	shift
	for p in "$@"; do
		case $p in
			*/tcp) tcp+=("${p%/tcp}") ;;
			*/udp) udp+=("${p%/udp}") ;;
		esac
	done
	cat <<EOF2
#!/usr/sbin/nft -f
# written by hardline. Edit, then load with: nft -f $NFT_RULES

table inet hardline
delete table inet hardline

table inet hardline {
	# new ssh connections per address, fail2ban or crowdsec handle the rest
	set ssh_meter4 { type ipv4_addr; flags dynamic, timeout; timeout 1m; }
	set ssh_meter6 { type ipv6_addr; flags dynamic, timeout; timeout 1m; }

	chain input {
		type filter hook input priority 0; policy drop;

		ct state established,related accept
		ct state invalid drop
		iif lo accept

		meta l4proto { icmp, icmpv6 } accept
		# dhcpv6 replies come from the router's link-local address and don't
		# match the multicast request in conntrack
		ip6 saddr fe80::/10 udp sport 547 udp dport 546 accept

		tcp dport $SSH_PORT ct state new update @ssh_meter4 { ip saddr limit rate over 10/minute burst 10 packets } drop
		tcp dport $SSH_PORT ct state new update @ssh_meter6 { ip6 saddr limit rate over 10/minute burst 10 packets } drop

EOF2
	((${#tcp[@]})) && printf '\t\ttcp dport { %s } accept\n' "$(join "${tcp[@]}")"
	((${#udp[@]})) && printf '\t\tudp dport { %s } accept\n' "$(join "${udp[@]}")"
	printf '\t}\n'
	if [[ $docker = 1 ]]; then
		cat <<'EOF2'

	# docker publishes ports with DNAT, so that traffic takes the forward
	# path and never reaches input. Same list, matched on the port the
	# client connected to. Containers talking to each other are left alone.
	chain docker {
		type filter hook forward priority -1; policy accept;

		ct state established,related accept
		ct status & dnat == 0 accept
		iifname "docker0" accept
		iifname "br-*" accept

EOF2
		((${#tcp[@]})) && printf '\t\tmeta l4proto tcp ct original proto-dst { %s } accept\n' "$(join "${tcp[@]}")"
		((${#udp[@]})) && printf '\t\tmeta l4proto udp ct original proto-dst { %s } accept\n' "$(join "${udp[@]}")"
		printf '\t\tdrop\n\t}\n'
	fi
	printf '}\n'
}

# Load new rules from FILE. Interactive runs then have DEADMAN_SECS to confirm
# they can still get in, otherwise the rules on disk (or none) come back.
nft_apply() {
	local file=$1
	run nft -c -f "$file" || { warn "nft rejected the ruleset, see $LOGFILE"; return 1; }
	if [[ $ASSUME_YES = 0 ]]; then
		deadman_arm firewall <<-EOF2
			if [ -f $NFT_RULES ]; then nft -f $NFT_RULES; else nft delete table inet hardline; fi
		EOF2
	fi
	if ! run nft -f "$file"; then
		rm -f /run/hardline-firewall.undo
		return 1
	fi
	[[ $ASSUME_YES = 1 ]] && return 0
	echo
	say "  Firewall is live. Open a NEW ssh connection to check you can still get in."
	deadman_confirm firewall "Still able to connect?" && return 0
	warn "firewall rolled back"
	return 1
}

# port_allowed 8080/tcp "22/tcp 8000-8100/tcp"
port_allowed() {
	local port=${1%/*} proto=${1#*/} a lo hi
	port=${port%-*}
	for a in $2; do
		[[ ${a#*/} = "$proto" ]] || continue
		a=${a%/*}
		lo=${a%-*} hi=${a#*-}
		((port >= lo && port <= hi)) && return 0
	done
	return 1
}

step_firewall() {
	step "Firewall"
	local state detected extra ports p dports="" closed="" docker=0 tmp=/run/hardline-firewall.nft
	state=$(firewall_state)
	detected=$(listening_ports)
	[[ -n $detected ]] && say "  listening right now: $detected"

	if [[ -n $OPT_ALLOW ]]; then
		extra=$OPT_ALLOW
	else
		extra=$(prompt "  ports to allow besides ssh, e.g. 80,443,51820/udp (empty for none)" "")
	fi
	ports="$SSH_PORT/tcp $(parse_ports "$extra")"
	ports=$(tr ' ' '\n' <<<"$ports" | grep -v '^$' | sort -u | sort -t/ -k1,1n | paste -sd' ' -)
	say "  allowing: $ports"

	if [[ $state = none ]] && command -v ufw >/dev/null 2>&1 && [[ $ASSUME_YES = 0 ]]; then
		ask "  ufw is installed but inactive. Use ufw instead of plain nftables?" y && state=ufw
	fi
	if [[ $state = nftables ]] && ! nft list table inet hardline >/dev/null 2>&1; then
		warn "there is already an nftables ruleset with a drop policy"
		ask "  Add the hardline table anyway?" n || return 0
	fi

	if dports=$(docker_ports); then
		case $state in
			ufw|firewalld|iptables)
				warn "ports published by docker bypass $state${dports:+: $dports}"
				note "docker ports bypass $state, bind them to 127.0.0.1 or filter them in DOCKER-USER"
				;;
			*)
				for p in $dports; do
					port_allowed "$p" "$ports" || closed+="$p "
				done
				say "  docker is installed, ports it publishes skip the input rules${dports:+ (now: $dports)}"
				[[ -n $closed ]] && say "  with the same list these would be closed: ${closed% }"
				if [[ $OPT_DOCKER = 1 ]] || { [[ $ASSUME_YES = 0 ]] && ask "  Filter docker's ports with the same list?" y; }; then
					docker=1
				else
					note "docker ports are not filtered, run again with --docker to filter them"
				fi
				;;
		esac
	fi

	case $state in
		ufw)
			ask "Configure ufw?" y || return 0
			run ufw default deny incoming
			run ufw default allow outgoing
			for p in $ports; do run ufw allow "${p/-/:}"; done
			run ufw --force enable || return 1
			;;
		firewalld)
			ask "Add the ports to firewalld?" y || return 0
			for p in $ports; do run firewall-cmd --permanent --add-port="$p"; done
			run firewall-cmd --reload || return 1
			;;
		iptables)
			warn "iptables INPUT policy is already DROP, leaving it alone"
			warn "make sure these are open: $ports"
			return 0
			;;
		*)
			ask "Set up nftables (drop everything inbound except the above)?" y || return 0
			pkg_install nftables || return 1
			if [[ $DRY_RUN = 1 ]]; then
				# shellcheck disable=SC2086
				put_file "$NFT_RULES" 600 < <(nft_ruleset $docker $ports)
				return 0
			fi
			# shellcheck disable=SC2086
			nft_ruleset $docker $ports >"$tmp"
			nft_apply "$tmp" || return 1
			put_file "$NFT_RULES" 600 <"$tmp"
			rm -f "$tmp"
			put_file "$(nft_main_conf)" 755 <<EOF2
#!/usr/sbin/nft -f
# hardline keeps its rules in its own table so docker and others are untouched
include "$NFT_RULES"
EOF2
			svc enable nftables || true
			;;
	esac
	ok "firewall active, open: $ports"
}

# ---------------------------------------------------------------- brute force

f2b_banaction() {
	case $(firewall_state) in
		ufw) echo ufw ;;
		firewalld) echo firewallcmd-rich-rules ;;
		iptables) echo iptables-multiport ;;
		*) echo nftables-multiport ;;
	esac
}

setup_fail2ban() {
	local backend="" logpath="" action allports="" pkgs=(fail2ban)
	# the fail2ban meta package pulls in firewalld, which is enabled by preset
	# and would block the ssh port after the next reboot
	[[ $FAMILY = rhel && $(firewall_state) != firewalld ]] && pkgs=(fail2ban-server)
	if [[ $FAMILY = rhel && $OS_ID != fedora ]] && ! pkg_has epel-release; then
		pkg_install epel-release || { warn "fail2ban needs EPEL, enable it and run again"; return 1; }
		PKG_UPDATED=0
	fi

	if [[ -f /var/log/auth.log || -f /var/log/secure ]]; then
		:
	elif [[ $INIT = systemd ]]; then
		# debian 12 and others have no auth.log without rsyslog
		backend=systemd
		case $FAMILY in
			debian|rhel|suse) pkgs+=(python3-systemd) ;;
			arch) pkgs+=(python-systemd) ;;
		esac
	elif [[ $FAMILY = alpine ]]; then
		logpath=/var/log/messages
	fi
	action=$(f2b_banaction)
	case $action in
		nftables-multiport) pkgs+=(nftables); allports=nftables-allports ;;
		iptables-multiport) allports=iptables-allports ;;
	esac

	ours fail2ban
	pkg_install "${pkgs[@]}" || return 1
	put_file /etc/fail2ban/jail.d/hardline.local 644 <<EOF
# written by hardline
[DEFAULT]
bantime = 1h
bantime.increment = true
findtime = 10m
maxretry = 5
banaction = $action${allports:+
banaction_allports = $allports}

[sshd]
enabled = true
port = $SSH_PORT${backend:+
backend = $backend}${logpath:+
logpath = $logpath}
EOF
	svc enable fail2ban || return 1
	[[ $INIT = systemd ]] && svc restart fail2ban
	ok "fail2ban watching sshd on port $SSH_PORT"
}

setup_crowdsec() {
	local bouncer=crowdsec-firewall-bouncer-nftables
	case $FAMILY in
		debian|rhel) ;;
		*)
			warn "crowdsec setup is only automated on apt and dnf systems, using fail2ban"
			setup_fail2ban
			return
			;;
	esac
	case $(firewall_state) in ufw|iptables) bouncer=crowdsec-firewall-bouncer-iptables ;; esac

	if ! pkg_has crowdsec; then
		pkg_install curl || return 1
		say "  adding the crowdsec package repository"
		if [[ $DRY_RUN = 1 ]]; then
			printf '  %s[dry-run]%s curl -fsSL https://install.crowdsec.net | sh\n' "$c_dim" "$c_off"
		else
			fetch https://install.crowdsec.net | sh >>"$LOGFILE" 2>&1 || { warn "crowdsec repo setup failed"; return 1; }
		fi
		PKG_UPDATED=0
	fi
	ours crowdsec crowdsec-firewall-bouncer
	pkg_install crowdsec "$bouncer" || return 1
	svc enable crowdsec || true
	svc enable crowdsec-firewall-bouncer || true
	ok "crowdsec running with $bouncer"
}

step_bruteforce() {
	step "Brute force protection"
	local tool=${OPT_BRUTE:-}
	if [[ -z $tool ]]; then
		if [[ $ASSUME_YES = 1 ]]; then
			tool=fail2ban
		else
			tool=$(prompt "  fail2ban, crowdsec or none" fail2ban)
		fi
	fi
	case $tool in
		fail2ban) setup_fail2ban ;;
		crowdsec) setup_crowdsec ;;
		none) say "  skipped" ;;
		*) warn "unknown choice: $tool"; return 1 ;;
	esac
}

# ---------------------------------------------------------------- updates

is_dnf5() { [[ $(dnf --version 2>/dev/null) == *dnf5* ]]; }

upgrade_now() {
	local n=${BEFORE[updates]}
	[[ $n = 0 ]] && return 0
	[[ $n = "?" ]] && n="all"
	ask "Install $n pending update(s) now?" y || return 0
	case $FAMILY in
		debian)
			pkg_refresh || return 1
			run env DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Options::=--force-confold upgrade
			;;
		rhel) run dnf -y -q upgrade ;;
		arch) PKG_UPDATED=0; pkg_refresh ;;
		alpine) run apk upgrade -q ;;
		suse) run zypper -q -n update ;;
	esac && ok "system is up to date"
}

step_updates() {
	step "Updates"
	upgrade_now || true
	if [[ $OPT_UPDATES = 0 ]]; then
		say "  skipped (--no-updates)"
		return 0
	fi
	case $FAMILY in
		debian)
			ask "Install security updates automatically (unattended-upgrades)?" y || return 0
			pkg_install unattended-upgrades || return 1
			put_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
			if [[ $ASSUME_YES = 0 ]] && ask "  Reboot automatically at 04:00 when an update needs it?" n; then
				put_file /etc/apt/apt.conf.d/52hardline-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
			fi
			ok "unattended-upgrades enabled"
			;;
		rhel)
			ask "Install updates automatically (dnf-automatic)?" y || return 0
			if is_dnf5; then
				pkg_install dnf5-plugin-automatic || return 1
				put_file /etc/dnf/automatic.conf <<'EOF'
[commands]
apply_updates = yes
EOF
				svc enable dnf5-automatic.timer || return 1
			else
				pkg_install dnf-automatic || return 1
				svc enable dnf-automatic-install.timer || return 1
			fi
			ok "dnf-automatic enabled"
			;;
		alpine)
			ask "Run apk upgrade daily from cron?" y || return 0
			put_file /etc/periodic/daily/hardline-apk-upgrade 755 <<'EOF'
#!/bin/sh
apk update -q && apk upgrade -q
EOF
			svc enable crond || true
			ok "daily apk upgrade enabled"
			;;
		arch)
			say "  Arch is rolling release, unattended upgrades tend to break things there."
			say "  Run pacman -Syu yourself every week or so."
			note "arch: no automatic updates, upgrade manually"
			;;
		suse)
			say "  not automated on openSUSE yet, look at transactional-update or os-update"
			;;
	esac
}

# ---------------------------------------------------------------- swap

# "2G" "512M" "1024" -> megabytes
to_mb() {
	local v=${1^^}
	case $v in
		*G) echo $(( ${v%G} * 1024 )) ;;
		*M) echo "${v%M}" ;;
		*) echo "$v" ;;
	esac
}

step_swap() {
	step "Swap"
	local cur ram suggest size free fs
	cur=$(swap_mb)
	if ((cur > 0)); then
		ok "swap already configured (${cur} MB)"
		return 0
	fi
	[[ $OPT_SWAP = no ]] && { say "  skipped"; return 0; }

	ram=$(ram_mb)
	if ((ram < 2048)); then
		suggest=$((ram * 2))
	elif ((ram <= 8192)); then
		suggest=$ram
	else
		suggest=4096
	fi
	size=$(to_mb "${OPT_SWAP:-$(prompt "  swapfile size in MB (RAM is ${ram} MB)" "$suggest")}")
	if [[ ! $size =~ ^[0-9]+$ ]] || ((size < 64)); then
		warn "invalid swap size: $size"
		return 1
	fi
	ask "Create a ${size} MB swapfile at /swapfile?" y || return 0

	free=$(df -Pm / | awk 'NR == 2 {print $4}')
	if ((free < size + 1024)); then
		warn "only ${free} MB free on /, not creating swap"
		return 1
	fi
	if [[ -e /swapfile ]]; then
		warn "/swapfile already exists but is not active, leaving it alone"
		return 1
	fi

	fs=$(awk '$2 == "/" {fs = $3} END {print fs}' /proc/mounts)
	case $fs in
		btrfs)
			if btrfs filesystem mkswapfile --help >/dev/null 2>&1; then
				run btrfs filesystem mkswapfile --size "${size}M" /swapfile || return 1
			else
				# swap on btrfs needs a file without copy-on-write
				run truncate -s 0 /swapfile
				run chattr +C /swapfile
				run fallocate -l "${size}M" /swapfile || return 1
				run mkswap /swapfile
			fi
			;;
		zfs)
			warn "swapfiles on zfs are not supported, use a zvol instead"
			return 1
			;;
		*)
			run fallocate -l "${size}M" /swapfile || run dd if=/dev/zero of=/swapfile bs=1M count="$size" || return 1
			run mkswap /swapfile
			;;
	esac
	run chmod 600 /swapfile
	if ! run swapon /swapfile; then
		warn "swapon failed (container or unsupported filesystem?), removing /swapfile"
		rm -f /swapfile
		return 1
	fi
	if ! grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab; then
		backup /etc/fstab
		if [[ $DRY_RUN = 0 ]]; then
			echo "/swapfile none swap defaults 0 0" >>/etc/fstab
			CHANGED+=(/etc/fstab)
		fi
	fi
	# OpenRC only activates fstab swap with the swap service. Not in the
	# manifest: --undo stopping it would take other services down with it.
	if [[ $INIT = openrc && ! $(rc-update show boot 2>/dev/null) =~ (^|[[:space:]])swap[[:space:]] ]]; then
		run rc-update add swap boot
	fi
	put_file /etc/sysctl.d/90-hardline-swap.conf <<<"vm.swappiness = 10"
	run sysctl -q -p /etc/sysctl.d/90-hardline-swap.conf || true
	ok "${size} MB swap active"
}

# ---------------------------------------------------------------- extras

current_tz() {
	local tz=""
	command -v timedatectl >/dev/null 2>&1 && tz=$(timedatectl show -p Timezone --value 2>/dev/null) || true
	[[ -z $tz && -r /etc/timezone ]] && tz=$(cat /etc/timezone)
	[[ -z $tz && -L /etc/localtime ]] && tz=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
	printf '%s' "${tz:-UTC}"
}

setup_ntp() {
	if [[ $INIT = systemd ]] && command -v timedatectl >/dev/null 2>&1; then
		if [[ $(timedatectl show -p NTP --value 2>/dev/null) = yes ]]; then
			ok "time sync already on"
			return 0
		fi
		run timedatectl set-ntp true && { ok "time sync enabled"; return 0; }
	fi
	[[ $INIT = none ]] && return 0
	ours chrony chronyd
	pkg_install chrony || return 1
	case $FAMILY in
		debian) svc enable chrony ;;
		*) svc enable chronyd ;;
	esac
	ok "chrony enabled"
}

step_extras() {
	step "Time and kernel settings"
	local cur tz
	cur=$(current_tz)
	tz=${OPT_TZ:-$(prompt "  timezone" "$cur")}
	if [[ $tz != "$cur" ]]; then
		[[ -e /usr/share/zoneinfo/$tz ]] || pkg_install tzdata || true
		if [[ ! -e /usr/share/zoneinfo/$tz ]]; then
			warn "unknown timezone: $tz"
		elif [[ $INIT = systemd ]] && command -v timedatectl >/dev/null 2>&1; then
			run timedatectl set-timezone "$tz" && ok "timezone $tz"
		else
			run ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
			[[ -f /etc/timezone ]] && put_file /etc/timezone <<<"$tz"
			ok "timezone $tz"
		fi
	fi

	if ask "Make sure the clock is synced (NTP)?" y; then
		setup_ntp || true
	fi

	if ask "Apply network and kernel sysctl hardening?" y; then
		local bpf=2
		# 1 can't be changed back without a reboot, and writing 2 over it fails
		[[ $(cat /proc/sys/kernel/unprivileged_bpf_disabled 2>/dev/null) = 1 ]] && bpf=1
		put_file /etc/sysctl.d/90-hardline.conf <<EOF
# written by hardline
net.ipv4.tcp_syncookies = 1
# loose mode, strict breaks asymmetric routing on some providers
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1

# kernel pointers and dmesg only for root, no eBPF for normal users
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = $bpf
# no writing to other users' fifos and files in sticky dirs like /tmp
fs.protected_fifos = 2
fs.protected_regular = 2
EOF
		if run sysctl -q -p /etc/sysctl.d/90-hardline.conf; then
			ok "sysctl applied"
		else
			warn "could not apply sysctl now (container?), it will load on boot"
		fi
	fi
}

# ---------------------------------------------------------------- report

render_report() {
	local k b a st
	printf '%-24s %-28s %-28s %s\n' "check" "before" "after" "state"
	printf '%-24s %-28s %-28s %s\n' "-----" "------" "-----" "-----"
	for k in "${AUDIT_KEYS[@]}"; do
		b=${BEFORE[$k]}
		a=${AFTER[$k]}
		st=$(judge "$k" "$a")
		if [[ $st = ok && $(judge "$k" "$b") != ok ]]; then
			st=fixed
		fi
		printf '%-24s %-28s %-28s %s\n' "${LABEL[$k]}" "$(short "$b" 27)" "$(short "$a" 27)" "$(paint "$st")"
	done
}

report() {
	local still=() k
	step "Report"
	render_report | sed 's/^/  /'

	for k in "${AUDIT_KEYS[@]}"; do
		[[ $(judge "$k" "${AFTER[$k]}") = open ]] && still+=("${LABEL[$k]}")
	done
	echo
	if ((${#still[@]})); then
		warn "still open: $(join "${still[@]}")"
	else
		ok "nothing obvious left open"
	fi

	if [[ $DRY_RUN = 1 ]]; then
		say "  dry run, no report written"
		return 0
	fi

	(
		umask 077
		c_red="" c_grn="" c_yel="" c_off=""
		{
			echo "hardline $HARDLINE_VERSION report"
			echo "host:  $(hostname 2>/dev/null || cat /etc/hostname)"
			echo "os:    $OS_NAME"
			echo "date:  $(date '+%F %T %Z')"
			echo
			render_report
			echo
			echo "listening ports before: ${BEFORE[ports]}"
			echo "listening ports after:  ${AFTER[ports]}"
			if ((${#CHANGED[@]})); then
				echo
				echo "changed files (originals saved as <file>.hardline.bak):"
				printf '  %s\n' "${CHANGED[@]}" | sort -u
			fi
			if ((${#NOTES[@]})); then
				echo
				echo "notes:"
				printf '  %s\n' "${NOTES[@]}"
			fi
			if [[ -n $GENERATED_PW ]]; then
				echo
				echo "generated sudo password for $ADMIN_USER: $GENERATED_PW"
				echo "change it with: passwd $ADMIN_USER"
			fi
		} >"$REPORT"
	)
	say "  report saved to $REPORT"
	say "  to put everything back: hardline --undo (or bash hardline.sh --undo)"
	say "  log: $LOGFILE"
}

# ---------------------------------------------------------------- undo

# what hardline 0.1.0 wrote, it didn't keep a manifest yet
LEGACY_FILES=(
	/etc/ssh/sshd_config.d/00-hardline.conf
	/etc/hardline/firewall.nft
	/etc/fail2ban/jail.d/hardline.local
	/etc/apt/apt.conf.d/52hardline-reboot
	/etc/periodic/daily/hardline-apk-upgrade
	/etc/sysctl.d/90-hardline.conf
	/etc/sysctl.d/90-hardline-swap.conf
)

# "kind checksum path" lines, the manifest first, then anything an older
# run left behind. A dash means the checksum is unknown.
undo_entries() {
	local f
	{
		[[ -f $MANIFEST ]] && cat "$MANIFEST"
		for f in "${LEGACY_FILES[@]}"; do
			[[ -e $f ]] && echo "new - $f"
		done
		find /etc -name '*.hardline.bak' 2>/dev/null | sed 's/\.hardline\.bak$//; s/^/edit - /'
		f=$(nft_main_conf)
		if grep -qs "include \"$NFT_RULES\"" "$f" && [[ ! -e $f.hardline.bak ]]; then
			echo "new - $f"
		fi
	} | awk '!seen[$3]++'
}

# put back the original (edit) or delete our file (new)
undo_file() {
	local kind=$1 path=$2
	if [[ $kind = edit ]]; then
		[[ -e $path.hardline.bak ]] || return 0
		run mv -f "$path.hardline.bak" "$path" && ok "restored $path"
	else
		run rm -f "$path" && ok "removed $path"
	fi
}

undo() {
	step "Undo"
	local entries kind sum path cur ssh_touched=0 f2b_touched=0 svcs=() s port
	entries=$(undo_entries)
	if [[ -z $entries ]]; then
		ok "nothing from hardline found"
		return 0
	fi
	[[ -f $MANIFEST ]] || warn "no manifest (hardline 0.1.0?), going by file names and .hardline.bak files"

	while read -r kind sum path; do
		case $kind:$path in
			svc:*) svcs+=("$path"); continue ;;
			*:/etc/sudoers.d/10-hardline-wheel) continue ;;    # the admin user keeps sudo
			*:/etc/fstab) continue ;;                           # see the swapfile below
		esac
		[[ -e $path || -e $path.hardline.bak ]] || continue
		case $path in
			/etc/ssh/*) ssh_touched=1 ;;
			/etc/fail2ban/*) f2b_touched=1 ;;
		esac

		cur=-
		[[ -f $path ]] && cur=$(sha256sum "$path" | cut -d' ' -f1)
		if [[ $path == *hardline* || ($sum != - && $sum = "$cur") ]]; then
			undo_file "$kind" "$path"
			continue
		fi

		# changed after hardline wrote it, or written by 0.1.0 without a checksum
		if [[ $ASSUME_YES = 1 ]]; then
			warn "$path may have been edited since, left alone (check it by hand)"
			continue
		fi
		say "  $path may have been edited after hardline:"
		if [[ $kind = edit ]]; then
			diff -u "$path.hardline.bak" "$path" 2>/dev/null | head -n 30 | sed 's/^/    /'
		else
			head -n 20 "$path" | sed 's/^/    /'
		fi
		if [[ $sum = - ]]; then
			ask "  Put back the version from before hardline?" y && undo_file "$kind" "$path"
		else
			ask "  Put back the version from before hardline anyway?" n && undo_file "$kind" "$path"
		fi
	done <<<"$entries"

	if [[ -f /swapfile ]] && grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab &&
		[[ -e /etc/fstab.hardline.bak ]] && ask "  Remove /swapfile as well?" n; then
		run swapoff /swapfile || true
		run sed -i -E '\#^[[:space:]]*/swapfile[[:space:]]#d' /etc/fstab
		run rm -f /swapfile /etc/fstab.hardline.bak
		ok "swapfile removed"
	fi

	if command -v nft >/dev/null 2>&1 && nft list table inet hardline >/dev/null 2>&1; then
		run nft delete table inet hardline && ok "firewall table removed"
	fi
	for s in "${svcs[@]}"; do
		svc disable "$s" && ok "$s disabled"
	done
	if ((f2b_touched)) && svc is-active fail2ban; then
		svc restart fail2ban || true
	fi

	if ((ssh_touched)) && command -v sshd >/dev/null 2>&1; then
		if sshd -t 2>>"$LOGFILE"; then
			# sshd may go back to another port, keep ufw/firewalld from blocking it
			port=$(sshd -T 2>/dev/null | awk 'tolower($1) == "port" && !p {p = $2} END {print p}') || true
			[[ -n $port && $port != "$SSH_PORT" ]] && { fw_open_port "$port" || true; }
			[[ -n $(ssh_reload_cmds) ]] && { run sh -c "$(ssh_reload_cmds)" || true; }
			ok "sshd reloaded${port:+, listening on $port}"
		else
			warn "sshd -t fails after restoring, sshd was NOT reloaded. Fix it before you log out."
		fi
	fi

	if [[ $DRY_RUN = 0 ]]; then
		rm -f "$MANIFEST"
		rmdir /etc/hardline 2>/dev/null || true
	fi
	say "  Kept: the admin user, its keys and sudo rights, and installed packages."
	say "  Kernel settings from sysctl go back to the defaults with the next reboot."
}

# ---------------------------------------------------------------- json

json_str() {
	local s=${1//\\/\\\\}
	printf '"%s"' "${s//\"/\\\"}"
}

print_json() {
	local -n a=$1
	local k sep=""
	printf '{"version":%s,"host":%s,"os":%s,"checks":{' "$(json_str "$HARDLINE_VERSION")" \
		"$(json_str "$(hostname 2>/dev/null || cat /etc/hostname)")" "$(json_str "$OS_NAME")"
	for k in "${AUDIT_KEYS[@]}"; do
		printf '%s"%s":{"label":%s,"value":%s,"state":"%s"}' "$sep" "$k" "$(json_str "${LABEL[$k]}")" \
			"$(json_str "${a[$k]}")" "$(judge "$k" "${a[$k]}")"
		sep=,
	done
	printf '}}\n'
}

# 2 when anything is open, for monitoring and CI
audit_status() {
	local -n a=$1
	local k
	for k in "${AUDIT_KEYS[@]}"; do
		[[ $(judge "$k" "${a[$k]}") = open ]] && return 2
	done
	return 0
}

usage() {
	cat <<EOF
hardline $HARDLINE_VERSION - harden a fresh VPS

usage: hardline.sh [options]

  -y, --yes             no questions, use flags and safe defaults
  -n, --dry-run         show what would change, change nothing
      --audit           only print the audit and exit (2 if something is open)
      --json            the audit as JSON, implies --audit
      --undo            put back what hardline changed
      --user NAME       create or update this admin user
      --key "KEY"       public key for the admin user
      --github NAME     import public keys from github.com/NAME.keys
      --copy-root-keys  copy root's authorized_keys to the admin user
      --ssh-port PORT   move sshd to this port
      --allow LIST      extra ports to open, e.g. "80,443,51820/udp"
      --docker          filter ports published by docker with the same list
      --ssh-groups      only sudo users and the group sshusers may log in over ssh
      --brute TOOL      fail2ban (default), crowdsec or none
      --no-updates      skip automatic updates
      --swap SIZE|no    swapfile size like 2G or 1024M, or no
      --timezone TZ     set the timezone, e.g. Europe/Berlin
      --skip LIST       skip steps: user,ssh,firewall,bruteforce,updates,swap,extras
      --no-color        plain output
  -h, --help            this help
EOF
}

parse_args() {
	while (($#)); do
		case $1 in
			-y|--yes) ASSUME_YES=1 ;;
			-n|--dry-run) DRY_RUN=1 ;;
			--audit) AUDIT_ONLY=1 ;;
			--json) AUDIT_ONLY=1 JSON=1 ;;
			--undo) UNDO=1 ;;
			--docker) OPT_DOCKER=1 ;;
			--ssh-groups) OPT_SSH_GROUPS=1 ;;
			--user) OPT_USER=${2:?--user needs a value}; shift ;;
			--key) OPT_KEY=${2:?--key needs a value}; shift ;;
			--github) OPT_GITHUB=${2:?--github needs a value}; shift ;;
			--copy-root-keys) OPT_COPY_ROOT_KEYS=1 ;;
			--ssh-port) OPT_SSH_PORT=${2:?--ssh-port needs a value}; shift ;;
			--allow) OPT_ALLOW=${2:?--allow needs a value}; shift ;;
			--brute) OPT_BRUTE=${2:?--brute needs a value}; shift ;;
			--no-updates) OPT_UPDATES=0 ;;
			--swap) OPT_SWAP=${2:?--swap needs a value}; shift ;;
			--timezone) OPT_TZ=${2:?--timezone needs a value}; shift ;;
			--skip) SKIP+="${2:?--skip needs a value},"; shift ;;
			--no-color) c_red="" c_grn="" c_yel="" c_dim="" c_bold="" c_off="" ;;
			-h|--help) usage; exit 0 ;;
			--version) echo "$HARDLINE_VERSION"; exit 0 ;;
			*) usage >&2; die "unknown option: $1" ;;
		esac
		shift
	done
	case ${OPT_BRUTE:-fail2ban} in fail2ban|crowdsec|none) ;; *) die "--brute must be fail2ban, crowdsec or none" ;; esac
}

run_step() {
	local name=$1 fn=$2
	if [[ $SKIP == *",$name,"* ]]; then
		return 0
	fi
	"$fn" || warn "step '$name' did not finish cleanly"
}

main() {
	parse_args "$@"
	[[ $EUID = 0 ]] || die "run this as root (sudo bash hardline.sh)"
	if [[ $ASSUME_YES = 0 && $AUDIT_ONLY = 0 ]] && ! (: </dev/tty) 2>/dev/null; then
		die "no terminal to ask questions on, use --yes for a non-interactive run"
	fi
	detect_os

	if [[ $JSON = 1 ]]; then
		audit BEFORE
		print_json BEFORE
		audit_status BEFORE
		exit
	fi
	if [[ $DRY_RUN = 0 && $AUDIT_ONLY = 0 ]]; then
		touch "$LOGFILE" && chmod 600 "$LOGFILE"
		log "hardline $HARDLINE_VERSION started: $*"
	fi

	printf '%shardline %s%s on %s (%s, init: %s)\n' "$c_bold" "$HARDLINE_VERSION" "$c_off" "$OS_NAME" "$FAMILY" "$INIT"
	[[ $DRY_RUN = 1 ]] && printf '%sdry run, nothing will be changed%s\n' "$c_yel" "$c_off"
	[[ $INIT = none ]] && warn "no running init system found (container?), services will not be started"

	if [[ $UNDO = 1 ]]; then
		SSH_PORT=$(sshd_value Port)
		undo || { warn "undo did not finish cleanly, see $LOGFILE"; exit 1; }
		exit 0
	fi
	if [[ $DRY_RUN = 0 && $AUDIT_ONLY = 0 && ( $FAMILY = debian || $FAMILY = alpine ) ]]; then
		pkg_refresh || true
	fi

	step "Audit"
	audit BEFORE
	print_audit BEFORE
	if [[ $AUDIT_ONLY = 1 ]]; then
		audit_status BEFORE
		exit
	fi

	echo
	ask "Start hardening?" y || exit 0
	SSH_PORT=${BEFORE[ssh_port]}
	[[ $SSH_PORT =~ ^[0-9]+$ ]] || SSH_PORT=22

	run_step user step_user
	run_step ssh step_ssh
	run_step firewall step_firewall
	run_step bruteforce step_bruteforce
	run_step updates step_updates
	run_step swap step_swap
	run_step extras step_extras

	audit AFTER
	report
}

main "$@"
