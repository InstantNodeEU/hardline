#!/usr/bin/env bash
#
# hardline - harden a fresh VPS in one interactive pass
#
# Copyright (c) 2026 luxend / InstantNode
# MIT license, see LICENSE

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

HARDLINE_VERSION=0.1.0
LOGFILE=/var/log/hardline.log
REPORT=/root/hardline-report-$(date +%Y%m%d-%H%M).txt
NFT_RULES=/etc/hardline/firewall.nft

ASSUME_YES=0
DRY_RUN=0
AUDIT_ONLY=0
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
declare -A BEFORE=() AFTER=()

KEY_RE='(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) [A-Za-z0-9+/]+=*'

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
	c_red=$'\e[31m' c_grn=$'\e[32m' c_yel=$'\e[33m' c_dim=$'\e[2m' c_bold=$'\e[1m' c_off=$'\e[0m'
else
	c_red="" c_grn="" c_yel="" c_dim="" c_bold="" c_off=""
fi

log() {
	[[ $DRY_RUN = 1 ]] && return 0
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
	backup "$path"
	mkdir -p "$(dirname "$path")"
	printf '%s\n' "$content" >"$path"
	chmod "$mode" "$path"
	CHANGED+=("$path")
	log "wrote $path"
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
		debian) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed" ;;
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
		arch) run pacman -Syu --noconfirm ;;
		alpine) run apk update -q ;;
		suse) run zypper -q refresh ;;
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
		suse) run zypper -q install -y "${missing[@]}" ;;
	esac
}

# svc enable|restart|reload|is-active NAME
svc() {
	local action=$1 name=$2
	case $INIT in
		systemd)
			case $action in
				enable) run systemctl enable --now "$name" ;;
				is-active) systemctl is-active --quiet "$name" 2>/dev/null ;;
				*) run systemctl "$action" "$name" ;;
			esac
			;;
		openrc)
			case $action in
				enable) run rc-update add "$name" default && run rc-service "$name" restart ;;
				is-active) rc-service "$name" status >/dev/null 2>&1 ;;
				*) run rc-service "$name" "$action" ;;
			esac
			;;
		none)
			[[ $action = is-active ]] && return 1
			warn "no init system, skipping $action $name"
			;;
	esac
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
	v=$(sshd -T 2>/dev/null | awk -v k="${key,,}" '$1 == k {print $2; exit}') || true
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
	elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		echo ufw
	elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		echo firewalld
	elif command -v nft >/dev/null 2>&1 && nft list chains 2>/dev/null | grep -q 'hook input.*policy drop'; then
		echo nftables
	elif command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)'; then
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
}

AUDIT_KEYS=(ports ssh_port root_login password_auth login_users empty_pw nopasswd firewall bruteforce updates autoupdates swap)
declare -A LABEL=(
	[ports]="listening ports"
	[ssh_port]="ssh port"
	[root_login]="root login"
	[password_auth]="password login"
	[login_users]="users with a shell"
	[empty_pw]="empty passwords"
	[nopasswd]="sudo without password"
	[firewall]="firewall"
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
	put_file /etc/sudoers.d/10-hardline-wheel 440 <<<"%wheel ALL=(ALL:ALL) ALL"
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
			id -nG "$name" | grep -qw "$group" || run addgroup "$name" "$group"
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
	ssh -V 2>&1 | sed -nE 's/^OpenSSH_([0-9]+)\.([0-9]+).*/\1\2/p' | head -n1
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

step_ssh() {
	step "SSH"
	if ! command -v sshd >/dev/null 2>&1; then
		say "  sshd is not installed, skipping"
		return 0
	fi
	local cur_port new_port root_mode="" pass_mode="" u keyuser="" conf=/etc/ssh/sshd_config.d/00-hardline.conf main=/etc/ssh/sshd_config

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

	say "  planned: port $new_port${root_mode:+, PermitRootLogin $root_mode}${pass_mode:+, PasswordAuthentication $pass_mode}"
	ask "Apply SSH settings?" y || return 0

	if ! grep -qsE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$main"; then
		backup "$main"
		if [[ $DRY_RUN = 0 ]]; then
			{ echo "Include /etc/ssh/sshd_config.d/*.conf"; cat "$main.hardline.bak"; } >"$main"
			CHANGED+=("$main")
		else
			printf '  %s[dry-run]%s add Include line to %s\n' "$c_dim" "$c_off" "$main"
		fi
	fi

	# Port is additive in sshd, a second Port line would keep 22 open
	if [[ $new_port != "$cur_port" ]] && grep -qE '^[[:space:]]*Port[[:space:]]' "$main"; then
		backup "$main"
		run sed -i -E 's/^([[:space:]]*Port[[:space:]])/#\1/' "$main"
		CHANGED+=("$main")
	fi

	local kbd=KbdInteractiveAuthentication ver
	ver=$(openssh_version || true)
	((${ver:-0} < 87)) && kbd=ChallengeResponseAuthentication

	put_file "$conf" 600 < <(
		echo "# written by hardline, original files are kept as *.hardline.bak"
		[[ $new_port != 22 || $cur_port != 22 ]] && echo "Port $new_port"
		[[ -n $root_mode ]] && echo "PermitRootLogin $root_mode"
		if [[ -n $pass_mode ]]; then
			echo "PasswordAuthentication $pass_mode"
			echo "$kbd no"
		fi
		echo "PubkeyAuthentication yes"
		echo "MaxAuthTries 4"
		echo "X11Forwarding no"
	)

	[[ $DRY_RUN = 0 && $FAMILY = debian ]] && mkdir -p /run/sshd
	if [[ $DRY_RUN = 0 ]] && ! sshd -t 2>>"$LOGFILE"; then
		warn "sshd -t failed, rolling back ssh changes"
		rm -f "$conf"
		[[ -f $main.hardline.bak ]] && cp -a "$main.hardline.bak" "$main"
		return 1
	fi

	if [[ $new_port != "$cur_port" ]]; then
		fw_open_port "$new_port" || true
		selinux_ssh_port "$new_port" || warn "could not label port $new_port for selinux, sshd may fail to bind"
	fi

	if [[ $INIT = systemd ]] && systemctl is-active --quiet ssh.socket 2>/dev/null; then
		# ubuntu 22.10+ socket activation takes the port from a generator
		run systemctl daemon-reload
		run systemctl restart ssh.socket
	else
		svc reload "$(ssh_service)" || svc restart "$(ssh_service)" || true
	fi
	SSH_PORT=$new_port
	ok "sshd configured"

	if [[ $DRY_RUN = 0 && $INIT != none ]]; then
		echo
		say "  ${c_bold}Keep this session open.${c_off} Test from a second terminal:"
		say "    ssh -p $new_port ${keyuser:-root}@$(server_ip)"
		if [[ $ASSUME_YES = 0 ]] && ! ask "Did the new login work?" y; then
			warn "rolling back ssh changes"
			rm -f "$conf"
			[[ -f $main.hardline.bak ]] && cp -a "$main.hardline.bak" "$main"
			svc reload "$(ssh_service)" || svc restart "$(ssh_service)" || true
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
		*) echo /etc/nftables.conf ;;
	esac
}

nft_ruleset() {
	local tcp=() udp=() p
	for p in "$@"; do
		case $p in
			*/tcp) tcp+=("${p%/tcp}") ;;
			*/udp) udp+=("${p%/udp}") ;;
		esac
	done
	cat <<EOF
#!/usr/sbin/nft -f
# written by hardline. Edit, then load with: nft -f $NFT_RULES
#
# Only the input hook is filtered. Forwarded traffic (docker, vms) is left
# alone, so published docker ports are not covered by these rules.

table inet hardline
delete table inet hardline

table inet hardline {
	chain input {
		type filter hook input priority 0; policy drop;

		ct state established,related accept
		ct state invalid drop
		iif lo accept

		meta l4proto { icmp, icmpv6 } accept

EOF
	((${#tcp[@]})) && printf '\t\ttcp dport { %s } accept\n' "$(join "${tcp[@]}")"
	((${#udp[@]})) && printf '\t\tudp dport { %s } accept\n' "$(join "${udp[@]}")"
	printf '\t}\n}\n'
}

# Load the rules and give the user a minute to confirm they can still get
# in. Without an answer the table is removed again.
nft_apply() {
	local timer ans
	run nft -f "$NFT_RULES" || return 1
	[[ $ASSUME_YES = 1 || $DRY_RUN = 1 ]] && return 0

	( sleep 60; nft delete table inet hardline 2>/dev/null ) &
	timer=$!
	echo
	say "  Firewall is live. Open a NEW ssh connection to check you can still get in."
	printf 'Still able to connect? (rolls back in 60s) [y/N] ' >/dev/tty
	read -r -t 60 ans </dev/tty || ans=""
	kill "$timer" 2>/dev/null || true
	wait "$timer" 2>/dev/null || true
	if [[ ${ans,,} == y* ]]; then
		return 0
	fi
	echo
	nft delete table inet hardline 2>/dev/null || true
	warn "firewall rolled back"
	return 1
}

step_firewall() {
	step "Firewall"
	local state detected extra ports p
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
			# shellcheck disable=SC2086
			put_file "$NFT_RULES" 600 < <(nft_ruleset $ports)
			nft_apply || return 1
			put_file "$(nft_main_conf)" 755 <<EOF
#!/usr/sbin/nft -f
# hardline keeps its rules in its own table so docker and others are untouched
include "$NFT_RULES"
EOF
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
			debian) pkgs+=(python3-systemd) ;;
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

is_dnf5() { dnf --version 2>/dev/null | head -n1 | grep -q dnf5; }

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

	if ask "Apply network sysctl hardening?" y; then
		put_file /etc/sysctl.d/90-hardline.conf <<'EOF'
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
	say "  log: $LOGFILE"
}

usage() {
	cat <<EOF
hardline $HARDLINE_VERSION - harden a fresh VPS

usage: hardline.sh [options]

  -y, --yes             no questions, use flags and safe defaults
  -n, --dry-run         show what would change, change nothing
      --audit           only print the audit and exit
      --user NAME       create or update this admin user
      --key "KEY"       public key for the admin user
      --github NAME     import public keys from github.com/NAME.keys
      --copy-root-keys  copy root's authorized_keys to the admin user
      --ssh-port PORT   move sshd to this port
      --allow LIST      extra ports to open, e.g. "80,443,51820/udp"
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
	if [[ $DRY_RUN = 0 ]]; then
		touch "$LOGFILE" && chmod 600 "$LOGFILE"
		log "hardline $HARDLINE_VERSION started: $*"
	fi

	printf '%shardline %s%s on %s (%s, init: %s)\n' "$c_bold" "$HARDLINE_VERSION" "$c_off" "$OS_NAME" "$FAMILY" "$INIT"
	[[ $DRY_RUN = 1 ]] && printf '%sdry run, nothing will be changed%s\n' "$c_yel" "$c_off"
	[[ $INIT = none ]] && warn "no running init system found (container?), services will not be started"

	if [[ $DRY_RUN = 0 && ( $FAMILY = debian || $FAMILY = alpine ) ]]; then
		pkg_refresh || true
	fi

	step "Audit"
	audit BEFORE
	print_audit BEFORE
	[[ $AUDIT_ONLY = 1 ]] && exit 0

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
