#!/bin/bash

# Default values
TEST_PATH="tests/"
CLIENTS="nethermind,geth,reth"
RUNS=8
IMAGES="default"
OUTPUT_DIR="results/speed"
SIZES=("1" "64" "512")

# Parse command-line options
while getopts "t:c:r:i:o:s:" opt; do
  case $opt in
  t) TEST_PATH="$OPTARG" ;;
  c) CLIENTS="$OPTARG" ;;
  r) RUNS="$OPTARG" ;;
  i) IMAGES="$OPTARG" ;;
  o) OUTPUT_DIR="$OPTARG" ;;
  s) IFS=',' read -ra SIZES <<<"$OPTARG" ;;
  *)
    echo "Usage: $0 [-t test_path] [-c clients] [-r runs] [-i images] [-o output_dir] [-s sizes]" >&2
    exit 1
    ;;
  esac
done

# Split comma-separated values into arrays
IFS=',' read -ra CLIENT_ARRAY <<<"$CLIENTS"
IFS=',' read -ra IMAGE_ARRAY <<<"$IMAGES"

# Create necessary directories
mkdir -p "$OUTPUT_DIR"
mkdir -p "$TEST_PATH/tmp"

# Function to install dependencies
install_dependencies() {
  echo "Installing dependencies..."
  pip install -r requirements.txt
  apt install -y jq
  python3 computer_specs.py --output_folder "$OUTPUT_DIR"
  echo "Dependencies installed."
}

# Function to check if a container is running
check_container_running() {
  local container_name=$1
  local wait_time=$2
  local retries=$3
  local retry_count=0

  while [ $retry_count -lt $retries ]; do
    if [ -z "$(docker ps -q -f name=$container_name)" ]; then
      retry_count=$((retry_count + 1))
      sleep $wait_time
    else
      return 0
    fi
  done
  echo "[ERROR] Container $container_name has stopped unexpectedly after $retries retries."
  return 1
}

# Function to check initialization completion
check_initialization_completed() {
  local client=$1
  local log_entry=$2
  local container_name="gas-execution-client"
  local container_wait_time=1
  local container_check_retries=60
  local log_wait_time=0.5
  local log_check_retries=3600
  local log_retry_count=0

  check_container_running $container_name $container_wait_time $container_check_retries
  if [ $? -ne 0 ]; then
    return 1
  fi

  echo "[INFO] Container $container_name has started."

  log_retry_count=0
  echo "[INFO] Waiting for log entry: '$log_entry' in $container_name..."
  until docker logs $container_name 2>&1 | grep -q "$log_entry"; do
    sleep $log_wait_time
    log_retry_count=$((log_retry_count + 1))

    check_container_running $container_name $container_wait_time $container_check_retries
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

# Function to clean up containers and data
clean_up() {
  echo "[INFO] Cleaning up containers and data..."

  # Check if containers exist before stopping and removing them
  if docker ps -a | grep -q "gas-execution-client"; then
    docker stop gas-execution-client
    docker rm gas-execution-client
  else
    echo "[INFO] Container gas-execution-client not found, skipping stop and remove."
  fi

  if docker ps -a | grep -q "gas-execution-client-sync"; then
    docker stop gas-execution-client-sync
    docker rm gas-execution-client-sync
  else
    echo "[INFO] Container gas-execution-client-sync not found, skipping stop and remove."
  fi

  docker container prune -f
  sudo rm -rf execution-data
  echo "[INFO] Cleanup completed."
}

# Function to calculate new size
calculate_new_size() {
  local size=$1
  new_size=$(echo "scale=2; ($size / 1.2 + 0.5)/1" | bc)
  if [ $? -ne 0 ]; then
    echo "[ERROR] Error calculating new size with bc"
    exit 1
  fi
  echo $new_size
}

# Function to generate necessary JSON files
generate_json_files() {
  local test_path=$1
  local new_size=$2

  python3 generate_chainspec.py $test_path/chainspec.json $test_path/tmp/chainspec.json $new_size
  python3 generate_genesis.py $test_path/genesis.json $test_path/tmp/genesis.json $new_size
  python3 generate_besu.py $test_path/besu.json $test_path/tmp/besu.json $new_size

}

# Function to run the setup and initialization process
run_setup_and_initialization() {
  local client=$1
  local image=$2
  local run=$3
  local size=$4
  local output_file=$5
  local log_entry=$6
  local start_time=$7
  local second_start=$8

  if [ -z "$image" ]; then
    echo "[INFO] Image input is empty, using default image."
    if [ "$second_start" = "true" ]; then
      python3 setup_node.py --client $client --second-start
    else
      python3 setup_node.py --client $client
    fi
  else
    echo "[INFO] Using provided image: $image for $client"
    if [ "$second_start" = "true" ]; then
      python3 setup_node.py --client $client --image $image --second-start
    else
      python3 setup_node.py --client $client --image $image
    fi
  fi

  check_initialization_completed $client "$log_entry"
  if [ $? -ne 0 ]; then
    echo "-1" >"$output_file"
    echo "[ERROR] Initialization check failed for client $client"
    return 1
  fi

  initialization_time=$(($(date +%s%N) / 1000000))
  interval=$((initialization_time - $start_time))
  echo "$interval" >"$output_file"
  echo "[INFO] Interval $interval written to $output_file"

  cd "scripts/$client"
  docker compose down
  clean_up
  cd ../..
}

# Main script execution
install_dependencies

for size in "${SIZES[@]}"; do
  echo "size before conversion: $size" # 调试信息
  new_size=$(calculate_new_size $size)
  generate_json_files $TEST_PATH $new_size
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

      output_file_first="${OUTPUT_DIR}/${client}_${run}_first_${size}M.txt"
      output_file_second="${OUTPUT_DIR}/${client}_${run}_second_${size}M.txt"

      # first init
      start_time=$(($(date +%s%N) / 1000000))
      run_setup_and_initialization $client $image $run $size $output_file_first "$log_entry" $start_time false

      # second init
      start_time=$(($(date +%s%N) / 1000000))
      run_setup_and_initialization $client $image $run $size $output_file_second "$log_entry" $start_time true

    done
  done
done

python3 report_speed.py --resultsPath $OUTPUT_DIR
echo "[INFO] Benchmarking completed and report generated."
