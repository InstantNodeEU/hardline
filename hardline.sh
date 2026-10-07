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
	out[ports]=$(listening_ports)
	out[ports]=${out[ports]:-none}
	out[ssh_port]=$(sshd_value Port)
	out[root_login]=$(sshd_value PermitRootLogin)
	out[password_auth]=$(sshd_value PasswordAuthentication)
	out[login_users]=$(login_users)
	out[empty_pw]=$(empty_pw_users)
	out[empty_pw]=${out[empty_pw]:-none}
	out[nopasswd]=$(nopasswd_sudo)
	out[nopasswd]=${out[nopasswd]:-none}
	out[firewall]=$(firewall_state)
	out[updates]=$(pending_updates)
	out[swap]="$(swap_mb) MB"
	out[autoupdates]=$(autoupdates_state)
	out[bruteforce]=$(bruteforce_state)
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
}

main "$@"
