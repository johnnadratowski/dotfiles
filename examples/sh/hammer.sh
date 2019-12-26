#!/bin/bash

hammer() (
	_init() {
		start=$(timestamp)
		throttle_calls=${THROTTLE_CALLS:-0}
		throttle_time=${THROTTLE_TIME:-60}
		concurrency=${CONCURRENCY:-50}
		output_dir=${OUTPUT_DIR:-/tmp}
		output_file=${OUTPUT_FILE:-$output_dir/hammer.$start.tsv}
		open_output=${OPEN_OUTPUT:-0}
		dump_file=${DUMP_FILE:-$output_dir/hammer.$start.dump.tsv}
		server=${SERVER:-"local"}
		iterations=${ITERATIONS:-100}
		iteration_delay=${ITERATION_DELAY:-0.01}
		ulimit_nprocs=${ULIMIT_NPROCS:-0}
		calls=${CALLS:-"$(cat)"}
		if [[ -e calls ]]; then
			calls="$(cat \"$calls\")" # Am I jumpin' around all nimbly bimbly from tree to tree?
		fi

		default_prefix="curl --w '%{http_code}\t%{time_total}\t%{time_connect}\t%{time_namelookup}\t%{time_pretransfer}\t%{time_redirect}\t%{time_starttransfer}\t%{size_download}\t%{size_upload}\t%{size_request}\t%{size_header}\t%{speed_download}\t%{speed_upload}\t%{num_connects}\t%{num_redirects}\t%{redirect_url}\t%{url_effective}'"

		cmd_prefix=${CMD_PREFIX:-$default_prefix}
		counter=1
		cur_throttle_count=0
		num_throttle=0
		declare -a pids

		# Distributed mode variables
		run_local=${RUN_LOCAL:-0}
		payload="$(declare -f hammer)"
		payload+="\\n\\n"
		payload+="export THROTTLE_CALLS=\"${THROTTLE_CALLS}\"\\n"
		payload+="export THROTTLE_TIME=\"${THROTTLE_TIME}\"\\n"
		payload+="export CONCURRENCY=\"${CONCURRENCY}\"\\n"
		payload+="export OUTPUT_FILE=\"${output_file}\"\\n"
		payload+="export DUMP_FILE=\"${dump_file}\"\\n"
		payload+="export ITERATIONS=\"${ITERATIONS}\"\\n"
		payload+="export CALLS=\"${calls}\"\\n"
		payload+="CMD_PREFIX=\"${CMD_PREFIX}\"\\n"
	}

	timestamp_ms() {
	  if which 'python' &> /dev/null; then
		  python -c 'import time; print(int(time.time()*1000))'
	  else
		  date +"%s000"
	  fi
	}

	timestamp() {
	  date +"%s"
	}

	_throttle() {
		if (( throttle_calls > 0 )); then 
			local run_time=$(($(timestamp) - start))
			throttle_count=$((run_time / throttle_time))
			local throttle_reset=$(((cur_throttle_count + 1) * throttle_time))
			# echo "RUNTIME: $run_time, CUR THROTTLE COUNT: $cur_throttle_count, THROTTLE_COUNT: $throttle_count, THROTTLE_RESET: $throttle_reset, NUM_THROTTLE: $num_throttle"

			if (( $throttle_count > $cur_throttle_count )); then
				echo "RESET THROTTLE: $throttle_count > $cur_throttle_count"
				cur_throttle_count=$throttle_count
				num_throttle=0
			fi

			if (( num_throttle >= throttle_calls )); then
				local time_to_throttle=$((throttle_reset - run_time))
				echo "THROTTLING FOR $time_to_throttle seconds"
				sleep $time_to_throttle
				num_throttle=0
			fi
		fi

		if (( $(jobs -pr | wc -l) >= $concurrency )); then
			local pid_to_wait=${pids[$((counter-concurrency))]}
			echo "WAITING FOR PID $pid_to_wait: MAX CONCURRENCY HIT: $counter"
			wait $pid_to_wait
		fi
	}

	_fork_call() {
		local index=$1
		local start_call=$(timestamp_ms)
		local local_dump=$(mktemp)
		local uuid=$(uuidgen)
		if [[ $cmd_prefix == "$default_prefix" ]]; then
			#echo "Running: $cmd_prefix -o $local_dump $call"
			local cmd_output="$(eval "$cmd_prefix -o $local_dump $call" 2> /dev/null)"
			local exit_code=$?
			local end_call=$(timestamp_ms)
			echo "$uuid\t$server\t$index\t$start_call\t$end_call\t$call\t$exit_code\t$cmd_output" >> $output_file
			echo "$uuid\t$server\t$index\t$start_call\t$end_call\t$call\t$exit_code\t$(cat $local_dump)" >> $dump_file
		else
			local time_output
			time_output=$( (time (eval "$cmd_prefix $call" > $local_dump) )2>&1 )
			local exit_code=$?
			cur_time=$(echo $time_output | cat | grep real | cut -f 2 | sed "s/.$//")
			local end_call=$(timestamp_ms)
			echo "$uuid\t$server\t$index\t$start_call\t$end_call\t$call\t$exit_code\t$cur_time" >> $output_file
			echo "$uuid\t$server\t$index\t$start_call\t$end_call\t$call\t$exit_code\t$(cat $local_dump)" >> $dump_file
		fi
		rm -f $local_dump
	}

	_do_call() {

		_throttle

		_fork_call $counter &

		pids[$counter]=$!
		counter=$((counter + 1))
		num_throttle=$((num_throttle + 1))
	}

	_start() {

		if (( $ULIMIT_NPROCS > 0 )); then 
			ulimit -u $ULIMIT_NPROCS || {
				echo "Failed to set ulimit nprocs"
				exit 1
			}
		fi

		if [[ $cmd_prefix == "$default_prefix" ]]; then
			echo "ID\tHammer Server\tIndex\tStart Time (timestamp ms)\tEnd Time (timestamp ms)\tCall\tExit Code\tHTTP Code\tTotal Time (sec)\tTime To Connect (sec)\tTime for Name Lookup (sec)\tTime Pretransfer (sec)\tTime Redirected (sec)\tTime Start Transfer (sec)\tSize Downloaded (bytes)\tSize Uploaded (bytes)\tSize of Request (bytes)\tSize of Header (bytes)\tSpeed of Download (bytes/sec)\tSpeed of Upload (bytes/sec)\tNumber of Connections\tNumber of Redirects\tRedirect URL\tEffective URL" > $output_file
		else
			echo "ID\tHammer Server\tIndex\tStart Time (timestamp ms)\tEnd Time (timestamp ms)\tCall\tExit Code\tTotal Time(sec)" > $output_file
		fi

		echo "HAMMERING with $iterations and max $concurrency concurrency."
		if [[ $throttle_calls -gt 0 ]]; then
			echo "throttling $((throttle_calls / throttle_time)) calls/s."
		fi

		for i in $(seq 1 $iterations); do
			echo "ITERATION: $i"

			while read -r call; do
				_do_call
			done <<< "$calls"

			sleep $iteration_delay
		done

		(( $(jobs -rp |wc -l) > 0 )) && echo "WAITING TO CLEAN UP PROCS" && wait

		local elapsed=$(($(timestamp) - $start))
		echo "Completed $(($counter-1)) calls in $elapsed seconds. Saved output to $output_file and dump to $dump_file."
		if [[ $open_output != 0 ]]; then
			echo "Opening output file: $output_file"
			open $output_file
		fi
	}

	_dist() {
		echo "Distributing load through servers: $@"

		for server in "$@"; do
			local ssh_status="$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=3 $server echo ok 2>&1)"

			if [[ $ssh_status != ok ]] ; then
				echo "Error connecting to server $server: $ssh_status"
				exit 3
			fi
		done

		for server in "$@"; do
			echo "Starting hammer on server $server"
			local server_command="$payload"
			server_command+="export SERVER=\"${server}\"\\n"
			server_command+="\\n"
			server_command+="hammer"
			echo "RUNNING: ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 $server <<-'ENDOFHAMMERBLOCK'
$server_command"
			ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 $server <<-'ENDOFHAMMERBLOCK'
$server_command 
ENDOFHAMMERBLOCK
		done

		if [[ $run_local != 0 ]]; then
			hammer
		fi

		(( $(jobs -rp |wc -l) > 0 )) && echo "WAITING FOR SERVERS TO FINISH" && wait

		for server in "$@"; do
			local outfile=$output_dir/$server.${output_file%*/}
			scp "$server":"$output_file" "$outfile"
			echo "Copied output file from server $server to $outfile"

			local dumpfile=$output_dir/$server.${output_file%*/}
			scp "$server":"$dump_file" "$dumpfile"
			echo "Copied output file from server $server to $dumpfile"
		done
	}

	_help() {
		echo "## hammer v0.1"
		echo "## Copyright (C) John Nadratowski"
		echo "##"
		echo "## Distributed load testing tool. Usage:"
		echo "##     hammer [option] ARGUMENTS..."
		echo "##"
		echo "## Options:"
		echo "##     -h, --help              Show this help."
		exit 0
	}

	_init

	[[ $1 == "--help" || $1 == "-h" ]] && _help
	[[ $1 != "" ]] && _dist "$@"
	[[ $1 == "" ]] && _start
)

