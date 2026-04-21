#!/bin/bash

# ============================================================================
# vLLM Performance Monitor v1.0
# ============================================================================
# A terminal-based monitoring tool for vLLM speculative decoding performance.
# Displays real-time metrics with color-coded bar graphs for:
#   - Avg Draft Acceptance Rate (speculative decoding efficiency)
#   - Avg Generation Throughput (tokens per second)
#
# Features:
#   - Live SSH streaming from remote vLLM container
#   - Color-coded thresholds for quick visual assessment
#   - Memory-efficient log rotation (keeps last 1000 samples)
#   - Filters out idle periods (0.0 values) for accurate averages
#   - Single SSH call per mode for historical data (no double-pulls)
#   - Single-awk main loop for metric parsing
#
# Color Thresholds:
#   Draft Acceptance:  >=70% GREEN, 60-69% YELLOW, <60% RED
#   Generation Throughput: 50-60 PURPLE, >=36 GREEN, 26-35 YELLOW, <26 RED
#
# Requirements:
#   - sshpass (for password-based SSH authentication)
#   - Remote host with Docker containers running vLLM
#   - SSHPASS environment variable set
# ============================================================================

# ----------------------------------------------------------------------------
# CONFIGURATION SECTION
# Adjust these values to customize monitoring behavior
# ----------------------------------------------------------------------------

# SSH connection settings - FORCED via command line, no defaults
SSH_HOST=""
USER=""

# vLLM API settings (optional)
VLLM_URL="http://vllm:8000"                   # vLLM API URL (e.g., http://<host>:8000)

# Display settings
MAX_BAR_LEN=40                  # Length of progress bar in characters
UPDATE_INTERVAL=3               # Seconds between screen updates
MAX_HISTORY=1000                # Maximum samples to keep (prevents memory growth)
MIN_SAMPLES=5                   # Minimum samples before showing data
POLL_INTERVAL=2                 # Seconds between polls when waiting
POLL_CAPTURE_LINES=50           # Lines to capture during polling
NORMAL_CAPTURE_LINES=100        # Lines to capture during normal mode
RESTART_INTERVAL=600            # Self-restart interval in seconds (10 mins)

# ----------------------------------------------------------------------------
# COMMAND-LINE ARGUMENTS
# ----------------------------------------------------------------------------
USE_TMUX=false                  # Force tmux mode (-t)
CUSTOM_CONTAINER=""             # Custom container name (-v)
DEBUG=false                     # Enable debug output (-d)
TARGET=""                       # user@host target (positional argument)
USAGE="Usage: $0 [-t] [-v container_name] [-d] user@host"

# Save all original arguments for self-restart
ALL_ARGS="$*"

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--tmux)
            USE_TMUX=true
            shift
            ;;
        -v|--container)
            CUSTOM_CONTAINER="$2"
            shift 2
            ;;
        -d|--debug)
            DEBUG=true
            shift
            ;;
        -h|--help)
            echo "$USAGE"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            echo "$USAGE"
            exit 1
            ;;
        *)
            # Positional argument: user@host
            TARGET="$1"
            shift
            ;;
    esac
done

# Override SSH_HOST and USER from command line, and enforce mandatory target
if [[ -z "$TARGET" ]]; then
    echo "Error: user@host is required as a positional argument." >&2
    echo "Usage: $0 [-t] [-v container_name] [-d] user@host" >&2
    exit 1
fi
USER="${TARGET%@*}"
SSH_HOST="${TARGET#*@}"

# ----------------------------------------------------------------------------
# TEMPORARY DATA STORAGE
# Files used to store metrics during runtime
# ----------------------------------------------------------------------------

# Create unique temp directory ($$ = current PID for uniqueness)
TEMP_DIR="/tmp/vllm_monitor_v1_$$"
mkdir -p "$TEMP_DIR"

# Data files for each metric (timestamp|value format)
DRAFT_FILE="$TEMP_DIR/draft.log"
THROUGHPUT_FILE="$TEMP_DIR/throughput.log"
LAST_TS_FILE="$TEMP_DIR/last_timestamp.txt"
MODE_FILE="$TEMP_DIR/mode.txt"

# Initialize timestamp file
echo "0" > "$LAST_TS_FILE"

# ----------------------------------------------------------------------------
# SSH CONNECTION OPTIONS
# Security and connectivity configuration
# ----------------------------------------------------------------------------

# These environment variables are inherited by all sshpass/ssh invocations
export SSH_ASKPASS=/dev/null
export SSH_ASKPASS_REQUIRE=never
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR -o ForwardX11=no"
# Note: SSH_ASKPASS prevents interactive prompts, StrictHostKeyChecking=no skips host verification

# ----------------------------------------------------------------------------
# ANSI COLOR CODES
# Terminal color definitions for TUI (Text User Interface)
# ----------------------------------------------------------------------------

GREEN=$'\033[0;32m'       # Good performance / success states
PALE_GREEN=$'\033[0;92m'  # Pale light green for model name
BLUE=$'\033[0;34m'        # Headers and informational text
YELLOW=$'\033[38;5;226m'  # Warning / moderate performance (pure yellow)
ORANGE=$'\033[38;5;208m'  # No data yet / waiting state
RED=$'\033[0;31m'         # Poor performance / critical states
PURPLE=$'\033[0;35m'      # Special metric range (50-60 tok/s)
NC=$'\033[0m'             # No Color (reset to default)

# ----------------------------------------------------------------------------
# INITIALIZATION
# Setup temp files and cleanup handlers
# ----------------------------------------------------------------------------

# Initialize empty data files
: > "$DRAFT_FILE"
: > "$THROUGHPUT_FILE"

# Cleanup function - removes temp files on exit
cleanup() {
    rm -rf "$TEMP_DIR"
    exit 0
}

# Register cleanup to run on script termination signals
trap cleanup SIGINT SIGTERM EXIT

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# detect_model <model_file>
# Queries the vLLM API for the active model name.
# Saves the result to a temp file.
detect_model() {
    local model_file="$1"
    if [[ -n "$VLLM_URL" ]]; then
        local model_api="$VLLM_URL/v1/models"
        local vllm_model
        vllm_model=$(curl -s "$model_api" 2>/dev/null | jq -r '.data[0].id')
        if [[ -z "$vllm_model" ]] || [[ "$vllm_model" == "null" ]]; then
            echo "not detected" > "$model_file"
        else
            echo "$vllm_model" > "$model_file"
        fi
    else
        echo "not detected" > "$model_file"
    fi
}

# extract_metrics_with_timestamps <input> <draft_file> <throughput_file>
# Parses vLLM log content, extracts metrics with timestamps, appends to files
# Timestamp format: MM-DD HH:MM:SS (e.g., 04-20 07:29:28)
extract_metrics_with_timestamps() {
    local input="$1"
    local draft_file="$2"
    local throughput_file="$3"
    local debug_mode="${4:-false}"
    
    if [[ "$debug_mode" == "true" ]]; then
        echo -e "${BLUE}[EXTRACT]${NC} Input sample (first 500 chars):" >&2
        echo "$input" | head -5 | sed 's/\x1b\[[0-9;]*m//g' >&2
        echo -e "${BLUE}[EXTRACT]${NC} Processing lines:" >&2
    fi
    
    echo "$input" | sed 's/\x1b\[[0-9;]*m//g' | \
    awk -v df="$draft_file" -v tf="$throughput_file" -v debug="$debug_mode" '
    {
        draft=""; throughput=""; timestamp=""
        
        # Extract timestamp MM-DD HH:MM:SS format
        if (match($0, /[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
            timestamp = substr($0, RSTART, RLENGTH)
            if (debug == "true") print "  [TIMESTAMP] " timestamp
        }
        
        # Extract draft acceptance rate
        if (match($0,/Avg Draft acceptance rate: *[0-9.]+/)) {
            d=substr($0,RSTART,RLENGTH)
            sub(/.*Avg Draft acceptance rate: */, "", d)
            if (d+0 >= 0.1) {
                draft=d
                if (debug == "true") print "  [DRAFT] " d
            }
        }
        
        # Extract generation throughput
        if (match($0,/generation throughput: *[0-9.]+/)) {
            t=substr($0,RSTART,RLENGTH)
            sub(/.*generation throughput: */, "", t)
            if (t+0 >= 0.1) {
                throughput=t
                if (debug == "true") print "  [THROUGHPUT] " t
            }
        }
        
        # Append to files if we have valid data
        if (draft != "" && timestamp != "") {
            print timestamp "|" draft >> df
        }
        if (throughput != "" && timestamp != "") {
            print timestamp "|" throughput >> tf
        }
    }'
}

# get_latest_timestamp
# Returns the most recent timestamp from data files (or "0" if none)
get_latest_timestamp() {
    local max_ts="0"
    
    # Check draft file
    if [[ -f "$DRAFT_FILE" ]] && [[ -s "$DRAFT_FILE" ]]; then
        local draft_ts=$(tail -1 "$DRAFT_FILE" 2>/dev/null | cut -d'|' -f1)
        if [[ -n "$draft_ts" ]]; then
            max_ts="$draft_ts"
        fi
    fi
    
    # Check throughput file
    if [[ -f "$THROUGHPUT_FILE" ]] && [[ -s "$THROUGHPUT_FILE" ]]; then
        local throughput_ts=$(tail -1 "$THROUGHPUT_FILE" 2>/dev/null | cut -d'|' -f1)
        if [[ -n "$throughput_ts" ]] && [[ "$throughput_ts" > "$max_ts" ]]; then
            max_ts="$throughput_ts"
        fi
    fi
    
    echo "$max_ts"
}

# filter_by_timestamp <cutoff_timestamp>
# Reads from stdin, outputs only lines with timestamp > cutoff
# Timestamp format: MM-DD HH:MM:SS (e.g., 04-20 07:29:28)
filter_by_timestamp() {
    local cutoff="$1"
    
    if [[ "$cutoff" == "0" ]] || [[ -z "$cutoff" ]]; then
        cat
        return
    fi
    
    sed 's/\x1b\[[0-9;]*m//g' | \
    awk -v cutoff="$cutoff" '
    {
        # Extract timestamp MM-DD HH:MM:SS format
        if (match($0, /[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
            ts = substr($0, RSTART, RLENGTH)
            if (ts > cutoff) print $0
        } else {
            # If no timestamp, output the line anyway
            print $0
        }
    }'
}

# count_total_samples
# Returns total number of draft + throughput samples
count_total_samples() {
    local draft_count=0
    local throughput_count=0
    
    [[ -f "$DRAFT_FILE" ]] && draft_count=$(wc -l < "$DRAFT_FILE" 2>/dev/null | tr -d ' ')
    [[ -f "$THROUGHPUT_FILE" ]] && throughput_count=$(wc -l < "$THROUGHPUT_FILE" 2>/dev/null | tr -d ' ')
    
    draft_count=${draft_count:-0}
    throughput_count=${throughput_count:-0}
    
    echo $((draft_count + throughput_count))
}

# render_waiting_screen
# Display simple waiting message
render_waiting_screen() {
    clear
    echo "=========================================="
    echo "     vLLM Performance Monitor v1.0        "
    echo "=========================================="
    echo -e "Time: $(date '+%Y-%m-%d %H:%M:%S') | Duration: $(( $(date +%s) - start_time ))s  "
    echo -e "Host: ${BLUE}${USER}@${SSH_HOST}${NC}"
    detected_model=$(cat "$MODEL_NAME_FILE" 2>/dev/null || echo "not detected")
    echo -e "Model: ${PALE_GREEN}${detected_model}${NC}"
    detected_cn=$(cat "$TEMP_DIR/container_name.txt" 2>/dev/null || echo "")
    echo -e "Node: ${BLUE}${detected_cn}${NC}"
    echo "------------------------------------------"
    echo ""
    echo -e "${ORANGE}** Waiting for vLLM metrics... **${NC}"
    echo ""
    echo "------------------------------------------"
    echo ""
    echo "=========================================="
    printf "${YELLOW}Press Ctrl+C to exit${NC}\n"
    echo "=========================================="
}

# poll_for_data <mode> <container_name>
# Poll for data until MIN_SAMPLES collected
poll_for_data() {
    local mode="$1"
    local container_name="$2"
    
    echo ""
    echo "=========================================="
    echo "  Waiting for vLLM metrics..."
    echo "=========================================="
    echo ""
    
    while true; do
        # Check if we have enough samples
        local total=$(count_total_samples)
        if [[ $total -ge $MIN_SAMPLES ]]; then
            break
        fi
        
        # Render waiting screen
        render_waiting_screen
        
        # Wait before next poll
        sleep $POLL_INTERVAL
        
        # Capture new data
        local raw_hist="/tmp/vllm_raw_poll_$$.tmp"
        : > "$raw_hist"
        
        # Get current timestamp cutoff
        local current_ts=$(cat "$LAST_TS_FILE" 2>/dev/null || echo "0")
        
        if [[ "$mode" == "tmux" ]]; then
            # Capture last N lines from tmux
            sshpass -e ssh $SSH_OPTS "${USER}@${SSH_HOST}" \
                "tmux set-window-option window-size manual; tmux resize-window -x 400 -y 50; tmux capture-pane -t vllm -p -S -$POLL_CAPTURE_LINES -E -1 2>/dev/null" > "$raw_hist"
        else
            # Capture last N lines from docker logs
            sshpass -e ssh $SSH_OPTS "${USER}@${SSH_HOST}" \
                "docker logs --tail $POLL_CAPTURE_LINES ${container_name} 2>&1" 2>/dev/null > "$raw_hist"
        fi
        
        # Filter by timestamp and extract new metrics
        local filtered="/tmp/vllm_filtered_$$.tmp"
        filter_by_timestamp "$current_ts" < "$raw_hist" > "$filtered"
        extract_metrics_with_timestamps "$(cat "$filtered")" "$DRAFT_FILE" "$THROUGHPUT_FILE"
        rm -f "$filtered"
        
        rm -f "$raw_hist"
    done
    
    # Update last timestamp
    local new_ts=$(get_latest_timestamp)
    echo "$new_ts" > "$LAST_TS_FILE"
}

# start_live_stream <mode> <container_name>
# Start continuous streaming based on mode
start_live_stream() {
    local mode="$1"
    local container_name="$2"
    
    if [[ "$mode" == "tmux" ]]; then
        # Continuous tmux capture
        (
            sleep 0.5
            while true; do
                sshpass -e ssh $SSH_OPTS "${USER}@${SSH_HOST}" \
                    "tmux set-window-option window-size manual; tmux resize-window -x 400 -y 50; tmux capture-pane -t vllm -p -S -$NORMAL_CAPTURE_LINES -E -1 2>/dev/null"
                sleep 1
            done
        )
    else
        # Stream live docker logs
        sshpass -e ssh $SSH_OPTS "${USER}@${SSH_HOST}" \
            "docker logs -f --tail 50 ${container_name} 2>&1"
    fi
}

# ============================================================================

# extract_metrics <input_file_or_stream> <jsonl_output_file>
# Parses vLLM log content, extracts draft acceptance and throughput metrics,
# writes matching values to JSONL file, prints match count to stdout.
extract_metrics() {
    local input="$1"
    local output="$2"
    : > "$output"

    echo "$input" | sed 's/\x1b\[[0-9;]*m//g' | \
    awk '{
        draft=""; throughput=""
        if (match($0,/Avg Draft acceptance rate: *[0-9.]+/)) {
            d=substr($0,RSTART,RLENGTH);
            sub(/.*Avg Draft acceptance rate: */, "", d);
            if (d+0 >= 0.1) draft=d
        }
        if (match($0,/generation throughput: *[0-9.]+/)) {
            t=substr($0,RSTART,RLENGTH);
            sub(/.*generation throughput: */, "", t)
            if (t+0 >= 0.1) throughput=t
        }
        if (draft != "" || throughput != "") {
            if (throughput != "") print throughput > "'$output'"
            if (draft != "") print draft > "'$output'"
        }
    }'

    wc -l < "$output" 2>/dev/null | tr -d ' '
}

# ============================================================================
# MAIN EXECUTION STARTS HERE
# ============================================================================

# ----------------------------------------------------------------------------
# SSHPASS DETECTION
# Verify SSHPASS environment variable is set
# ----------------------------------------------------------------------------

if [[ -z "$SSHPASS" ]]; then
    echo "${RED}Error: SSHPASS environment variable not set.${NC}"
    echo "Please set it with: export SSHPASS='your_password'"
    exit 1
fi

# ----------------------------------------------------------------------------
# SSH CONNECTIVITY TEST
# Verify connection before attempting to stream logs
# ----------------------------------------------------------------------------

echo -n "Testing SSH connection... "
if ! sshpass -e ssh $SSH_OPTS "${USER}@${SSH_HOST}" "echo OK" 2>/dev/null | grep -q OK; then
    echo "${RED}FAILED${NC}"
    echo "Please check network connectivity and SSH credentials."
    exit 1
fi
echo "${GREEN}OK${NC}"

# ----------------------------------------------------------------------------
# MODEL DETECTION
# Query vLLM API for active model name
# ----------------------------------------------------------------------------

MODEL_NAME_FILE="$TEMP_DIR/model_name.txt"
detect_model "$MODEL_NAME_FILE"
detected_model=$(cat "$MODEL_NAME_FILE" 2>/dev/null || echo "not detected")

echo "=========================================="
echo "  vLLM Performance Monitor (v1.0)"
echo "=========================================="
echo "Host: ${USER}@${SSH_HOST}"
echo -e "Model: ${PALE_GREEN}${detected_model}${NC}"

echo ""

# ----------------------------------------------------------------------------
# LOG STREAM FUNCTION
# Detects container type and starts streaming logs via SSH
# Implements polling mode when insufficient initial data
# ----------------------------------------------------------------------------
stream_logs() {
    local container_name mode="docker"

    # Step 1: Determine container name and mode
    if [[ "$USE_TMUX" == true ]]; then
        echo -e "${YELLOW}[-]${NC} tmux mode enabled, skipping docker detection..." >&2
        container_name=""
        mode="tmux"
    elif [[ -n "$CUSTOM_CONTAINER" ]]; then
        container_name="$CUSTOM_CONTAINER"
        echo -e "${BLUE}[+]${NC} Using custom container: $container_name" >&2
        mode="docker"
    else
        # Auto-detect: find any vllm* docker container on the remote host
        result=$(sshpass -e ssh $SSH_OPTS "${USER}@${SSH_HOST}" "docker ps 2>/dev/null | grep vllm" 2>/dev/null)
        container_name=$(echo "$result" | tail -1 | awk '{print $NF}')
        if [[ -z "$container_name" ]]; then
            mode="tmux"
            echo -e "${YELLOW}[-]${NC} No vllm container found, falling back to tmux..." >&2
        else
            echo -e "${BLUE}[+]${NC} Detected container: $container_name" >&2
        fi
    fi

    # Save detected container name to temp file for the main loop
    echo "${container_name:-tmux}" > "$TEMP_DIR/container_name.txt" 2>/dev/null

    # ----------------------------------------------------------------------------
    # PRE-LOAD HISTORICAL DATA
    # ----------------------------------------------------------------------------

    raw_hist="/tmp/vllm_raw_hist_$$.tmp"
    : > "$raw_hist"

    echo ""
    echo "=========================================="
    echo "  Pooling historical data..."
    echo "=========================================="

    if [[ "$mode" == "tmux" ]]; then
        echo -n "  Capturing tmux pane history... "

        # Capture last 500 lines from tmux (most recent data)
        sshpass -e ssh $SSH_OPTS "${USER}@${SSH_HOST}" \
            "tmux set-window-option window-size manual; tmux resize-window -x 400 -y 50; tmux capture-pane -t vllm -p -S -500 -E - 2>/dev/null" > "$raw_hist"

        # Debug: show what was captured (only if -d flag is set)
        if [[ "$DEBUG" == true ]]; then
            echo -e "${BLUE}[DEBUG]${NC} Raw capture size: $(wc -c < "$raw_hist") bytes" >&2
            echo -e "${BLUE}[DEBUG]${NC} First 10 raw lines:" >&2
            head -10 "$raw_hist" | cat -A >&2
            echo -e "${BLUE}[DEBUG]${NC} Lines containing 'Draft' or 'throughput':" >&2
            grep -i "draft\|throughput" "$raw_hist" | head -5 >&2
        fi
    else
        echo -n "  Fetching logs from $container_name... "

        # Grab docker logs
        sshpass -e ssh $SSH_OPTS "${USER}@${SSH_HOST}" \
            "docker logs --tail 500 ${container_name} 2>&1" 2>/dev/null > "$raw_hist"
    fi

    # Extract metrics with timestamps
    extract_metrics_with_timestamps "$(cat "$raw_hist")" "$DRAFT_FILE" "$THROUGHPUT_FILE" "$DEBUG"

    # Debug extra info
    if [[ "$DEBUG" == true ]]; then
        echo -e "${BLUE}[EXTRACT]${NC} Raw capture size: $(wc -c < "$raw_hist") bytes" >&2
        echo -e "${BLUE}[EXTRACT]${NC} Draft file lines: $(wc -l < "$DRAFT_FILE")" >&2
        echo -e "${BLUE}[EXTRACT]${NC} Throughput file lines: $(wc -l < "$THROUGHPUT_FILE")" >&2
    fi

    # Debug: show what was extracted
    if [[ "$DEBUG" == true ]]; then
        echo -e "${BLUE}[DEBUG]${NC} Draft file contents:" >&2
        cat "$DRAFT_FILE" >&2
        echo -e "${BLUE}[DEBUG]${NC} Throughput file contents:" >&2
        cat "$THROUGHPUT_FILE" >&2
    fi

    # Get latest timestamp for deduplication
    local latest_ts=$(get_latest_timestamp)
    echo "$latest_ts" > "$LAST_TS_FILE"

    # Count samples
    local total=$(count_total_samples)
    local draft_count=$(wc -l < "$DRAFT_FILE" 2>/dev/null | tr -d ' ')
    local throughput_count=$(wc -l < "$THROUGHPUT_FILE" 2>/dev/null | tr -d ' ')

    echo "${GREEN}OK${NC}"
    echo "=========================================="
    echo "  Draft samples: $draft_count | Throughput samples: $throughput_count | Total: $total"
    echo "=========================================="
    echo ""

    # Clean up intermediate file
    rm -f "$raw_hist"

    # Decide mode based on sample count
    if [[ $total -ge $MIN_SAMPLES ]]; then
        # Enough data - go straight to normal mode
        echo "normal" > "$MODE_FILE"
        echo -e "${BLUE}[+]${NC} Sufficient data found. Starting live monitoring..." >&2
        
        # Output historical lines for main loop
        cat "$TEMP_DIR/draft.log" "$TEMP_DIR/throughput.log" 2>/dev/null | head -20
        
        # Start live stream
        start_live_stream "$mode" "$container_name"
    else
        # Not enough data - enter polling mode
        echo "polling" > "$MODE_FILE"
        echo -e "${YELLOW}[-]${NC} Insufficient data. Entering polling mode (will check every ${POLL_INTERVAL}s)..." >&2
        
        # Poll until we have enough data
        poll_for_data "$mode" "$container_name"
        
        # Now transition to normal mode
        echo "normal" > "$MODE_FILE"
        echo -e "${BLUE}[+]${NC} Threshold reached! Starting live monitoring..." >&2
        
        # Clear screen and start live stream
        clear
        
        # Start live stream
        start_live_stream "$mode" "$container_name"
    fi
}

# ============================================================================
# MAIN MONITORING LOOP
# Processes log lines with timestamp-based deduplication
# ============================================================================

echo "Starting live monitoring..."
echo ""

start_time=$(date +%s)    # Record when monitoring started
last_update=0             # Track last screen refresh time

# Track last processed timestamp for deduplication
last_processed_ts=$(cat "$LAST_TS_FILE" 2>/dev/null || echo "0")

# Infinite loop: reads one line at a time from SSH log stream
while IFS= read -r line; do
    now=$(date +%s)

    # ------------------------------------------------------------------------
    # TIMESTAMP-BASED DEDUPLICATION
    # Skip lines that have already been processed
    # ------------------------------------------------------------------------
    
    # Extract timestamp from line (MM-DD HH:MM:SS format)
    line_ts=$(echo "$line" | sed 's/\x1b\[[0-9;]*m//g' | grep -oE '[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' | tail -1)
    
    # Skip if line has no timestamp
    if [[ -z "$line_ts" ]]; then
        continue
    fi
    
    # Skip if older than last processed
    if [[ ! "$line_ts" > "$last_processed_ts" ]]; then
        continue
    fi
    
    # Update last processed timestamp
    last_processed_ts="$line_ts"
    echo "$last_processed_ts" > "$LAST_TS_FILE"

    # ------------------------------------------------------------------------
    # PARSE METRICS FROM LOG LINE
    # ------------------------------------------------------------------------

    # Strip ANSI escape sequences
    clean_line=$(echo "$line" | sed 's/\x1b\[[0-9;]*m//g')
    
    # Debug: show lines that might contain metrics (only if -d flag is set)
    if [[ "$DEBUG" == true ]]; then
        if [[ "$clean_line" =~ "Draft" ]] || [[ "$clean_line" =~ "throughput" ]]; then
            echo -e "${BLUE}[DEBUG MAIN]${NC} Found metric line: $clean_line" >&2
        fi
    fi

    draft=$(echo "$clean_line" | awk '
        match($0,/Avg Draft acceptance rate: *[0-9.]+/){
            d=substr($0,RSTART,RLENGTH);
            sub(/.*Avg Draft acceptance rate: */, "", d);
            printf "%.1f",d
        }
    ')
    
    throughput=$(echo "$clean_line" | awk '
        match($0,/generation throughput: *[0-9.]+/){
            t=substr($0,RSTART,RLENGTH);
            sub(/.*generation throughput: */, "", t);
            printf "%.1f",t
        }
    ')

    # ------------------------------------------------------------------------
    # STORE NON-ZERO METRICS
    # Only record meaningful values (>=0.1) to exclude idle periods
    # Automates log rotation when MAX_HISTORY is exceeded
    # ------------------------------------------------------------------------

    # Store draft acceptance rate if valid
    if [[ -n "$draft" ]]; then
        if awk -v d="$draft" 'BEGIN{exit !(d >= 0.1)}'; then
            echo "${now}|${draft}" >> "$DRAFT_FILE"
            [[ $(wc -l < "$DRAFT_FILE") -gt $MAX_HISTORY ]] && \
                tail -n $((MAX_HISTORY / 2)) "$DRAFT_FILE" > "$DRAFT_FILE.tmp" && \
                mv "$DRAFT_FILE.tmp" "$DRAFT_FILE"
        fi
    fi

    # Store throughput if valid
    if [[ -n "$throughput" ]]; then
        if awk -v t="$throughput" 'BEGIN{exit !(t >= 0.1)}'; then
            echo "${now}|${throughput}" >> "$THROUGHPUT_FILE"
            [[ $(wc -l < "$THROUGHPUT_FILE") -gt $MAX_HISTORY ]] && \
                tail -n $((MAX_HISTORY / 2)) "$THROUGHPUT_FILE" > "$THROUGHPUT_FILE.tmp" && \
                mv "$THROUGHPUT_FILE.tmp" "$THROUGHPUT_FILE"
        fi
    fi

    # ------------------------------------------------------------------------
    # UPDATE SCREEN PERIODICALLY (every UPDATE_INTERVAL seconds)
    # Calculate averages, generate colored bars, render TUI
    # ------------------------------------------------------------------------

    if [[ $((now - last_update)) -ge $UPDATE_INTERVAL ]]; then
        last_update=$now

        # ----------------------------------------------------------------
        # SELF-RESTART CHECK (every RESTART_INTERVAL seconds)
        # Clears accumulated/truncated data by restarting the monitoring loop
        # ----------------------------------------------------------------
        elapsed=$(( now - start_time ))
        if [[ $elapsed -ge $RESTART_INTERVAL ]]; then
            echo ""
            echo -e "${YELLOW}>> Restarting monitor to refresh data...${NC}"
            exec "$0" $ALL_ARGS
        fi

        # Calculate averages and last-5 trends from data files
        draft_avg=$(tail -n +1 "$DRAFT_FILE" 2>/dev/null | awk -F'|' 'BEGIN{s=0;c=0}{s+=$2;c++}END{if(c>0)printf "%.1f",s/c;else print "0.0"}')
        draft_last5=$(tail -5 "$DRAFT_FILE" 2>/dev/null | awk -F'|' 'BEGIN{s=0;c=0}{s+=$2;c++}END{if(c>0)printf "%.1f",s/c;else print "0.0"}')
        throughput_avg=$(tail -n +1 "$THROUGHPUT_FILE" 2>/dev/null | awk -F'|' 'BEGIN{s=0;c=0}{s+=$2;c++}END{if(c>0)printf "%.1f",s/c;else print "0.0"}')
        throughput_last5=$(tail -5 "$THROUGHPUT_FILE" 2>/dev/null | awk -F'|' 'BEGIN{s=0;c=0}{s+=$2;c++}END{if(c>0)printf "%.1f",s/c;else print "0.0"}')

        # Sanitize values (handle empty/missing)
        draft_avg=${draft_avg:-0.0}
        draft_last5=${draft_last5:-0.0}
        throughput_avg=${throughput_avg:-0.0}
        throughput_last5=${throughput_last5:-0.0}

        # ----------------------------------------------------------------
        # CALCULATE BAR LENGTHS (0-MAX_BAR_LEN based on value)
        # ----------------------------------------------------------------
        read draft_pct throughput_pct <<< $(awk -v d="$draft_avg" -v t="$throughput_avg" -v max="$MAX_BAR_LEN" '
        BEGIN {
            p=int((d/100)*max); if(p<0)p=0; if(p>max)p=max
            q=int((t/100)*max); if(q<0)q=0; if(q>max)q=max
            printf "%d %d", p, q
        }')

        # ----------------------------------------------------------------
        # GENERATE VISUAL BARS (filled: █ | empty: ░)
        # ----------------------------------------------------------------
        draft_bar=$(awk -v p="$draft_pct" -v m="$MAX_BAR_LEN" 'BEGIN{
            for(i=0;i<p;i++)printf"█";
            for(i=p;i<m;i++)printf"░"
        }')
        throughput_bar=$(awk -v p="$throughput_pct" -v m="$MAX_BAR_LEN" 'BEGIN{
            for(i=0;i<p;i++)printf"█";
            for(i=p;i<m;i++)printf"░"
        }')

        # ----------------------------------------------------------------
        # DRAFT ACCEPTANCE COLOR LOGIC
        # Thresholds: >=70% GREEN, 60-69% YELLOW, <60% RED
        # ----------------------------------------------------------------
        draft_color=$(awk -v val="$draft_avg" 'BEGIN{
            if(val>=70) print "\033[0;32m"
            else if(val>=60) print "\033[0;33m"
            else print "\033[0;31m"
        }')

        # ----------------------------------------------------------------
        # GENERATION THROUGHPUT COLOR LOGIC
        # Thresholds: 50-60 PURPLE, >=36 GREEN, 26-35 YELLOW, <26 RED
        # ----------------------------------------------------------------
        throughput_color=$(awk -v val="$throughput_avg" 'BEGIN{
            if(val>=50 && val<=60) print "\033[0;35m"
            else if(val>=36) print "\033[0;32m"
            else if(val>=26) print "\033[38;5;226m"
            else print "\033[0;31m"
        }')

        # ----------------------------------------------------------------
        # RENDER THE COMPLETE TUI
        # ----------------------------------------------------------------
        clear
        echo "=========================================="
    echo "     vLLM Performance Monitor v1.0        "
        echo "=========================================="
        echo -e "Time: $(date '+%Y-%m-%d %H:%M:%S') | Duration: $((now - start_time))s  "
        echo -e "Host: ${BLUE}${USER}@${SSH_HOST}${NC}"
        detected_model=$(cat "$MODEL_NAME_FILE" 2>/dev/null || echo "not detected")
        echo -e "Model: ${PALE_GREEN}${detected_model}${NC}"
        detected_cn=$(cat "$TEMP_DIR/container_name.txt" 2>/dev/null || echo "")
        echo -e "Node: ${BLUE}${detected_cn}${NC}"
        echo "------------------------------------------"
        echo ""

        # Draft Acceptance Rate display
        printf "${BLUE}>>${NC} Avg Draft Acceptance Rate\n"
        printf "    Average: ${GREEN}%5.1f%%${NC}  Last 5: ${YELLOW}%5.1f%%${NC}\n" "$draft_avg" "$draft_last5"
        printf "   ${draft_color}[${draft_bar}]%%${NC}\n"
        echo ""

        # Generation Throughput display
        printf "${BLUE}>>${NC} Avg Generation Throughput\n"
        printf "    Average: ${GREEN}%5.1f${NC} tok/s  Last 5: ${YELLOW}%5.1f${NC} tok/s\n" "$throughput_avg" "$throughput_last5"
        printf "   ${throughput_color}[${throughput_bar}] ${NC}tok/s\n"
        echo ""

        # Persistent orange warning while no data has been collected
        # (Should not happen in normal mode, but kept for safety)
        if [[ "$draft_avg" == "0.0" && "$throughput_avg" == "0.0" ]]; then
            echo -e "${ORANGE}** No data yet... waiting for vLLM metrics... **${NC}"
            echo ""
        fi

        echo "------------------------------------------"
        echo ""
        echo "=========================================="
        printf "${YELLOW}Press Ctrl+C to exit${NC}\n"
        echo "=========================================="

        sleep 1
    fi

done < <(stream_logs)  # Feed SSH log stream into the while loop
