#!/bin/bash

TEST_PATH="tests/"
CLIENTS="nethermind,geth,reth"
RUNS=8
IMAGES="default"
OUTPUT_DIR="results/memory"
SIZES=("1" "64" "512")

while getopts "t:c:r:i:o:s:" opt; do
  case $opt in
    t) TEST_PATH="$OPTARG" ;;
    c) CLIENTS="$OPTARG" ;;
    r) RUNS="$OPTARG" ;;
    i) IMAGES="$OPTARG" ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    s) IFS=',' read -ra SIZES <<< "$OPTARG" ;; 
    *) echo "Usage: $0 [-t test_path] [-c clients] [-r runs] [-i images] [-o output_dir] [-s sizes]" >&2
       exit 1 ;;
  esac
done

IFS=',' read -ra CLIENT_ARRAY <<< "$CLIENTS"
IFS=',' read -ra IMAGE_ARRAY <<< "$IMAGES"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$TEST_PATH/tmp"

# Install dependencies
echo "Installing dependencies..."
pip install -r requirements.txt
apt install -y jq
python3 computer_specs.py --output_folder "$OUTPUT_DIR"
echo "Dependencies installed."

check_initialization_completed() {
  local client=$1
  local log_entry=$2
  local container_name="gas-execution-client"
  local container_wait_time=1 
  local container_check_retries=60
  local log_wait_time=0.5 
  local log_check_retries=3600
  local log_retry_count=0
  local container_retry_count=0

  check_container_running() {
    while [ $container_retry_count -lt $container_check_retries ]; do
      if [ -z "$(docker ps -q -f name=$container_name)" ]; then
        container_retry_count=$((container_retry_count + 1))
        sleep $container_wait_time
      else
        return 0
      fi
    done
    echo "[ERROR] Container $container_name has stopped unexpectedly after $container_check_retries retries."
    return 1
  }

  check_container_running
  if [ $? -ne 0 ]; then
    return 1
  fi

  echo "[INFO] Container $container_name has started."

  log_retry_count=0
  echo "[INFO] Waiting for log entry: '$log_entry' in $container_name..."
  until docker logs $container_name 2>&1 | grep -q "$log_entry"; do
    sleep $log_wait_time
    log_retry_count=$((log_retry_count+1))

    check_container_running
    if [ $? -ne 0 ]; then
      return 1
    fi

    if [ $log_retry_count -ge $log_check_retries ]; then
      echo "[ERROR] Log entry '$log_entry' not found in $container_name within the expected time."
      return 1
    fi
  done

  echo "[INFO] Log entry '$log_entry' found in $container_name."
  return 0
}

monitor_memory_usage() {
  local container_name=$1
  local output_file=$2
  local interval=1
  local max_memory_usage=0
  local error_count=0
  local max_errors=100

  echo -1 > "$output_file"
  echo "[INFO] Starting memory monitoring for $container_name..."
  while true; do
    memory_usage=$(docker stats --no-stream --format "{{.MemUsage}}" $container_name)
    
    if [ -z "$memory_usage" ]; then
      echo "[DEBUG] Failed to get memory usage for $container_name"
      sleep $interval
      continue
    fi

    # Extract current memory usage and its unit
    current_memory=$(echo $memory_usage | awk '{print $1}' | sed 's/[^0-9.]//g')
    unit=$(echo $memory_usage | awk '{print $1}' | sed 's/[0-9.]//g')

    # Remove any commas from the number
    current_memory=$(echo $current_memory | sed 's/,//g')

    # Convert memory to MB
    case $unit in
      kB) current_memory=$(echo "scale=2; $current_memory / 1024" | bc) ;;
      MB) current_memory=$current_memory ;;
      GB) current_memory=$(echo "scale=2; $current_memory * 1024" | bc) ;;
      KiB) current_memory=$(echo "scale=2; $current_memory / 1024" | bc) ;;
      MiB) current_memory=$current_memory ;;
      GiB) current_memory=$(echo "scale=2; $current_memory * 1024" | bc) ;;
      *) 
        echo "[DEBUG] Unknown unit: $unit"
        error_count=$((error_count + 1))
        if [ $error_count -ge $max_errors ]; then
          echo "[ERROR] Too many unknown unit errors. Exiting memory monitoring."
          echo -1 > "$output_file"
          break
        else
          sleep $interval
          continue
        fi
        ;;
    esac
    error_count=0

    current_time=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$current_time] [DEBUG] Read stored memory from file: $stored_memory"

    if [ -f "$output_file" ]; then
      stored_memory=$(cat "$output_file")
    else
      stored_memory=-1
    fi

    if (( $(echo "$current_memory > $max_memory_usage" | bc -l) )); then
      max_memory_usage=$current_memory
      if (( $(echo "$max_memory_usage > $stored_memory" | bc -l) )); then
        echo "$max_memory_usage" > "$output_file"
      fi
    fi
    sleep $interval
  done &
  monitor_pid=$!
  trap "kill $monitor_pid" EXIT
  echo "[INFO] Memory monitoring for $container_name with PID $monitor_pid started."
}

stop_memory_monitor() {
  kill $monitor_pid
  wait $monitor_pid 2>/dev/null
}

clean_up() {
  echo "[INFO] Cleaning up containers and data..."
  docker stop gas-execution-client gas-execution-client-sync
  docker rm gas-execution-client gas-execution-client-sync
  docker container prune -f
  sudo rm -rf execution-data
  echo "[INFO] Cleanup completed."
}

for size in "${SIZES[@]}"; do

  echo "[INFO] Calculating new size for $size"
  new_size=$(echo "scale=2; ($size / 1.2 + 0.5)/1" | bc)
  if [ $? -ne 0 ]; then
    echo "[ERROR] Error calculating new size with bc"
    exit 1
  fi
  echo "[INFO] New size calculated: $new_size"

  # 用 tests/xxx.json 作为模板随机生成测试genesis.json
  python3 generate_chainspec.py $TEST_PATH/chainspec.json $TEST_PATH/tmp/chainspec.json $new_size
  python3 generate_genesis.py $TEST_PATH/genesis.json $TEST_PATH/tmp/genesis.json $new_size
  python3 generate_besu.py $TEST_PATH/besu.json $TEST_PATH/tmp/besu.json $new_size

  clean_up

  for run in $(seq 1 $RUNS); do
    for I in "${!CLIENT_ARRAY[@]}"; do
      echo "--------------------------------------"
      echo "[INFO] Run size ${size}M round $run - Client ${CLIENT_ARRAY[$I]} - Image ${IMAGE_ARRAY[$I]}"
      echo "--------------------------------------"

      client="${CLIENT_ARRAY[$I]}"
      image="${IMAGE_ARRAY[$I]}"

      case $client in
        nethermind) log_entry="initialization completed" ;;
        reth) log_entry="Starting reth" ;;
        erigon) log_entry="logging to file system" ;;
        geth) log_entry="Set global gas cap" ;;
        besu) log_entry="Writing node record to disk" ;;
      esac

      cd "scripts/$client"
      docker compose down --remove-orphans
      clean_up
      cd ../..

      memory_output_file="${OUTPUT_DIR}/${client}_${run}_first_${size}M.txt"
      if [[ "$client" == "nethermind" || "$client" == "besu" ]]; then
        monitor_memory_usage "gas-execution-client" $memory_output_file
      else
        monitor_memory_usage "gas-execution-client-sync" $memory_output_file
      fi

      if [ -z "$image" ]; then
        echo "[INFO] Image input is empty, using default image."
        python3 setup_node.py --client $client
      else
        echo "[INFO] Using provided image: $image for $client"
        python3 setup_node.py --client $client --image $image
      fi

      echo "[DEBUG] First start sleeping for 10 seconds..."
      sleep 10
      check_initialization_completed $client "$log_entry"
      if [ $? -ne 0 ]; then
        stop_memory_monitor
        echo "[ERROR] Initialization check failed for client $client"
        echo "-1" > "$memory_output_file"
        continue
      fi
      stop_memory_monitor

      cd "scripts/$client"
      docker compose stop
      clean_up
      cd ../..

      memory_output_file="${OUTPUT_DIR}/${client}_${run}_second_${size}M.txt"
      monitor_memory_usage "gas-execution-client" $memory_output_file

      if [ -z "$image" ]; then
        echo "[INFO] Image input is empty, using default image."
        python3 setup_node.py --client $client --second-start
      else
        echo "[INFO] Using provided image: $image for $client"
        python3 setup_node.py --client $client --image $image --second-start
      fi

      echo "[DEBUG] Second start sleeping for 10 seconds..."
      sleep 10
      check_initialization_completed $client "$log_entry"
      if [ $? -ne 0 ]; then
        stop_memory_monitor
        echo "[ERROR] Initialization check failed for client $client"
        echo "-1" > "$memory_output_file"
        continue
      fi
      stop_memory_monitor

      cd "scripts/$client"
      docker compose down --remove-orphans
      clean_up
      cd ../..
    done
  done
done

python3 report_memory.py --resultsPath $OUTPUT_DIR
echo "[INFO] Benchmarking completed and report generated."