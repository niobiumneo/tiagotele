#!/usr/bin/env bash
# Offline end-to-end smoke test - no headset, no Gazebo, no robot needed:
#   fake TIAGo Pro (robot_state_publisher + joint_state_publisher, real URDF)
#   + ik_teleop/launch_tiago_ik.py + ros_tcp_endpoint
#   + fake_unity_client.py (speaks the Unity ROS-TCP-Connector protocol)
# and counts what comes out on the controller topics.
# Usage: WS=~/teleop_ws ./smoke_test_tcp.sh
# (no set -u: ROS setup.bash files reference unset variables)
WS="${WS:-$HOME/teleop_ws}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-/tmp/teleop_smoke}"; mkdir -p "$OUT"
source /opt/ros/humble/setup.bash
# shellcheck disable=SC1090
for f in /opt/pal/*/setup.bash; do [[ -f "$f" ]] && source "$f"; done
source "$WS/install/setup.bash"
# isolate from any real robot on the network
export ROS_LOCALHOST_ONLY=1 ROS_DOMAIN_ID="${ROS_DOMAIN_ID_TEST:-42}"
PORT="${PORT:-10000}"
# Each background job gets its own process group; cleanup stops only those groups.
# (Previously 'pkill -f robot_state_publisher' etc. also killed a Gazebo / robot stack running
#  on the same machine.)
set -m
cleanup() {
  for p in $(jobs -p); do kill -INT -- "-$p"; done; sleep 3
  for p in $(jobs -p); do kill -KILL -- "-$p"; done
  ros2 daemon stop >/dev/null
} 2>/dev/null
trap cleanup EXIT
ros2 launch "$HERE/fake_robot.launch.py" > "$OUT/fake_robot.log" 2>&1 &
sleep 3
ros2 launch ik_teleop launch_tiago_ik.py use_sim_time:=False > "$OUT/ik.log" 2>&1 &
ros2 run ros_tcp_endpoint default_server_endpoint --ros-args -p ROS_IP:=127.0.0.1 -p ROS_TCP_PORT:=$PORT > "$OUT/endpoint.log" 2>&1 &
for i in $(seq 1 90); do grep -q "ready to go" "$OUT/ik.log" && break; sleep 1; done
if ! grep -q "ready to go" "$OUT/ik.log"; then echo "FAIL: IK planner did not start, see $OUT/ik.log"; grep -E "ERROR|what\(\)|exception" "$OUT/ik.log" | head; exit 1; fi
echo "IK planner ready after ~${i}s"
python3 "$HERE/topic_counter.py" 14 > "$OUT/counts.log" 2>&1 &
CNT=$!
sleep 1
python3 "$HERE/fake_unity_client.py" --port "$PORT" --duration 10 --call-service > "$OUT/client.log" 2>&1
wait $CNT
echo "--- fake Unity client";  cat "$OUT/client.log"
echo "--- messages seen";     cat "$OUT/counts.log"
echo "--- endpoint";          grep -E "Register|ERROR" "$OUT/endpoint.log" | sed -E 's/\[[0-9.]+\] //' | head
traj=$(awk '$2=="/arm_left_controller/joint_trajectory"{print $1}' "$OUT/counts.log")
grip=$(awk '$2=="/gripper_left_controller/joint_trajectory"{print $1}' "$OUT/counts.log")
if [[ "${traj:-0}" -gt 0 && "${grip:-0}" -gt 0 ]]; then echo "PASS: Unity-format XRMod -> arm + gripper JointTrajectory commands"; exit 0
else echo "FAIL: no trajectories (logs in $OUT)"; exit 1; fi
