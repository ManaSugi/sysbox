#!/usr/bin/env bats

#
# Volume mount tests for sysbox-pods.
#

load ../helpers/crictl
load ../helpers/userns
load ../helpers/k8s
load ../helpers/run
load ../helpers/uid-shift
load ../helpers/sysbox-health

function teardown() {
  sysbox_log_check
}

@test "pod hostPath vol" {

	# Create a dir on the host with ownership matching the sys container's root
	# process.
	local host_path=$(mktemp -d "/mnt/scratch/tmp-vol.XXXXXX")
	echo "some data" > $host_path/testfile.txt

	subuid=$(grep containers /etc/subuid | cut -d":" -f2)
	subgid=$(grep containers /etc/subgid | cut -d":" -f2)
   chown -R $subuid:$subgid $host_path

	# Create a pod with a volume mount of that host dir
	local ctr_path="/mnt/test-vol"
	local container_json="/mnt/scratch/container.json"

	jq --arg host_path "$host_path" --arg ctr_path "$ctr_path" \
		'  .mounts = [ {
   			host_path: $host_path,
	   		container_path: $ctr_path
		} ]' \
	   "${POD_MANIFEST_DIR}/alpine-container.json" > "$container_json"

	local syscont=$(crictl_run $container_json ${POD_MANIFEST_DIR}/alpine-pod.json)
	local pod=$(crictl_cont_get_pod $syscont)

	# Verify the volume got mounted and it has the correct ownership
	run crictl exec $syscont cat "$ctr_path/testfile.txt"
	[ "$status" -eq 0 ]
	[[ "$output" == "some data" ]]

	uid=$(crictl exec $syscont stat -c '%u' $ctr_path)
	gid=$(crictl exec $syscont stat -c '%g' $ctr_path)

	[ $uid -eq 0 ]
	[ $gid -eq 0 ]

	# Verify uid shifting is NOT done on the pod's volume
	run crictl exec $syscont sh -c "grep $ctr_path /proc/self/mountinfo | egrep -qv \"shiftfs|idmapped\""
	[ "$status" -eq 0 ]

	# Verify the pod can write to the mounted host volume
	run crictl exec $syscont sh -c "echo 'new data' > $ctr_path/testfile.txt"
	[ "$status" -eq 0 ]

	run crictl exec $syscont cat "$ctr_path/testfile.txt"
	[ "$status" -eq 0 ]
	[[ "$output" == "new data" ]]

	# Cleanup
	crictl stopp $pod
	crictl rmp $pod
	rm -rf $host_path
	rm -rf $container_json
}

@test "pod hostPath vol (uid-shift)" {

	if ! sysbox_using_uid_shifting; then
		skip "needs Sysbox uid shifting"
	fi

	# Create a dir on the host with root ownership
	local host_path=$(mktemp -d "/mnt/scratch/tmp-vol.XXXXXX")
	echo "some data" > $host_path/testfile.txt

	# Create a pod with a volume mount of that host dir
	local ctr_path="/mnt/test-vol"
	local container_json="/mnt/scratch/container.json"

	jq --arg host_path "$host_path" --arg ctr_path "$ctr_path" \
		'  .mounts = [ {
   			host_path: $host_path,
	   		container_path: $ctr_path
		} ]' \
	   "${POD_MANIFEST_DIR}/alpine-container.json" > "$container_json"

	local syscont=$(crictl_run $container_json ${POD_MANIFEST_DIR}/alpine-pod.json)
	local pod=$(crictl_cont_get_pod $syscont)

	# Verify the volume got mounted and it has the correct ownership
	run crictl exec $syscont cat "$ctr_path/testfile.txt"
	[ "$status" -eq 0 ]
	[[ "$output" == "some data" ]]

	uid=$(crictl exec $syscont stat -c '%u' $ctr_path)
	gid=$(crictl exec $syscont stat -c '%g' $ctr_path)

	[ $uid -eq 0 ]
	[ $gid -eq 0 ]

	# Verify the pod's volume is uid-shifted
	if sysbox_using_shiftfs_only; then
		run crictl exec $syscont sh -c "grep $ctr_path /proc/self/mountinfo | grep shiftfs"
		[ "$status" -eq 0 ]
	elif sysbox_using_idmapped_mnt; then
		run crictl exec $syscont sh -c "grep $ctr_path /proc/self/mountinfo | grep idmapped"
		[ "$status" -eq 0 ]
	fi

	# Verify the pod can write to the mounted host volume
	run crictl exec $syscont sh -c "echo 'new data' > $ctr_path/testfile.txt"
	[ "$status" -eq 0 ]

	run crictl exec $syscont cat "$ctr_path/testfile.txt"
	[ "$status" -eq 0 ]
	[[ "$output" == "new data" ]]

	# Cleanup
	crictl stopp $pod
	crictl rmp $pod
	rm -rf $host_path
	rm -rf $container_json
}

@test "pod hostPath vol (read-only)" {

	# Create a dir on the host with ownership matching the sys container's root
	# process.
	local host_path=$(mktemp -d "/mnt/scratch/tmp-vol.XXXXXX")
	echo "some data" > $host_path/testfile.txt

	subuid=$(grep containers /etc/subuid | cut -d":" -f2)
	subgid=$(grep containers /etc/subgid | cut -d":" -f2)
   chown -R $subuid:$subgid $host_path

	# Create a pod with a volume mount of that host dir
	local ctr_path="/mnt/test-vol"
	local container_json="/mnt/scratch/container.json"

	jq --arg host_path "$host_path" --arg ctr_path "$ctr_path" \
		'  .mounts = [ {
   			host_path: $host_path,
	   		container_path: $ctr_path,
				readonly: true,
		} ]' \
	   "${POD_MANIFEST_DIR}/alpine-container.json" > "$container_json"

	local syscont=$(crictl_run $container_json ${POD_MANIFEST_DIR}/alpine-pod.json)
	local pod=$(crictl_cont_get_pod $syscont)

	# Verify the volume got mounted and it has the correct ownership
	run crictl exec $syscont cat "$ctr_path/testfile.txt"
	[ "$status" -eq 0 ]
	[[ "$output" == "some data" ]]

	uid=$(crictl exec $syscont stat -c '%u' $ctr_path)
	gid=$(crictl exec $syscont stat -c '%g' $ctr_path)

	[ $uid -eq 0 ]
	[ $gid -eq 0 ]

	# Verify the pod can't write to the read-only mounted host volume
	run crictl exec $syscont sh -c "echo 'new data' > $ctr_path/testfile.txt"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Read-only file system"* ]]

	# Cleanup
	crictl stopp $pod
	crictl rmp $pod
	rm -rf $host_path
	rm -rf $container_json
}
