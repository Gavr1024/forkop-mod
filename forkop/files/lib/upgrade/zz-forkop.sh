# Sourced by /sbin/sysupgrade after it chooses how to build the backup list.
# Listing the folder in keep.d is not enough: that walk can skip files
# inside /etc/forkop. Add each file when the backup list is built.

forkop_backup_files() {
	local file="$1"
	local root path listed

	[ -n "$file" ] || return 0
	root="${FORKOP_BACKUP_DIR:-/etc/forkop}"
	[ -d "$root" ] || return 0

	listed="$(find "$root" -type f 2>/dev/null; find "$root" -type l 2>/dev/null)"
	[ -n "$listed" ] || return 0

	printf '%s\n' "$listed" | while IFS= read -r path; do
		[ -n "$path" ] || continue
		grep -qxF "$path" "$file" 2>/dev/null || echo "$path"
	done >> "$file"
	return 0
}

case " ${sysupgrade_init_conffiles:-} " in
*" forkop_backup_files "*) ;;
*) sysupgrade_init_conffiles="${sysupgrade_init_conffiles:+$sysupgrade_init_conffiles }forkop_backup_files" ;;
esac
