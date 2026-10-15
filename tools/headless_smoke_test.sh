#!/usr/bin/env bash
# Headless smoke test of the teleop pipeline - no Gazebo, no rviz, no robot, no headset:
#   tools/headless_smoke.launch.py  (robot_state_publisher + joint_state_publisher with the TIAGo Pro
#                                    URDF, control_node, teleop_msg_bridge, 2x gripper_traj_node)
#   tools/xr_input_pub.py           (custom_teleop_messages/XRMod on /xr_input, moving poses + squeeze)
# then checks every hop:
#   /xr_input -> /left_arm_cmd /right_arm_cmd /head_cmd /grip/left /grip/right
#             -> /arm_{left,right}_controller /torso_controller /head_controller .../joint_trajectory
#             -> /gripper_{left,right}_controller/joint_trajectory
# and that ros_tcp_endpoint (default_server_endpoint) listens on TCP $PORT (default 10000).
#
# Usage:  WS=~/teleop_ws ./tools/headless_smoke_test.sh [--from-topic]
#   --from-topic  do not pass robot_description to control_node (exactly like launch_tiago_ik.py,
#                 MoveIt reads the /robot_description topic instead)
# Env: OUT (log dir, default /tmp/teleop_headless_smoke), PORT (10000), ROS_DOMAIN_ID_TEST (42).
# Runs with ROS_LOCALHOST_ONLY=1 on its own domain, and only stops the processes it started.
# (no set -u: ROS setup.bash files reference unset variables)
WS="${WS:-$HOME/teleop_ws}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-/tmp/teleop_headless_smoke}"; rm -rf "$OUT"; mkdir -p "$OUT"
PORT="${PORT:-10000}"
FROM_TOPIC=False; [[ "${1:-}" == "--from-topic" ]] && FROM_TOPIC=True

# shellcheck disable=SC1090
source "/opt/ros/${ROS_DISTRO:-humble}/setup.bash"
# shellcheck disable=SC1090
for f in /opt/pal/*/setup.bash; do [[ -f "$f" ]] && source "$f"; done
# shellcheck disable=SC1091
source "$WS/install/setup.bash" || { echo "FAIL: $WS/install/setup.bash not found (build first)"; exit 1; }
export ROS_LOCALHOST_ONLY=1 ROS_DOMAIN_ID="${ROS_DOMAIN_ID_TEST:-42}"

set -m                      # every background job gets its own process group
PGIDS=()
start() { "$@" & PGIDS+=("$!"); }
cleanup() {
  for p in "${PGIDS[@]}"; do kill -INT -- "-$p" 2>/dev/null; done
  sleep 3
  for p in "${PGIDS[@]}"; do kill -KILL -- "-$p" 2>/dev/null; done
  ros2 daemon stop >/dev/null 2>&1   # only the daemon of the test domain
}
trap cleanup EXIT

echo "=== 1. bring-up (robot_description_from_topic:=$FROM_TOPIC)"
start ros2 launch "$HERE/headless_smoke.launch.py" "robot_description_from_topic:=$FROM_TOPIC" > "$OUT/launch.log" 2>&1
LAUNCH_PID=${PGIDS[0]}
for i in $(seq 1 120); do
  grep -q "ready to go" "$OUT/launch.log" && break
  kill -0 "$LAUNCH_PID" 2>/dev/null || break
  sleep 1
done
if ! grep -q "ready to go" "$OUT/launch.log"; then
  echo "FAIL: control_node did not report 'Bio IK planner ready to go!' (see $OUT/launch.log)"
  grep -E "ERROR|what\(\)|terminate|exception|died" "$OUT/launch.log" | head -20
  exit 1
fi
echo "control_node ready after ~${i}s"
grep -E "process started" "$OUT/launch.log" | sed -E 's/^\[INFO\] \[launch\]: //'

echo "=== 2. stream XRMod on /xr_input and record the pipeline"
TOPICS=(/xr_input /left_arm_cmd /right_arm_cmd /head_cmd /grip/left /grip/right
        /arm_left_controller/joint_trajectory /arm_right_controller/joint_trajectory
        /torso_controller/joint_trajectory /head_controller/joint_trajectory
        /gripper_left_controller/joint_trajectory /gripper_right_controller/joint_trajectory)
python3 "$HERE/topic_counter.py" 16 > "$OUT/counts.log" 2>&1 &
CNT=$!
ECHO_PIDS=()
for t in "${TOPICS[@]}"; do
  f="$OUT/echo$(echo "$t" | tr '/' '_').txt"
  case "$t" in   # explicit type: no dependency on graph discovery timing
    /xr_input) ty=custom_teleop_messages/msg/XRMod ;;
    /grip/*) ty=std_msgs/msg/Float32 ;;
    */joint_trajectory) ty=trajectory_msgs/msg/JointTrajectory ;;
    *) ty=geometry_msgs/msg/PoseStamped ;;
  esac
  timeout 20 ros2 topic echo --once "$t" "$ty" > "$f" 2>&1 &
  ECHO_PIDS+=("$!")
done
sleep 2
python3 "$HERE/xr_input_pub.py" --duration 10 > "$OUT/xr_input_pub.log" 2>&1
wait "$CNT"
wait "${ECHO_PIDS[@]}"   # only the topic echo jobs (bounded by timeout), not the launch job

cat "$OUT/xr_input_pub.log"
echo "--- message counts over 16 s"
cat "$OUT/counts.log"
echo "--- one sample per topic (ros2 topic echo --once)"
for t in "${TOPICS[@]}"; do
  f="$OUT/echo$(echo "$t" | tr '/' '_').txt"
  echo "## $t"; grep -v "^\s*$" "$f" | head -n 14
done

echo "=== 3. ros_tcp_endpoint on TCP $PORT"
start ros2 run ros_tcp_endpoint default_server_endpoint --ros-args -p ROS_IP:=127.0.0.1 -p "ROS_TCP_PORT:=$PORT" > "$OUT/endpoint.log" 2>&1
EP_OK=0
for _ in $(seq 1 20); do
  if python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', int(sys.argv[1])), 1).close()" "$PORT" 2>/dev/null; then
    EP_OK=1; break; fi
  sleep 1
done
command -v ss >/dev/null && ss -ltnp 2>/dev/null | grep ":$PORT "
grep -v "^\s*$" "$OUT/endpoint.log" | head -5
[[ $EP_OK == 1 ]] && echo "endpoint accepted a TCP connection on 127.0.0.1:$PORT" || echo "endpoint NOT listening on $PORT"

echo "=== result"
rc=0
for t in "${TOPICS[@]}"; do
  n=$(awk -v t="$t" '$2==t{print $1}' "$OUT/counts.log")
  if [[ "${n:-0}" -gt 0 ]]; then printf '  ok   %6d  %s\n' "$n" "$t"; else printf '  FAIL %6d  %s\n' "${n:-0}" "$t"; rc=1; fi
done
[[ $EP_OK == 1 ]] || rc=1
# IK trajectories must carry a sane time_from_start (1/frequency = 0.05 s). Without patch 0004 it
# is a negative overflowed duration (sec: -2147483648) and joint speed limiting is disabled.
for g in arm_left arm_right torso head; do
  f="$OUT/echo_${g}_controller_joint_trajectory.txt"
  tfs=$(python3 - "$f" <<'EOF'
import sys, yaml
try:
    m = yaml.safe_load(open(sys.argv[1]).read().split('---')[0])
    t = m['points'][0]['time_from_start']
    print(t['sec'] + t['nanosec'] * 1e-9)
except Exception as e:  # noqa: BLE001
    print('none')
EOF
)
  if python3 -c "import sys; v=float(sys.argv[1]); sys.exit(0 if 0 < v <= 1.0 else 1)" "$tfs" 2>/dev/null; then
    printf '  ok   time_from_start=%ss  /%s_controller/joint_trajectory\n' "$tfs" "$g"
  else
    printf '  FAIL time_from_start=%s  /%s_controller/joint_trajectory (expected 0 < t <= 1 s)\n' "$tfs" "$g"; rc=1
  fi
done
# Gripper targets must stay inside the PAL Pro gripper finger range [0.0 closed, 0.07 open] while
# squeeze ramps 0 -> 1 -> 0. ARC's original config (0.0 .. 0.95) fails this; patch 0005 fixes it.
for s in left right; do
  r=$(awk -v t="/gripper_${s}_controller/joint_trajectory" '$1=="gripper_range" && $4==t{print $2, $3}' "$OUT/counts.log")
  if [[ -n "$r" ]] && python3 -c "import sys; lo,hi=map(float,sys.argv[1:3]); sys.exit(0 if 0.0 <= lo and hi <= 0.07 and hi-lo > 0.03 else 1)" $r; then
    printf '  ok   gripper %-5s target range [%s]  (limits 0.0 .. 0.07)\n' "$s" "$r"
  else
    printf '  FAIL gripper %-5s target range [%s]  (expected within 0.0 .. 0.07)\n' "$s" "${r:-none}"; rc=1
  fi
done
if [[ $rc == 0 ]]; then echo "PASS: /xr_input -> bridge -> IK + gripper JointTrajectory on all 6 controllers; endpoint listens on $PORT"
else echo "FAIL (logs in $OUT)"; fi
exit $rc
