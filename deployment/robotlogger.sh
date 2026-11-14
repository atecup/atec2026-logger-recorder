#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
script_path="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
project_dir="$(cd "${script_dir}/.." && pwd)"
default_user_config="${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/robotlogger/robotlogger.conf"
config_path="${ROBOTLOGGER_CONFIG:-${default_user_config}}"
action="record"
as_root=0
cli_robot_id=""
cli_ros_setup=""
cli_workspace=""
cli_domain=""
cli_rmw=""
cli_ssd=""
cli_data=""
cli_storage=""
cli_expected_topics=()
info_path=""
full_integrity=0

usage() {
  cat <<'EOF'
Usage: robotlogger.sh [record|check|status|info|audit] [options]

  record (default)  Validate ROS/DDS/topics/SSD, then record until Ctrl-C
  check             Run preflight checks without recording
  status            Show active recorder processes and newest bag folders
  info BAG_DIR      Show metadata for a completed bag
  audit BAG_DIR     Check database integrity, per-topic rates/gaps, and header lag
    --full-integrity  Use SQLite integrity_check instead of faster quick_check

Options (only needed when auto-detection is insufficient):
  --config FILE     One-time per-robot config (default: ~/.config/robotlogger/robotlogger.conf)
  --robot-id ID     Bag folder identifier
  --ros-setup FILE  ROS setup.bash path
  --workspace FILE  Adapter/interface setup.bash path
  --domain ID       ROS_DOMAIN_ID
  --rmw NAME        RMW implementation
  --ssd PATH        Mounted SSD path
  --data PATH       Bag root, must be inside the SSD mount
  --storage ID      sqlite3 or an installed rosbag2 storage plugin
  --topic NAME      Whitelisted topic that may start later; repeat as needed
  -h, --help        Show this help
EOF
}

while (($#)); do
  case "$1" in
    record|check|status|info|audit|__root_record)
      if [[ "$1" == "__root_record" ]]; then as_root=1; action=record; else action="$1"; fi
      shift
      if [[ ("$action" == "info" || "$action" == "audit") && $# -gt 0 && "$1" != --* ]]; then info_path="$1"; shift; fi
      ;;
    --config) config_path="${2:?missing value for --config}"; shift 2 ;;
    --robot-id) cli_robot_id="${2:?missing value for --robot-id}"; shift 2 ;;
    --ros-setup) cli_ros_setup="${2:?missing value for --ros-setup}"; shift 2 ;;
    --workspace) cli_workspace="${2:?missing value for --workspace}"; shift 2 ;;
    --domain) cli_domain="${2:?missing value for --domain}"; shift 2 ;;
    --rmw) cli_rmw="${2:?missing value for --rmw}"; shift 2 ;;
    --ssd) cli_ssd="${2:?missing value for --ssd}"; shift 2 ;;
    --data) cli_data="${2:?missing value for --data}"; shift 2 ;;
    --storage) cli_storage="${2:?missing value for --storage}"; shift 2 ;;
    --topic) cli_expected_topics+=("${2:?missing value for --topic}"); shift 2 ;;
    --full-integrity) full_integrity=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

interactive=0
if [[ -t 0 ]]; then interactive=1; fi
save_config_value() {
  local key="$1" value="$2" config_dir
  [[ -n "${config_path}" ]] || return 0
  config_dir="$(dirname "${config_path}")"
  mkdir -p "${config_dir}" 2>/dev/null || {
    echo "Cannot save ${key} to ${config_path}; use --config in a writable location." >&2
    return 1
  }
  touch "${config_path}" 2>/dev/null || {
    echo "Cannot save ${key} to ${config_path}; use --config in a writable location." >&2
    return 1
  }
  # Appending lets the most recent answer override earlier config values
  # without relying on platform-specific sed escaping.
  printf '%s=%q\n' "${key}" "${value}" >>"${config_path}"
}
prompt_value() {
  local key="$1" label="$2" current="$3" answer=""
  if (( ! interactive )); then
    echo "Missing ${key}: ${label}. Set it in ${config_path} or pass the matching command-line option." >&2
    return 1
  fi
  printf '%s' "${label} [${current}]: " >&2
  IFS= read -r answer || answer=""
  [[ -n "${answer}" ]] || answer="${current}"
  [[ -n "${answer}" ]] || return 1
  printf '%s' "${answer}"
}
is_ros2_setup() {
  local candidate="$1" version=""
  version="$(bash -c 'set +u; source "$1" >/dev/null 2>&1; printf "%s" "${ROS_VERSION:-}"' _ "${candidate}" 2>/dev/null || true)"
  [[ "${version}" == "2" ]]
}

# Do not inherit an interactive shell's DDS XML implicitly. If a robot needs
# one, it must be set explicitly in the optional logger config file.
unset CYCLONEDDS_URI || true
# Config is sourced once per invocation. CLI values override config and the
# small set of explicitly supported environment overrides.
if [[ -r "${config_path}" ]]; then
  # shellcheck disable=SC1090
  source "${config_path}"
fi
domain_was_configured=0
if [[ -n "${cli_domain}" ]] || { [[ -r "${config_path}" ]] && grep -Eq '^[[:space:]]*ROS_DOMAIN_ID=' "${config_path}"; }; then
  domain_was_configured=1
fi
ROBOT_ID="${cli_robot_id:-${ROBOT_ID:-}}"
ROS_SETUP="${cli_ros_setup:-${ROS_SETUP:-}}"
ROS_WORKSPACE_SETUP="${cli_workspace:-${ROS_WORKSPACE_SETUP:-}}"
ROS_DOMAIN_ID="${cli_domain:-${ROS_DOMAIN_ID:-}}"
RMW_IMPLEMENTATION="${cli_rmw:-${RMW_IMPLEMENTATION:-}}"
SSD_MOUNT="${cli_ssd:-${SSD_MOUNT:-}}"
DATA_ROOT="${cli_data:-${DATA_ROOT:-}}"
STORAGE_ID="${cli_storage:-${STORAGE_ID:-sqlite3}}"
EXPECTED_TOPICS="${EXPECTED_TOPICS:-}"
TOPIC_REGEX_FILE="${TOPIC_REGEX_FILE:-${script_dir}/topics.regex}"
MIN_FREE_BYTES="${MIN_FREE_BYTES:-10737418240}"
SPLIT_BYTES="${SPLIT_BYTES:-1073741824}"
MAX_CACHE_SIZE="${MAX_CACHE_SIZE:-0}"
SPACE_CHECK_SECONDS="${SPACE_CHECK_SECONDS:-15}"

g1_workspace="${project_dir}/players/unitree_g1_adapter/install/setup.bash"
is_g1=0
if [[ -r "${g1_workspace}" ]]; then is_g1=1; fi
if [[ -z "${ROBOT_ID}" ]]; then
  if (( is_g1 )); then ROBOT_ID=g1; else ROBOT_ID="$(hostname -s)"; fi
fi
if [[ -z "${ROS_DOMAIN_ID}" ]]; then
  if (( is_g1 )); then ROS_DOMAIN_ID=1; else ROS_DOMAIN_ID=0; fi
fi
if (( ! domain_was_configured && interactive )); then
  ROS_DOMAIN_ID="$(prompt_value ROS_DOMAIN_ID "ROS_DOMAIN_ID（回车使用默认值）" "${ROS_DOMAIN_ID}")" || exit 70
  save_config_value ROS_DOMAIN_ID "${ROS_DOMAIN_ID}"
fi
[[ "${ROS_DOMAIN_ID}" =~ ^[0-9]+$ ]] && (( ROS_DOMAIN_ID <= 232 )) || {
  echo "ROS_DOMAIN_ID must be an integer from 0 to 232." >&2
  exit 64
}
if [[ -n "${ROS_SETUP}" && -r "${ROS_SETUP}" ]] && ! is_ros2_setup "${ROS_SETUP}"; then
  echo "Configured ROS setup is not ROS 2: ${ROS_SETUP}" >&2
  ROS_SETUP=""
fi
if [[ -z "${ROS_SETUP}" || ! -r "${ROS_SETUP}" ]]; then
  ROS_SETUP=""
  ros_setup_candidates=()
  for candidate in /opt/ros/*/setup.bash; do
    if [[ -r "${candidate}" ]] && is_ros2_setup "${candidate}"; then
      ros_setup_candidates+=("${candidate}")
    fi
  done
  if [[ -n "${ROS_DISTRO:-}" && -r "/opt/ros/${ROS_DISTRO}/setup.bash" ]] && is_ros2_setup "/opt/ros/${ROS_DISTRO}/setup.bash"; then
    ROS_SETUP="/opt/ros/${ROS_DISTRO}/setup.bash"
  elif ((${#ros_setup_candidates[@]} == 1)); then
    ROS_SETUP="${ros_setup_candidates[0]}"
  elif ((${#ros_setup_candidates[@]} > 1)); then
    echo "Detected multiple ROS installations:" >&2
    printf '  %s\n' "${ros_setup_candidates[@]}" >&2
    if (( interactive )); then
      ROS_SETUP="$(prompt_value ROS_SETUP "选择与 adapter/interface workspace 对应的 setup.bash 完整路径" "")" || exit 66
      [[ -r "${ROS_SETUP}" ]] || { echo "ROS setup is unreadable: ${ROS_SETUP}" >&2; exit 66; }
      save_config_value ROS_SETUP "${ROS_SETUP}"
    else
      echo "Set ROS_SETUP in ${config_path} or provide --ros-setup." >&2
      exit 66
    fi
  fi
fi
if [[ -z "${ROS_SETUP}" || ! -r "${ROS_SETUP}" ]]; then
  ROS_SETUP="$(prompt_value ROS_SETUP "ROS setup.bash 的完整路径" "")" || exit 66
  [[ -r "${ROS_SETUP}" ]] || { echo "ROS setup is unreadable: ${ROS_SETUP}" >&2; exit 66; }
  save_config_value ROS_SETUP "${ROS_SETUP}"
fi
if [[ -z "${ROS_WORKSPACE_SETUP}" ]] && (( is_g1 )); then ROS_WORKSPACE_SETUP="${g1_workspace}"; fi
if [[ -n "${ROS_WORKSPACE_SETUP}" && ! -r "${ROS_WORKSPACE_SETUP}" ]]; then
  echo "Interface workspace is unreadable: ${ROS_WORKSPACE_SETUP}" >&2
  ROS_WORKSPACE_SETUP="$(prompt_value ROS_WORKSPACE_SETUP "选手 adapter 编译后的 install/setup.bash 路径" "")" || exit 66
  [[ -r "${ROS_WORKSPACE_SETUP}" ]] || { echo "Interface workspace is unreadable: ${ROS_WORKSPACE_SETUP}" >&2; exit 66; }
  save_config_value ROS_WORKSPACE_SETUP "${ROS_WORKSPACE_SETUP}"
fi
if [[ -z "${SSD_MOUNT}" ]]; then
  if command -v mountpoint >/dev/null 2>&1 && mountpoint -q /mnt/robot-ssd; then
    SSD_MOUNT=/mnt/robot-ssd
  else
    SSD_MOUNT=""
  fi
fi
if [[ -z "${SSD_MOUNT}" ]]; then
  SSD_MOUNT="$(prompt_value SSD_MOUNT "SSD 挂载目录（例如 /mnt/robot-ssd）" "/mnt/robot-ssd")" || exit 74
  save_config_value SSD_MOUNT "${SSD_MOUNT}"
fi
if command -v mountpoint >/dev/null 2>&1 && ! mountpoint -q "${SSD_MOUNT}"; then
  echo "${SSD_MOUNT} 不是已挂载的文件系统；请先挂载 SSD 后重试." >&2
  exit 74
fi
if [[ -z "${DATA_ROOT}" ]]; then
  DATA_ROOT="$(prompt_value DATA_ROOT "rosbag 写入 SSD 的目录" "${SSD_MOUNT}/rosbags")" || exit 74
  save_config_value DATA_ROOT "${DATA_ROOT}"
fi
if [[ ! "${ROBOT_ID}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "ROBOT_ID may contain only letters, digits, dot, underscore, and dash." >&2
  exit 64
fi

if [[ "${action}" == "status" ]]; then
  echo "Active recorder:"
  pgrep -af 'ros2 bag record' || true
  echo "Recent bag folders:"
  if [[ -d "${DATA_ROOT}/${ROBOT_ID}" ]]; then ls -lt "${DATA_ROOT}/${ROBOT_ID}" | head -8; else echo "None yet."; fi
  exit 0
fi

set +u
source "${ROS_SETUP}"
set -u
export ROS_DOMAIN_ID RMW_IMPLEMENTATION
RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-}"
if [[ -z "${RMW_IMPLEMENTATION}" ]]; then
  if compgen -G "/opt/ros/*/lib/librmw_cyclonedds_cpp.so" >/dev/null; then
    RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
  else
    RMW_IMPLEMENTATION=rmw_fastrtps_cpp
  fi
  export RMW_IMPLEMENTATION
fi
if [[ -n "${CYCLONEDDS_URI:-}" ]]; then export CYCLONEDDS_URI; else unset CYCLONEDDS_URI || true; fi
source_workspace_setup() {
  [[ -n "${ROS_WORKSPACE_SETUP}" ]] || return 0
  set +u
  source "${ROS_WORKSPACE_SETUP}"
  set -u
  # Some Foxy deployments have incomplete generated hooks on exFAT installs.
  # Explicitly expose the merged prefix so ros2 CLI and rosbag can find typesupport.
  workspace_prefix="$(cd "$(dirname "${ROS_WORKSPACE_SETUP}")" && pwd -P)"
  export AMENT_PREFIX_PATH="${workspace_prefix}${AMENT_PREFIX_PATH:+:${AMENT_PREFIX_PATH}}"
  export CMAKE_PREFIX_PATH="${workspace_prefix}${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}"
  export LD_LIBRARY_PATH="${workspace_prefix}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
}
source_workspace_setup

if [[ "${action}" == "info" ]]; then
  [[ -n "${info_path}" ]] || { echo "Pass a completed bag directory to info." >&2; exit 64; }
  ros2 bag info "${info_path}"
  exit $?
fi
if [[ "${action}" == "audit" ]]; then
  [[ -n "${info_path}" ]] || { echo "Pass a closed bag directory to audit." >&2; exit 64; }
  ros2 bag info "${info_path}" >/dev/null || { echo "rosbag2 cannot read this bag metadata." >&2; exit 1; }
  audit_args=("${project_dir}/tools/audit_bag.py" "${info_path}")
  if (( full_integrity )); then audit_args+=(--full-integrity); fi
  python3 "${audit_args[@]}"
  exit $?
fi

for value in "${MIN_FREE_BYTES}" "${SPLIT_BYTES}" "${SPACE_CHECK_SECONDS}" "${MAX_CACHE_SIZE}"; do
  [[ "${value}" =~ ^[0-9]+$ ]] || { echo "Numeric config values must be non-negative integers." >&2; exit 64; }
done
(( SPLIT_BYTES > 0 && SPACE_CHECK_SECONDS > 0 )) || { echo "SPLIT_BYTES and SPACE_CHECK_SECONDS must be positive." >&2; exit 64; }
[[ -r "${TOPIC_REGEX_FILE}" ]] || { echo "Topic whitelist is unreadable: ${TOPIC_REGEX_FILE}" >&2; exit 66; }
[[ -d "${SSD_MOUNT}" ]] || { echo "SSD path does not exist: ${SSD_MOUNT}" >&2; exit 74; }
ssd_real="$(realpath -e "${SSD_MOUNT}")"
data_real="$(realpath -m "${DATA_ROOT}")"
case "${data_real}/" in "${ssd_real}/"*) ;; *) echo "Bag root must be inside SSD mount." >&2; exit 64 ;; esac
available_bytes="$(df -P -B1 "${SSD_MOUNT}" | awk 'NR == 2 {print $4}')"
[[ "${available_bytes}" =~ ^[0-9]+$ ]] || { echo "Could not read SSD free space." >&2; exit 74; }
(( available_bytes >= MIN_FREE_BYTES )) || { echo "SSD has only ${available_bytes} bytes free; minimum is ${MIN_FREE_BYTES}." >&2; exit 75; }

command -v ros2 >/dev/null 2>&1 || { echo "ros2 command is missing after sourcing ROS." >&2; exit 69; }
topic_tmp="/tmp/robotlogger-topics.$$.txt"
dds_err="/tmp/robotlogger-dds.$$.err"
query_ros_graph() {
  if timeout 12s ros2 topic list >"${topic_tmp}" 2>"${dds_err}"; then return 0; fi
  return 1
}
topic_regex="$(grep -Ev '^[[:space:]]*(#|$)' "${TOPIC_REGEX_FILE}" | paste -sd '|' -)"
expected_topics=()
if [[ -n "${EXPECTED_TOPICS}" ]]; then read -r -a expected_topics <<<"${EXPECTED_TOPICS}"; fi
expected_topics+=("${cli_expected_topics[@]}")
load_matching_topics() {
  mapfile -t topics < <(grep -E "${topic_regex}" "${topic_tmp}" | sort -u)
}
if ! query_ros_graph; then
  if (( interactive )); then
    cat "${dds_err}" >&2 || true
    ROS_DOMAIN_ID="$(prompt_value ROS_DOMAIN_ID "机器人 ROS_DOMAIN_ID" "${ROS_DOMAIN_ID}")" || exit 70
    export ROS_DOMAIN_ID
    save_config_value ROS_DOMAIN_ID "${ROS_DOMAIN_ID}"
    if ! query_ros_graph; then
      cat "${dds_err}" >&2 || true
      RMW_IMPLEMENTATION="$(prompt_value RMW_IMPLEMENTATION "RMW 实现（如 rmw_cyclonedds_cpp）" "${RMW_IMPLEMENTATION}")" || exit 70
      export RMW_IMPLEMENTATION
      save_config_value RMW_IMPLEMENTATION "${RMW_IMPLEMENTATION}"
      query_ros_graph || { cat "${dds_err}" >&2 || true; echo "DDS discovery still failed. Check the ROS installation and DDS interface configuration." >&2; exit 70; }
    fi
  else
    cat "${dds_err}" >&2 || true
    rm -f "${topic_tmp}" "${dds_err}"
    echo "DDS discovery failed. Set ROS_DOMAIN_ID/RMW in ${config_path} or run from an interactive terminal to configure them." >&2
    exit 70
  fi
fi
load_matching_topics
has_lidar_topic=0
has_camera_topic=0
if printf '%s\n' "${topics[@]}" "${expected_topics[@]}" | grep -Eq '^/points_downsampled_[^/]+$'; then has_lidar_topic=1; fi
if printf '%s\n' "${topics[@]}" "${expected_topics[@]}" | grep -Eq '^/image_compressed_[^/]+$'; then has_camera_topic=1; fi
if (( ! has_lidar_topic || ! has_camera_topic )); then
  if (( interactive )); then
    echo "Sensor topic IDs cannot be inferred while their publishers are absent." >&2
    printf 'Enter any late sensor topic names now (space-separated, or press Enter if adapter advertises them at startup): ' >&2
    IFS= read -r -a prompted_topics || prompted_topics=()
    expected_topics+=("${prompted_topics[@]}")
    if ((${#prompted_topics[@]})); then
      for expected_topic in "${prompted_topics[@]}"; do
        [[ "${expected_topic}" =~ ^/[A-Za-z0-9_/]+$ ]] && grep -Eq "${topic_regex}" <<<"${expected_topic}" || {
          echo "Topic is invalid or outside the official whitelist: ${expected_topic}" >&2
          exit 64
        }
      done
      save_config_value EXPECTED_TOPICS "${expected_topics[*]}"
    fi
  fi
fi
for expected_topic in "${expected_topics[@]}"; do
  [[ "${expected_topic}" =~ ^/[A-Za-z0-9_/]+$ ]] && grep -Eq "${topic_regex}" <<<"${expected_topic}" || {
    echo "Configured topic is invalid or outside the official whitelist: ${expected_topic}" >&2
    exit 64
  }
done
EXPECTED_TOPICS="${expected_topics[*]}"
if (( ${#topics[@]} == 0 )); then
  echo "No whitelisted topics are advertised yet in ROS_DOMAIN_ID=${ROS_DOMAIN_ID}; fixed contract topics can still be discovered after recording starts." >&2
  if [[ -s "${topic_tmp}" ]]; then
    echo "Currently visible ROS topics:" >&2
    sed 's/^/  /' "${topic_tmp}" >&2
  fi
fi
rm -f "${topic_tmp}" "${dds_err}"

# Custom message types must be installed and sourced so rosbag2 can create
# subscriptions. Ask once for the team's install/setup.bash when auto-detection
# did not make those type definitions available.
declare -A seen_types=()
check_message_types() {
  unresolved_types=()
  seen_types=()
  for topic in "${topics[@]}"; do
    msg_type="$(timeout 4s ros2 topic type "${topic}" 2>/dev/null || true)"
    if [[ -z "${msg_type}" ]]; then unresolved_types+=("${topic} (type unavailable)"); continue; fi
    [[ -z "${seen_types[${msg_type}]+x}" ]] || continue
    seen_types["${msg_type}"]=1
    if ! ros2 interface show "${msg_type}" >/dev/null 2>&1; then unresolved_types+=("${msg_type}"); fi
  done
}
check_message_types
if ((${#unresolved_types[@]})); then
  printf 'Interface type support missing for: %s\n' "${unresolved_types[*]}" >&2
  if [[ -n "${ROS_WORKSPACE_SETUP}" ]]; then
    echo "Current workspace did not provide these message definitions: ${ROS_WORKSPACE_SETUP}" >&2
  fi
  ROS_WORKSPACE_SETUP="$(prompt_value ROS_WORKSPACE_SETUP "选手 adapter 编译后的 install/setup.bash 路径" "${ROS_WORKSPACE_SETUP}")" || exit 66
  [[ -r "${ROS_WORKSPACE_SETUP}" ]] || { echo "Interface workspace is unreadable: ${ROS_WORKSPACE_SETUP}" >&2; exit 66; }
  source_workspace_setup
  save_config_value ROS_WORKSPACE_SETUP "${ROS_WORKSPACE_SETUP}"
  check_message_types
  if ((${#unresolved_types[@]})); then
    echo "Still missing interface types: ${unresolved_types[*]}. Build/install the team's interface package, then retry." >&2
    exit 66
  fi
fi

missing_topics=()
for must in /joint_states /robot_state /motion_state /nav_state; do
  if ! printf '%s\n' "${topics[@]}" | grep -Fxq "${must}"; then missing_topics+=("${must}"); fi
done
if ! printf '%s\n' "${topics[@]}" | grep -Eq '^/(grasp_state|manipulation_state)$'; then
  missing_topics+=("/grasp_state or /manipulation_state")
fi
if ! printf '%s\n' "${topics[@]}" | grep -Eq '^/points_downsampled_[^/]+$'; then
  missing_topics+=("/points_downsampled_<id>")
fi
if ! printf '%s\n' "${topics[@]}" | grep -Eq '^/image_compressed_[^/]+$'; then
  missing_topics+=("/image_compressed_<id>")
fi

late_custom_topics=()
for custom_topic in /robot_state /nav_state /motion_state; do
  if ! printf '%s\n' "${topics[@]}" | grep -Fxq "${custom_topic}"; then late_custom_topics+=("${custom_topic}"); fi
done
if ! printf '%s\n' "${topics[@]}" | grep -Eq '^/(grasp_state|manipulation_state)$'; then
  late_custom_topics+=("/grasp_state or /manipulation_state")
fi
if [[ -z "${ROS_WORKSPACE_SETUP}" ]] && ((${#late_custom_topics[@]})); then
  if (( interactive )); then
    printf 'Late custom state topics may need ROS interface type support (%s). Enter the adapter install/setup.bash path, or press Enter if their types are in the ROS underlay: ' "${late_custom_topics[*]}" >&2
    IFS= read -r late_workspace || late_workspace=""
    if [[ -n "${late_workspace}" ]]; then
      [[ -r "${late_workspace}" ]] || { echo "Interface workspace is unreadable: ${late_workspace}" >&2; exit 66; }
      ROS_WORKSPACE_SETUP="${late_workspace}"
      source_workspace_setup
      save_config_value ROS_WORKSPACE_SETUP "${ROS_WORKSPACE_SETUP}"
    else
      echo "No interface workspace supplied; late custom message topics may not be recordable." >&2
    fi
  else
    echo "Late custom state topics may need type support; set ROS_WORKSPACE_SETUP or pass --workspace before recording." >&2
  fi
fi

clock_sync="unknown"
if command -v timedatectl >/dev/null 2>&1; then
  clock_sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
fi

if [[ "${action}" == "check" ]]; then
  printf 'ROS: %s | domain: %s | RMW: %s\n' "${ROS_SETUP}" "${ROS_DOMAIN_ID}" "${RMW_IMPLEMENTATION}"
  printf 'SSD: %s | free: %s bytes | robot: %s\n' "${SSD_MOUNT}" "${available_bytes}" "${ROBOT_ID}"
  if [[ "${clock_sync}" == "yes" ]]; then echo "System clock sync: yes";
  else echo "WARNING: system clock synchronization is not confirmed; verify sensor/host time alignment."; fi
  printf 'Matched %d topics:\n' "${#topics[@]}"
  if ((${#topics[@]})); then printf '  %s\n' "${topics[@]}"; else echo "  (none advertised yet)"; fi
  if ((${#missing_topics[@]})); then
    printf 'Not advertised yet: %s\n' "${missing_topics[*]}" >&2
    echo "Preflight continues; fixed-name contract topics will be watched after recording starts." >&2
  fi
  if ((${#expected_topics[@]})); then printf 'Configured late topics to watch: %s\n' "${expected_topics[*]}"; fi
  echo "Preflight complete. A successful check confirms the recorder environment, not that publishers are already sending messages."
  exit 0
fi

# Perform discovery and any interactive configuration as the operator, then
# elevate only if the SSD's existing parent directory is not writable.
write_probe="${DATA_ROOT}"
while [[ ! -d "${write_probe}" && "${write_probe}" != "/" ]]; do write_probe="$(dirname "${write_probe}")"; done
needs_root=0
if [[ ! -w "${write_probe}" ]]; then needs_root=1; fi
if [[ "${action}" == "record" && "${EUID}" -ne 0 && "${as_root}" -eq 0 && "${needs_root}" -eq 1 ]]; then
  command -v sudo >/dev/null 2>&1 || { echo "Recorder needs write access to ${DATA_ROOT}, but sudo is unavailable." >&2; exit 77; }
  sudo_args=(env -u CYCLONEDDS_URI
    "ROBOTLOGGER_CONFIG=${config_path}" "ROBOT_ID=${ROBOT_ID}"
    "ROS_SETUP=${ROS_SETUP}" "ROS_WORKSPACE_SETUP=${ROS_WORKSPACE_SETUP}"
    "EXPECTED_TOPICS=${EXPECTED_TOPICS}"
    "ROS_DOMAIN_ID=${ROS_DOMAIN_ID}" "RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION}"
    "SSD_MOUNT=${SSD_MOUNT}" "DATA_ROOT=${DATA_ROOT}"
    "TOPIC_REGEX_FILE=${TOPIC_REGEX_FILE}" "STORAGE_ID=${STORAGE_ID}"
    "MIN_FREE_BYTES=${MIN_FREE_BYTES}" "SPLIT_BYTES=${SPLIT_BYTES}"
    "MAX_CACHE_SIZE=${MAX_CACHE_SIZE}" "SPACE_CHECK_SECONDS=${SPACE_CHECK_SECONDS}")
  if [[ -n "${CYCLONEDDS_URI:-}" ]]; then sudo_args+=("CYCLONEDDS_URI=${CYCLONEDDS_URI}"); fi
  exec sudo "${sudo_args[@]}" "${script_path}" __root_record
fi

if pgrep -af '[r]os2 bag record' >/dev/null; then
  echo "A rosbag recorder is already running. Use the existing session; refusing to start a second recorder." >&2
  exit 73
fi

mkdir -p "${DATA_ROOT}"
mkdir -p "${DATA_ROOT}/${ROBOT_ID}"
session="$(date +%Y_%m%d_%H_%M)"
output="${DATA_ROOT}/${ROBOT_ID}/${session}"
suffix=2
while [[ -e "${output}" ]]; do
  output="${DATA_ROOT}/${ROBOT_ID}/${session}_$(printf '%02d' "${suffix}")"
  ((suffix += 1))
done
echo "Preflight passed: ROS ${ROS_SETUP##*/}, domain ${ROS_DOMAIN_ID}, ${#topics[@]} whitelisted topics, SSD free ${available_bytes} bytes."
if [[ "${clock_sync}" != "yes" ]]; then echo "WARNING: system clock synchronization is not confirmed; verify sensor/host time alignment." >&2; fi
if ((${#missing_topics[@]})); then echo "WARNING: missing contract topics: ${missing_topics[*]}" >&2; fi
if [[ -z "${ROS_WORKSPACE_SETUP}" ]] && ((${#missing_topics[@]})); then
  echo "If late state topics use custom message types, provide their install/setup.bash with --workspace; rosbag2 needs that type support when they appear." >&2
fi
echo "Recording to ${output} (Ctrl-C closes the bag cleanly)."

record_help="$(ros2 bag record -h 2>&1 || true)"
record_args=(bag record)
if grep -q -- '--storage' <<<"${record_help}"; then
  record_args+=(--storage "${STORAGE_ID}")
else
  echo "WARNING: this rosbag2 version has no --storage option; using its default storage plugin." >&2
fi
if grep -q -- '--max-cache-size' <<<"${record_help}"; then
  record_args+=(--max-cache-size "${MAX_CACHE_SIZE}")
else
  echo "WARNING: this rosbag2 version has no --max-cache-size option; its default cache will be used." >&2
fi
if grep -q -- '--max-bag-size' <<<"${record_help}"; then
  record_args+=(--max-bag-size "${SPLIT_BYTES}")
else
  echo "WARNING: this rosbag2 version has no --max-bag-size option; disk free-space guard remains active, but size splitting is unavailable." >&2
fi
if ! grep -q -- '--output' <<<"${record_help}"; then
  echo "This rosbag2 version does not expose --output; cannot safely choose the SSD path." >&2
  exit 69
fi
record_args+=(--output "${output}")
if grep -q -- '--polling-interval' <<<"${record_help}"; then record_args+=(--polling-interval 1000); fi

# Watch every fixed contract name, even before its publisher starts. This is
# still an explicit whitelist; unrelated topics are not recorded. Sensor names
# contain team-specific IDs and are included when advertised at startup or
# entered interactively/configured with --topic.
fixed_contract_topics=(
  /global_pose /cmd_vel /joint_states /robot_state /nav_state /motion_state
  /grasp_state /manipulation_state
)
record_topics=()
declare -A seen_record_topics=()
for topic in "${topics[@]}" "${fixed_contract_topics[@]}" "${expected_topics[@]}"; do
  if [[ -z "${seen_record_topics[${topic}]+x}" ]]; then
    record_topics+=("${topic}")
    seen_record_topics["${topic}"]=1
  fi
done
record_args+=("${record_topics[@]}")
ros2 "${record_args[@]}" &
recorder_pid=$!
stop_recorder() {
  if kill -0 "${recorder_pid}" 2>/dev/null; then
    kill -INT "${recorder_pid}" 2>/dev/null || true
    wait "${recorder_pid}" || true
  fi
}
trap stop_recorder INT TERM EXIT
while kill -0 "${recorder_pid}" 2>/dev/null; do
  available_bytes="$(df -P -B1 "${DATA_ROOT}" | awk 'NR == 2 {print $4}')"
  if [[ ! "${available_bytes}" =~ ^[0-9]+$ ]] || (( available_bytes < MIN_FREE_BYTES )); then
    echo "SSD free-space threshold reached; closing bag cleanly." >&2
    stop_recorder
    trap - EXIT
    exit 75
  fi
  sleep "${SPACE_CHECK_SECONDS}"
done
wait "${recorder_pid}"
trap - EXIT
