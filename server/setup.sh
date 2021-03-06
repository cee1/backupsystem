#!/bin/bash
set -e
default="/data/backup"
backup_user="backupsrv"

help()
{
	echo "You need install gitosis first(https://github.com/cee1/gitosis-hack.git)"
	echo "setup.sh <host-ip> [path]"
}

if test $# -lt 1 -o "$1" == "-h" -o "$1" == "--help"; then
	help
	exit 0
elif test $# -lt 2; then
	target=
	host_ip="$1"
else
	host_ip="$1"
	target="$2"
fi


notes=()
push_note()
{
	local note="$1"
	
	local len=${#notes[@]}
	notes[len]="$note"
}

create_backup_user()
{
	echo "Creating user '$backup_user' with HOME='$target'"
	test -d $(dirname "$target") || mkdir -p $(dirname "$target")
	useradd --system --shell /bin/bash --comment "$backup_user" --user-group --create-home \
	  --home-dir "$target" "$backup_user"
	sudo -H -u "$backup_user" ssh-keygen -C "$backup_user@$host_ip" -N "" -f "$target/.ssh/id_rsa"
	
	push_note "Don't forget to Copy server's public key('$target/.ssh/id_rsa.pub') to clients"
}

check_prereq()
{
	local backup_user_exists=1

	if test "$(id -u $(whoami))" -ne 0; then
		echo "please run this script as root" >&2
		exit 2
	fi

	if ! which gitosis-init &> /dev/null; then
		echo "You must install gitosis first" >&2
		exit 2
	fi

	if id -u "$backup_user" &> /dev/null; then
		backup_user_exists=1
		target="$(eval echo ~$backup_user)"
	else
		backup_user_exists=0
		test -n "$target" || target="$default"
	fi

	read -p "Please specify /path/to/send_mail: " send_mail
	read -p "Please specify notification email(a@e.com b@e.com...): " notification_emails
	read -p "Please specify /path/to/admin_public_key: " admin_pubkey
	admin_pubkey="$(eval echo "$admin_pubkey")"

	# canonicalize -> absolute_path
	target=$(readlink -m "$target")
	send_mail=$(readlink -m "$send_mail")
	admin_pubkey=$(readlink -m "$admin_pubkey")

	logdir="${target}/log"
	datadir="${target}/data"
	TODOdir="${target}/TODO"
	scriptsdir="${target}/scripts"
	cmdir="${scriptsdir}/cmds"
	utilsdir="${scriptsdir}/utils"

	echo "Backup WorkingDir set to '$target'"
	test $backup_user_exists -eq 1 || echo "Will create dedicated user $backup_user"
	echo "send_mail: '$send_mail'"
	echo "Notification emails: $notification_emails"
	echo "Administrator's public key: '$admin_pubkey'"
	read -p "Is above OK?(y/N)" answer

	if test "$answer" != "y"; then
		echo "Bye"
		exit 1
	fi

	if test $backup_user_exists -eq 0; then
		create_backup_user
	fi
}

mklayout()
{
	for dir in "$logdir" "$datadir" "$TODOdir"
	do
		mkdir -p "$dir"
		chown "$backup_user:$backup_user" "$dir"
	done
}

install_scripts()
{
	local cwd=$(pwd)

	exec_sources=("do_backup" "bkdb")
	normal_sources=("backupconfig.sh" "cmds/git.sh" "cmds/sftp.sh" "cmds/rsync.sh" "utils/post-update.template" "utils/backupProp.py" "utils/utils.sh" "utils/colorful.py")
	
	for item in "${exec_sources[@]}"
	do
		echo "install \"${item}\"-> \"${scriptsdir}/${item}\" [mode 755]"
		install -p -D -m 755 -T "$item" "${scriptsdir}/${item}"
	done
	
	for item in "${normal_sources[@]}"
	do
		echo "install \"${item}\"-> \"${scriptsdir}/${item}\" [mode 744]"
		install -p -D -m 644 -T "$item" "${scriptsdir}/${item}"
	done

	echo "Setting scripts execution environment"
	settings=(
		"Host=\"$host_ip\""
		"TODOdir=\"$TODOdir\""
		"Datadir=\"$datadir\""
		"Cmdir=\"$cmdir\""
		"UtilsDir=\"$utilsdir\""
		"LogfileDir=\"$logdir\""
		"Sendmail=\"$send_mail\""
		"Administrators=\"$notification_emails\""
	)
	
	for setting in "${settings[@]}"
	do
		key=$(echo "$setting" | cut -d "=" -f 1)
		sed -i "s|^[ \t]*$key=.*|$setting|g" "$scriptsdir/backupconfig.sh"
	done
	push_note "You can configure the backup system through \"$scriptsdir/backupconfig.sh\""

	echo "Initializing gitosis ..."
	sudo -H -u "$backup_user" gitosis-init < "$admin_pubkey"
	cd "$target/repositories/gitosis-admin.git"

	sudo -H -u "$backup_user" git --git-dir="." --work-tree="gitosis-export" \
	  checkout -f HEAD
	sed -i -e "/extProps[\t ]*=/d" \
	  -e "/[\t ]*gitosis[\t ]*$/a \
	extProps\t = ${utilsdir#$target/}/backupProp.py" gitosis-export/gitosis.conf
	sudo -H -u "$backup_user" git --git-dir="." --work-tree="gitosis-export" \
	  add gitosis.conf
	sudo -H -u "$backup_user" git --git-dir="." --work-tree="gitosis-export" \
	  commit --amend -m "Backup system: set gitosis.extProps"
	mv -f gitosis-export/gitosis.conf .

	cd "$cwd"

	echo "Installing '/etc/cron.d/backupserver' ..."
	cat > /etc/cron.d/backupserver <<EOF
0-59/5 * * * * $backup_user '$scriptsdir/do_backup'

# Users of Arch Linux use the following line:
#0-59/5 * * * * su -c "'$scriptsdir/do_backup'" $backup_user
EOF
	push_node "Note Arch users also need to modify /etc/cron.d/backupserver"
}

check_prereq
mklayout
install_scripts

echo
echo "***Note***"
for note in "${notes[@]}"
do
	echo "$note"
done

echo "You can additionally set apache to export git, you need to add user \"www-data\" to group \"$backup_user\""

