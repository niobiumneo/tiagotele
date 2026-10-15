# tiagotele

VR teleoperation for a **PAL Robotics TIAGo Pro** on ROS 2 Humble. You drive both arms, the
torso, the head and the grippers from a Meta Quest headset.

This repository builds **only the teleop parts** of
[AdamSanderson93/ARC_ROS2_TIAGO](https://github.com/AdamSanderson93/ARC_ROS2_TIAGO) for use with
the Quest app [AdamSanderson93/Unity_Bridge_VR](https://github.com/AdamSanderson93/Unity_Bridge_VR).
It fixes the bugs that stop that stack from building and running, and adds tests that need no
headset. It also documents how this stack differs from **PAL's own VR teleoperation**.

> ARC_ROS2_TIAGO has no license file, so its source is **not copied into this repository**.
> `build_teleop_ws.sh` fetches it at a pinned commit and applies the patches in `patches/`.

## How it works

```
Meta Quest (Unity_Bridge_VR app)
   |  ROS-TCP-Connector, TCP 10000
   v
ros_tcp_endpoint --> /cmd_vel (Twist) ----------------------------> twist_mux (TIAGo Pro base)
   |
   +--> /xr_input (custom_teleop_messages/XRMod: 2 controller poses, HMD pose, 2 grip values)
            |
            v
      teleop_msg_bridge --> /left_arm_cmd /right_arm_cmd /head_cmd (PoseStamped)
            |           \-> /grip/left /grip/right (Float32 0..1)
            v                               v
   control_node (bio_ik, 20 Hz)      gripper_traj_node x2
            v                               v
   /arm_left_controller  /arm_right_controller     /gripper_left_controller
   /torso_controller     /head_controller          /gripper_right_controller
                (.../joint_trajectory, trajectory_msgs/JointTrajectory)
```

## Repository layout

| path | what |
|---|---|
| `build_teleop_ws.sh` | Creates or updates a colcon workspace with only the teleop packages, applies the patches, runs rosdep and builds. Safe to re-run. |
| `patches/0*.patch` | Fixes for ARC_ROS2_TIAGO, always applied (see below). |
| `patches/w*.patch` | Fixes for the optional WebRTC transport. |
| `teleop.repos`, `webrtc.repos`, `pal_deps.repos` | Pinned source lists (vcstool format), also used by the script. |
| `tools/headless_smoke_test.sh` | Pipeline test with no headset, robot, Gazebo or rviz. Prints PASS/FAIL. |
| `tools/smoke_test_tcp.sh` | The same test through `ros_tcp_endpoint`, using a fake Unity client that speaks the ROS-TCP-Connector protocol. |
| `docs/BUILD_NOTES.md` | Build options, what is and isn't built, running in sim and on the robot, DDS, verification log. |
| `docs/PAL_VR_TELEOP.md` | How to use PAL's official VR teleop (Premium feature). |
| `docs/KNOWN_ISSUES.md` | Remaining design gaps to address before real-robot use. |

## Quick start

Requirements: Ubuntu 22.04 with ROS 2 Humble (`/opt/ros/humble`), **or** PAL's TIAGo Pro
developer docker / PAL OS. The script sources `/opt/pal/<distro>/setup.bash` automatically and
reuses the PAL packages installed there.

```bash
git clone https://github.com/niobiumneo/tiagotele.git && cd tiagotele
./build_teleop_ws.sh                    # defaults: --ws ~/teleop_ws --transport tcp --pal-deps auto
source /opt/ros/humble/setup.bash && source ~/teleop_ws/install/setup.bash

# optional, no headset/robot needed:
WS=~/teleop_ws ./tools/headless_smoke_test.sh
WS=~/teleop_ws ./tools/smoke_test_tcp.sh
```

Options: `--transport tcp|webrtc|both`, `--pal-deps auto|apt|source|skip`, `--no-rosdep`,
`--jobs N`, `--clean`. Details are in [docs/BUILD_NOTES.md](docs/BUILD_NOTES.md).

### What gets built (`--transport tcp`)
* From ARC_ROS2_TIAGO: `custom_teleop_messages`, `bio_ik` (plus its `fp` dependency), `ik_teleop`
  and `gripper_traj_passthrough`.
* `ros_tcp_endpoint` (Unity-Technologies/ROS-TCP-Endpoint, `main-ros2`, tag `ROS2v0.7.0`).
* The robot model: `launch_pal`, `tiago_pro_description`, `tiago_pro_moveit_config` and
  `pal_sea_arm_moveit_config`. These come from the PAL docker or apt; the script clones PAL's
  public repos only if they are missing.

Not built:
* face/emotion recognition, the Nextage robot packages, the TIAGo dual repos and `pick_ik`;
* WebRTC/opentera/audio, unless you pass `--transport webrtc|both`;
* ARC's `install_deps.sh` is not used.

### What the patches fix
| patch | problem in upstream ARC_ROS2_TIAGO |
|---|---|
| 0001 | `BoolTrigger.srv` was never generated, so Unity's `toggle_tracking`/`stop_robot` services could not register. |
| 0002 | `ik_teleop` didn't declare the PAL/MoveIt packages its launch file uses, so rosdep and colcon skipped them. |
| 0003 | `control_node` **crashed at startup** with `ParameterAlreadyDeclaredException`, and log throttling was broken (about 1000 lines/s). |
| 0004 | An uninitialised control rate sent every arm/torso/head command with a **negative `time_from_start`** and **no joint speed limiting**. |
| 0005 | The gripper range was wrong: it sent 0..0.95, but the PAL Pro gripper is 0.0 m (closed) to 0.07 m (open). |
| w001, w002 | WebRTC profile only: missing runtime deps, and the OpenBLAS CPU-detection build failure. |

ARC's README says to clone with `--recurse-submodules`, but that fails (gitlinks without
`.gitmodules` entries). The script never clones recursively; it pins the repos it needs.

## Running

Every terminal: `source /opt/ros/humble/setup.bash && source ~/teleop_ws/install/setup.bash`. In the
PAL docker, also source `/opt/pal/<distro>/setup.bash`.

**Simulation first:**
```bash
ros2 launch tiago_pro_gazebo tiago_pro_gazebo.launch.py                       # T1 (PAL's sim)
ros2 launch ik_teleop launch_tiago_ik.py use_sim_time:=True                   # T2, wait for "Bio IK planner ready to go!"
ros2 run ros_tcp_endpoint default_server_endpoint --ros-args -p ROS_IP:=0.0.0.0 -p ROS_TCP_PORT:=10000   # T3
```
`use_sim_time` must be a capitalised `True`/`False` (launch_pal rejects `false`).

**Quest app (Unity_Bridge_VR):** set the ROS IP in `Assets/Resources/ROSConnectionPrefab.prefab`
(or *Robotics > ROS Settings*) to the machine running T3, and open TCP 10000 in its firewall. The
project sets the `ROS2` define only for Android; add it for Editor or PC-VR use.

**Real robot:** run T2 with `use_sim_time:=False`, plus T3, on a machine on the robot's DDS
network. Use the robot's `RMW_IMPLEMENTATION` and `ROS_DOMAIN_ID`. Before you start:
1. `ros2 control list_controllers` shows `arm_left_controller`, `arm_right_controller`,
   `torso_controller`, `head_controller`, `gripper_left_controller` and `gripper_right_controller`
   as **active**, and nothing else (PAL VR teleop, WBC, play_motion2) is commanding those joints.
2. Check your gripper type (BUILD_NOTES section 5.2).
3. Read [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md). There is **no software stop or deadman** and
   the hand mapping is absolute, so lower the speed limits, keep the arms clear, and keep someone
   on the e-stop.

## PAL's VR teleop vs this stack

PAL ships its own VR teleoperation for TIAGo Pro as a Premium robot feature. Usage notes are in
[docs/PAL_VR_TELEOP.md](docs/PAL_VR_TELEOP.md). The PAL page itself could not be read when they were
written, so check every command against
[PAL's docs page](https://docs.pal-robotics.com/edge/manipulation/vr-teleoperation).

| | PAL VR teleop | this repo (ARC + Unity_Bridge_VR) |
|---|---|---|
| Headset side | Web page in the Quest 3 browser (reportedly WebXR), no app install | Custom Unity app |
| Transport | HTTPS (port 4443) frontend served by the robot or PC | ROS-TCP-Connector -> `ros_tcp_endpoint`, TCP 10000, no auth |
| Arm control | `vr_teleop_controller`: PAL whole-body controller (torso included, self-collision avoidance) inside ros2_control | `bio_ik` node sending JointTrajectory to the standard arm/torso/head/gripper controllers |
| Safety | Hold-to-move trigger, start from the home pose, Meta button stops | None in software yet (see KNOWN_ISSUES) |
| Base, camera | Not documented | Thumbsticks -> `/cmd_vel`; head camera streamed to the headset |
| Availability | Premium, closed source, needs PAL's packages | Open source, builds anywhere with Humble |

Never run both at the same time: they command the same joints.

## Verification status

Verified in a ROS 2 Humble container (`moveit/moveit2:humble-release`, Ubuntu 22.04):
* A from-scratch build as a non-root user built 17 packages with no manual steps, and re-running
  the script is idempotent. An emulated PAL docker (`/opt/pal` underlay) builds too.
* The headless pipeline test (real TIAGo Pro URDF, fake joint states) produces trajectories on all
  six controllers, with `time_from_start` 0.05 s and gripper targets within 0..0.07 m.
* The fake-Unity TCP test passes.
* `--transport both` builds, but was never run.

**Not** verified: Gazebo, a real TIAGo Pro, a real Quest/Unity build, or DDS over a real network.

## Credits and licenses

* This repository's own files are under the BSD 3-Clause license (`LICENSE`).
* Code fetched at build time keeps its own license:
  * ARC_ROS2_TIAGO (AdamSanderson93; no license file; not redistributed here, only patched locally);
  * bio_ik and fp (BSD);
  * ROS-TCP-Endpoint (Apache-2.0);
  * PAL Robotics packages (Apache-2.0).
* Unity_Bridge_VR is a separate project by AdamSanderson93.
