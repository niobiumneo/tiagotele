# Build notes - ARC_ROS2_TIAGO teleop-only build (TIAGo Pro, ROS 2 Humble)

This repository builds **only** the VR-teleoperation parts of
[AdamSanderson93/ARC_ROS2_TIAGO](https://github.com/AdamSanderson93/ARC_ROS2_TIAGO)
for use with [AdamSanderson93/Unity_Bridge_VR](https://github.com/AdamSanderson93/Unity_Bridge_VR)
on a PAL TIAGo Pro.

```
tiagotele/
  README.md               # overview / quick start
  docs/                   # BUILD_NOTES.md (this file), PAL_VR_TELEOP.md, KNOWN_ISSUES.md
  build_teleop_ws.sh      # the build script (idempotent)
  patches/0*.patch        # fixes applied to ARC_ROS2_TIAGO (always)
  patches/w*.patch        # fixes for the optional WebRTC profile
  teleop.repos            # vcstool view of the core sources (pinned)
  webrtc.repos            # vcstool view of the optional WebRTC sources (pinned)
  pal_deps.repos          # PAL source fallback (only used if PAL packages are missing)
  tools/                  # headset-free test harness:
                          #   headless_smoke_test.sh (+ headless_smoke.launch.py, xr_input_pub.py):
                          #     URDF + joint_state_publisher + control_node + bridge + grippers, no rviz/Gazebo
                          #   smoke_test_tcp.sh (+ fake_robot.launch.py, fake_unity_client.py):
                          #     same through ros_tcp_endpoint with the Unity ROS-TCP-Connector wire protocol
```

## 1. Quick start (your machine / PAL docker)

Requirements: Ubuntu 22.04 with ROS 2 Humble from apt (`/opt/ros/humble`), **or** PAL's
TIAGo Pro docker / PAL OS (Humble based; PAL packages live in `/opt/pal/<distro>`, which the
script sources automatically). Internet access to github.com and the ROS apt repo.

```bash
git clone https://github.com/niobiumneo/tiagotele.git && cd tiagotele
./build_teleop_ws.sh                          # = --ws ~/teleop_ws --transport tcp --pal-deps auto
source /opt/ros/humble/setup.bash && source ~/teleop_ws/install/setup.bash
WS=~/teleop_ws ./tools/headless_smoke_test.sh  # optional: headless pipeline test (no rviz/Gazebo/robot), PASS/FAIL
WS=~/teleop_ws ./tools/smoke_test_tcp.sh       # optional: same through ros_tcp_endpoint + fake Unity client
```
Both tests run on `ROS_LOCALHOST_ONLY=1`, `ROS_DOMAIN_ID=42`, use TCP port 10000 (`PORT=...` to change)
and only stop the processes they started.

Options (also available as env vars):

| option | env | default | meaning |
|---|---|---|---|
| `--ws DIR` | `WS` | `~/teleop_ws` | workspace to create/update |
| `--transport tcp\|webrtc\|both` | `TRANSPORT` | `tcp` | `tcp` = ROS-TCP-Endpoint (what Unity_Bridge_VR **main** uses). `webrtc` = old opentera path |
| `--pal-deps auto\|apt\|source\|skip` | `PAL_DEPS` | `auto` | how to get `launch_pal`, `tiago_pro_description`, `tiago_pro_moveit_config`, `pal_sea_arm_moveit_config` (see 3) |
| `--no-rosdep` | `SKIP_ROSDEP=1` | off | don't call rosdep/apt (e.g. no sudo in the docker) |
| `--jobs N` | `COLCON_JOBS` | colcon default | `--parallel-workers`; use 1-2 on a small laptop (bio_ik is memory hungry) |
| `--arc-ref REF` | `ARC_REF` | `32e37a48...` | ARC_ROS2_TIAGO commit; patches were made against this one |
| `--clean` | | off | wipe build/ install/ log/ first |
| | `UNDERLAY` | newest `/opt/pal/*/setup.bash` | extra setup file to source before building |
| | `OPENBLAS_TARGET` | `HASWELL` on x86_64 (webrtc only) | forced OpenBLAS CPU target for audio_utils |

Re-running the script is safe: clones are kept (re-fetched only if the pinned ref changes),
already-applied patches are skipped and colcon does an incremental build.

## 2. What is built, and what is not

ARC_ROS2_TIAGO is cloned **without `--recurse-submodules`** and with a *sparse* checkout that
contains only the teleop package directories (no upstream repo-root files such as its network/VPN
config are checked out into the workspace - see 8).

### Built (TRANSPORT=tcp)

| package | from | why |
|---|---|---|
| `custom_teleop_messages` | ARC | `XRMod`/`XRPose` msgs + `BoolTrigger` srv (Unity publishes `XRMod` on `/xr_input`, calls `BoolTrigger` services) |
| `bio_ik` | ARC (vendored) | IK solver library + MoveIt kinematics plugin used by `ik_teleop` |
| `fp` | tylerjw/fp @ `3230158` (ARC submodule pin) | header-only lib `bio_ik` needs (with `librange-v3-dev`, `libfmt-dev` from apt) |
| `ik_teleop` | ARC | `control_node` (whole-upper-body bio_ik IK at 20 Hz -> `JointTrajectory` on `/arm_{left,right}_controller`, `/torso_controller`, `/head_controller` `.../joint_trajectory`), `teleop_msg_bridge` (`/xr_input` -> `/left_arm_cmd` `/right_arm_cmd` `/head_cmd` + `/grip/{left,right}`), `launch_tiago_ik.py` |
| `gripper_traj_passthrough` | ARC | `/grip/{left,right}` (Float32 0..1) -> `/gripper_{left,right}_controller/joint_trajectory` (`gripper_*_finger_joint`; with patch 0005: squeeze 0 -> 0.07 m open, squeeze 1 -> 0.0 closed) |
| `ros_tcp_endpoint` | Unity-Technologies/ROS-TCP-Endpoint `main-ros2` @ `54c1a64` = tag `ROS2v0.7.0` (ARC gitlink pin; the plain `v0.7.0` tag is the ROS 1 release) | TCP bridge for Unity ROS-TCP-Connector (Unity_Bridge_VR main) |

Plus, **only if they are not already installed**, PAL description/config sources (see 3).

### Built only with TRANSPORT=webrtc|both (optional, heavy)

`webrtc_launch` (ARC), `opentera_webrtc_ros` + `opentera_webrtc_ros_msgs` + `map_image_generator`
(introlab/opentera-webrtc-ros @ `cd3705b`, recursive submodules), `audio_utils` + `audio_utils_msgs`
(introlab/audio_utils @ `cfa851d`), `odas_ros_msgs` (introlab/odas_ros @ `0d26e65`).
Other opentera packages (client, demos, GUI, face_cropping, turtlebot3 description) are
`COLCON_IGNORE`d. See section 6 for status.

### Excluded (and why)

| item | reason |
|---|---|
| `face_data_inspec`, `emotion_keras_pkg` | emotion/face recognition research nodes, not teleop (pull TensorFlow/Keras/torch) |
| `nextage_fillie_open_*` | other robot (Kawada Nextage) |
| `tutorial_interfaces` | empty tutorial package |
| submodules `tiago_dual_*`, `pal_gazebo_worlds` | TIAGo **dual** (not Pro) model/sim; TIAGo Pro sim comes from PAL (`tiago_pro_gazebo`) |
| submodules `pick_ik`, `picknik_controllers`, `ik_teleop_pick_ik.zip`, `bio_ik.zip` | alternative IK experiments / archives, not used by `launch_tiago_ik.py` |
| submodules `cv_camera`, `odas_ros` (nodes), `audio_utils` (tcp) | USB camera / microphone-array / audio for the WebRTC path only |
| `opentera-webrtc-ros`, `webrtc_launch` (tcp) | Unity_Bridge_VR **main** uses ROS-TCP-Connector, not WebRTC |
| `install_deps.sh` | installs far more than needed (rtabmap, turtlebot3, nav2, torchvision, node/npm...); replaced by rosdep on the needed package set |

## 3. Robot-model dependencies (`PAL_DEPS`)

`ik_teleop/launch/launch_tiago_ik.py` imports `launch_pal` and `tiago_pro_description`
(launch arguments, hw-suffix helper), reads controller/joint-limit/pilz files from
`tiago_pro_moveit_config`, and its SRDF (`ik_teleop/config/tiago_pro.srdf.xacro`) xacro-includes
files from `tiago_pro_moveit_config` **and `pal_sea_arm_moveit_config`**. The URDF itself comes
from `/robot_description` (published by the robot / Gazebo), so the launch file does not build
the URDF.

* `auto` (default): if they are installed (PAL docker/robot `/opt/pal/...`, or apt), nothing
  is done. Otherwise rosdep installs the released binaries (`ros-humble-launch-pal`,
  `ros-humble-tiago-pro-description`, `ros-humble-tiago-pro-moveit-config`,
  `ros-humble-pal-sea-arm-moveit-config` - all are in the official Humble repo). Only if they
  are *still* missing, sources are cloned at the tags matching those binaries
  (`pal_deps.repos`: launch_pal 0.22.1, tiago_pro_robot 2.5.1, tiago_pro_moveit_config 1.5.2,
  pal_sea_arm_moveit_config 1.0.7, pal_sea_arm 2.8.4, pal_pro_gripper 1.12.6,
  tiago_pro_head_robot 1.12.0, omni_base_robot 2.18.0, pal_urdf_utils 2.11.1,
  realsense-ros 4.59.1) and everything except the description/config packages is
  `COLCON_IGNORE`d.
* `apt`: never clone; warn if missing. `source`: always clone. `skip`: ignore (build still
  succeeds, the launch file will not start).

Inside PAL's docker / on the robot, use the PAL-installed versions (default `auto` does that) -
they match your robot's configuration.

## 4. Patches (what was broken)

All patches are minimal and applied with `git apply` (idempotent).

| patch | problem | fix |
|---|---|---|
| `0001-custom_teleop_messages-generate-BoolTrigger-srv.patch` | `srv/BoolTrigger.srv` exists but is not in `rosidl_generate_interfaces`. Unity calls `RegisterRosService<BoolTrigger>("toggle_tracking"/"stop_robot")`; ros_tcp_endpoint then fails with *Unknown service class*. | add the srv to `rosidl_generate_interfaces`; declare exec deps of the msg package |
| `0002-ik_teleop-declare-launch-runtime-deps.patch` | `ik_teleop/package.xml` does not declare what its launch file/SRDF use (launch_pal, tiago_pro_description, tiago_pro_moveit_config, pal_sea_arm_moveit_config, moveit_configs_utils, gripper_traj_passthrough, rviz2, xacro...). rosdep therefore never installs them and `colcon --packages-up-to` doesn't build them. | add `<exec_depend>`s |
| `0003-ik_teleop-fix-param-redeclare-crash-and-log-throttle.patch` | **Runtime crash**: `control_node` is created with `automatically_declare_parameters_from_overrides(true)` and `BIO_IK_Planner` then calls `declare_parameter()` on the same names -> `terminate ... ParameterAlreadyDeclaredException: parameter 'frequency' has already been declared` right after "Load Frequency" (the IK node never starts). Also `RCLCPP_WARN_STREAM_THROTTLE(..., 0.5, ...)` - ROS 2 throttle periods are **milliseconds**, so the idle loop logged "Commanded position is the same as current position" ~1000x/s. | declare only if `!has_parameter()`; throttle 500 ms |
| `0004-ik_teleop-initialise-group-control-rate-freq.patch` | **Runtime/safety bug**: `BIO_IK_Group` never initialises `freq_` (its `hz` argument is unused). Every arm/torso/head `JointTrajectory` therefore had `time_from_start` = 1/garbage (observed: `sec: -2147483648`), velocities were denormals (~1e-318), and `interpolate_motion()` (which scales by `freq_`) never limited joint speeds - the full IK jump was commanded in one step. | `freq_ = hz` (the `frequency` param, 20 Hz): `time_from_start` 0.05 s, each step limited to `max_velocity`/20 from `tiago_pro_moveit_config/config/joint_limits.yaml` (verified: arm_left_1 velocity = 0.60 rad/s = its limit) |
| `0005-gripper_traj_passthrough-pal-pro-gripper-range.patch` | **Wrong gripper range/direction for TIAGo Pro**: ARC maps squeeze 0..1 to `gripper_*_finger_joint` 0.0..0.95. On the current PAL Pro gripper (`pal_pro_gripper` 1.12.6, the version rosdep/PAL docker installs) that joint is **prismatic 0.0 m (closed) .. 0.07 m (open)** (`gripper_limits.xacro`, `pal_pro_gripper_wrapper/config/gripper.yaml` open_value 0.07 / close_value 0.0), so a released trigger commanded *fully closed* and a pressed trigger asked for 0.95 m, 13x past the limit. | `open_angle: 0.07`, `closed_angle: 0.0` (squeeze 0 = open, 1 = closed). Older revolute grippers (ARC backup branch value): `open_angle 0.0`, `closed_angle 0.802850778`. Check your robot first (section 5.2) |
| `w001-webrtc_launch-declare-launch-runtime-deps.patch` (webrtc) | `tiago_pro.launch.xml` runs ik_teleop's python bridges (need `rclpy_message_converter`) and `topic_tools relay`, none declared | add `<exec_depend>`s |
| `w002-audio_utils-MusicBeatDetector-openblas-target.patch` (webrtc) | bundled OpenBLAS 0.3.20 cannot detect newer/virtualised CPUs (`SGEMM_DEFAULT_UNROLL_M undeclared`) - the issue the ARC README mentions | honour `OPENBLAS_TARGET` (script sets `HASWELL` on x86_64; override e.g. `OPENBLAS_TARGET=SAPPHIRERAPIDS`, or `OPENBLAS_TARGET=` for auto-detect) |

No code changes were needed for Humble API compatibility of the C++ (bio_ik, ik_teleop,
gripper_traj_passthrough build cleanly on Humble/MoveIt 2.5 with only warnings).

## 5. How to run

Always first (every terminal):
```bash
source /opt/ros/humble/setup.bash
# PAL docker / robot: source /opt/pal/<distro>/setup.bash  (the script prints the right line)
source ~/teleop_ws/install/setup.bash
```

### 5.1 Simulation (do this first)
Needs PAL's TIAGo Pro simulation (`tiago_pro_gazebo`, in PAL's docker, or
`sudo apt install ros-humble-tiago-pro-simulation`):
```bash
# T1 - Gazebo (TIAGo Pro with the default pal-pro-gripper end effectors)
ros2 launch tiago_pro_gazebo tiago_pro_gazebo.launch.py
# T2 - IK teleop: control_node + teleop_msg_bridge + gripper passthrough (+ rviz2)
ros2 launch ik_teleop launch_tiago_ik.py use_sim_time:=True
# T3 - Unity TCP bridge
ros2 run ros_tcp_endpoint default_server_endpoint --ros-args -p ROS_IP:=0.0.0.0 -p ROS_TCP_PORT:=10000
```
Note: launch_pal arguments are **case-sensitive booleans**: `use_sim_time:=True|False`
(`false` is rejected). Wait for `Bio IK planner ready to go!` in T2.

Unity_Bridge_VR: set the ROS IP in `Assets/Resources/ROSConnectionPrefab.prefab`
(hard-coded to the original author's lab IP, port `10000`) - or in *Robotics > ROS Settings* - to the IP of the
machine running T3, and make sure TCP 10000 is reachable (firewall).
The project only has the `ROS2` scripting define for the **Android** (Quest standalone) target;
if you run it in the Editor / PC-VR (Standalone), add `ROS2` to the Standalone define symbols
(*Robotics > ROS Settings > Protocol: ROS2*) or messages will be serialised in ROS 1 format.

### 5.2 Real robot
* Make sure the robot's arm/torso/head/gripper **JointTrajectoryControllers are active** -
  `ros2 control list_controllers` should list `arm_left_controller`, `arm_right_controller`,
  `torso_controller`, `head_controller`, `gripper_left_controller`, `gripper_right_controller`
  as `active`. `control_node` publishes straight to their `~/joint_trajectory` topics. If another
  stack (e.g. PAL's whole-body control / PAL VR teleop / play_motion2) is commanding the same
  joints, stop it first.
* Run T2 with `use_sim_time:=False` and T3 as above, either on a dev PC that sees the robot's
  DDS graph or inside the robot's docker. `rviz2` in the launch file just exits on a headless
  machine (harmless).
* `control_node` has no workspace limits; its only motion limit is the per-joint max speed from
  `joint_limits.yaml`, and that limit is only applied with patch 0004 (without it every command
  jumped straight to the IK solution with a negative `time_from_start`). Try in simulation first,
  start with the arms in a safe pose, keep the e-stop in reach.
* **Gripper type check** (patch 0005 assumes the current prismatic PAL Pro gripper):
  `ros2 param get /robot_state_publisher robot_description | grep -A4 'finger_joint" type'`
  should show `type="prismatic"` with `upper="0.07"`. If yours is revolute, edit
  `gripper_traj_passthrough/config/pal_gripper_{left,right}.yaml` (values in the patch comment).
  Gripper commands are sent with `time_from_start` 0 at ~100 Hz (ARC design); PAL's own
  `gripper_grasper` service is the gentler alternative.
* Base: Unity publishes `geometry_msgs/Twist` on `/cmd_vel` at ~100 Hz from the thumbsticks
  (zeros when idle). On TIAGo Pro `/cmd_vel` is the **lowest-priority (10) "navigation" input of
  twist_mux** (joystick `joy_vel`/keyboard override it), so no relay is needed; but it competes
  with Nav2 if navigation is running. (`webrtc_launch` relays `/cmd_vel -> /movo/cmd_vel`, a
  leftover for another robot - not used in the tcp path.)
* Camera: Unity subscribes to `/head_front_camera/color/image_raw/compressed` (plus two unused
  topics); the endpoint forwards it - expect bandwidth/latency on Wi-Fi.

### 5.3 DDS / networking
* Use the **same `RMW_IMPLEMENTATION` and `ROS_DOMAIN_ID` as the robot**. ARC_ROS2_TIAGO's own
  `dds.xml` / `pal_connect_mod.sh` show the author's setup: CycloneDDS
  (`export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`, `sudo apt install ros-humble-rmw-cyclonedds-cpp`)
  with `CYCLONEDDS_URI` listing your network interface and the robot as a unicast peer -
  edit `<NetworkInterface name="eno1">` and `<Peer Address="...">` for your network.
  Check what your robot uses (`echo $RMW_IMPLEMENTATION` in a robot shell) - this was not
  verifiable here.
* `ROS_LOCALHOST_ONLY=1` (used by `tools/smoke_test_tcp.sh`) isolates tests from the robot.
* ros_tcp_endpoint is a plain TCP server (no DDS between Unity and ROS); only the endpoint
  host needs to be on the robot's DDS graph. `ROS_IP:=0.0.0.0` binds all interfaces.

### 5.4 Services toggle_tracking / stop_robot
Unity registers and calls `toggle_tracking` and `stop_robot` (`custom_teleop_messages/srv/BoolTrigger`).
**Nothing in ARC_ROS2_TIAGO provides these services**, so pressing those buttons only logs
`Ignoring service call to toggle_tracking - service is not ready` on the endpoint (it does not
block streaming; Unity's callbacks ignore the response). Arm tracking is always on while
`/xr_input` is streaming.

### 5.5 Optional: old WebRTC transport (`TRANSPORT=webrtc` or `both`)
Only needed for the WebRTC version of the Unity app (not Unity_Bridge_VR main):
```bash
./build_teleop_ws.sh --transport both        # adds webrtc_launch + opentera + audio_utils (+~10 min)
ros2 launch webrtc_launch tiago_pro.launch.xml server_url:=http://<your-signalling-server>:6789
```
The launch file hard-codes the signalling room names/password and a `/cmd_vel -> /movo/cmd_vel`
relay; edit it for your setup. Runtime Python deps for its bridges (`rclpy_message_converter`,
`topic_tools`) are installed by rosdep thanks to patch w001.

## 6. Verification done (in a cloud container)

Container method (not needed on your machine): Docker image `moveit/moveit2:humble-release`
(Ubuntu 22.04, ROS 2 Humble, MoveIt 2.5) because the ROS apt repo was blocked by the
container's egress proxy; PAL packages therefore came from the source fallback (`auto` path).

* Independent re-verification (pristine `moveit/moveit2:humble-release` container, i.e. empty
  `/var/lib/apt/lists` like every ROS/PAL docker image, run as a **non-root user with sudo**, empty
  workspace, exactly the Quick start above):
  * Found and fixed: (1) the script never ran `apt-get update` before `rosdep install`, so on
    an image with empty apt lists `librange-v3-dev` was "Unable to locate" and `fp`/`bio_ik`
    failed (exit 1) - the script now runs `apt-get update` once; (2) `clone_pal_sources` ended
    on a false `[[ ]] && touch`, so with realsense2_* already installed (normal on a Humble
    desktop) the script exited 1 silently right after cloning PAL sources - fixed;
    (3) ik_teleop runtime bug -> patch 0004; (4) `tools/smoke_test_tcp.sh` cleaned up with
    `pkill -f robot_state_publisher` etc., which also killed a Gazebo/robot stack running on the
    same machine - it now only stops the process groups it started.
  * Result: **17 packages finished, exit 0** (3 min 51 s on 4 cores, no manual steps); re-run:
    all 4 patches "already applied", clones kept, 17 packages in 3.5 s, exit 0.
  * PAL-docker emulation (PAL description/config packages installed into `/opt/pal/alum`, run as
    root): underlay auto-sourced, nothing cloned, rosdep skips the PAL keys, 6 packages built,
    exit 0; `launch_pal`/`tiago_pro_*` resolved from `/opt/pal/alum`.
* `tools/headless_smoke_test.sh` (both `robot_description` as parameter and `--from-topic`):
  **PASS** - 470 XRMod -> 470 each on `/left_arm_cmd` `/right_arm_cmd` `/head_cmd` `/grip/left`
  `/grip/right` -> ~220 JointTrajectory each on arm_left/arm_right/torso/head (20 Hz,
  `time_from_start` 0.05 s, arm joint 1 at its 0.60 rad/s limit) and 470 on both gripper
  controllers; `default_server_endpoint` accepts TCP connections on port 10000.
  bio_ik is stochastic: in 1 of ~8 runs the IK stalled for a moment on "Motion is in collision"
  (a speed-limited step crossed a self-collision) and then recovered.
* `tools/smoke_test_tcp.sh`: **PASS** - fake TIAGo Pro (real URDF from `tiago_pro_description`,
  joint_state_publisher) + `launch_tiago_ik.py` + `ros_tcp_endpoint` + `fake_unity_client.py`
  speaking the Unity wire protocol (`__handshake ... "protocol": "ROS2"`):
  469 XRMod -> ~465 `/left_arm_cmd`/`/right_arm_cmd`/`/head_cmd`/`/grip/*` ->
  ~200 JointTrajectory each on arm_left/arm_right/torso/head (20 Hz) and ~465 on both grippers
  (closing to 0.07 -> 0.0 with patch 0005). `toggle_tracking`/`stop_robot` register OK (needs patch 0001).
* Re-verified after adding patch 0005 (re-run of the script on the verified workspace: 0001-0004
  "already applied", `+ 0005`, 17 packages, exit 0). `headless_smoke_test.sh` now also asserts the
  gripper target range over the whole squeeze ramp: before 0005 **FAIL** `[0.0000 0.9500]`, after
  **PASS** `[0.0000 0.0700]`; `smoke_test_tcp.sh` PASS (`gripper_range 0.0000 0.0700`).
* `TRANSPORT=both` (tcp + WebRTC) on an empty workspace in a fresh container:
  **25 packages finished, exit 0** (11 min; audio_utils' bundled OpenBLAS/FFTW is ~10 min).
  Only build-verified: `rtabmap_msgs` was provided from source because the container could not
  reach the ROS apt repo (on your machine rosdep installs `ros-humble-rtabmap-msgs`), and
  `rclpy_message_converter` / `topic_tools` (runtime deps of the launch file) could not be
  installed here, so `webrtc_launch/tiago_pro.launch.xml` was not started (it also needs the
  external signalling server).
* Not verifiable here: Gazebo (`tiago_pro_gazebo`), the real robot, a real Quest/Unity build,
  CycloneDDS over a real network, PAL's docs page (blocked by the container's proxy).

## 7. Known limitations / notes

* ARC_ROS2_TIAGO's README says `git clone --recurse-submodules`, but that fails: the gitlinks
  `ROS-TCP-Endpoint` and `picknik_controllers` have **no `.gitmodules` entry**
  (`fatal: no submodule mapping found in .gitmodules for path 'ROS-TCP-Endpoint'`), while
  `.gitmodules` lists `pick_ik` and four `tiago_dual_*` repos that are not in the tree. The
  script avoids this by cloning nothing recursively from ARC and pinning the needed repos itself.

* WebRTC profile (`TRANSPORT=webrtc`) is heavy: opentera's native client downloads a prebuilt
  libwebrtc from GitHub releases and compiles a bundled OpenCV; `map_image_generator` needs
  `ros-humble-rtabmap-msgs`; opentera needs GStreamer dev packages and `rsync` that no
  package.xml declares (the script apt-installs them for this profile). Its signalling server
  default (the original author's server) and room password are hard-coded in
  `webrtc_launch/launch/tiago_pro.launch.xml`. Unity_Bridge_VR **main** does not use it.
* `launch_tiago_ik.py` evaluates `if use_sensor_manager:` on the launch-argument *string*
  (`'False'` is truthy), so `tiago_pro_moveit_config/config/sensors_3d.yaml` is **always** loaded:
  control_node builds an octomap from `/throttle_filtering_points/filtered_points` (PAL's filtered
  head-camera cloud) and rejects IK solutions/steps that collide with it ("Planned End State
  Colliding" / "Motion is in collision"). `use_sensor_manager:=False` has no effect. Not patched
  (it is the behaviour the ARC author ran with); edit the launch file if you do not want it.
* `launch_tiago_ik.py` logs `Cannot infer URDF/SRDF from tiago_pro_moveit_config ... loaded from
  /robot_description topic` - expected (the URDF is taken from the running robot/sim).
* ik_teleop's `config/tiago_pro.srdf.xacro` is a modified copy of PAL's SRDF - if your robot has
  a different end-effector/FT-sensor configuration, pass the matching launch args
  (`end_effector_left:=... ft_sensor_left:=...`, same names as PAL's launch files).
* `teleop_msg_bridge` adds a fixed +0.5 m x offset (`left/right_world_trans`) and a 90 deg
  pitch tool transform (`config/tiago_bridge.yaml`) - tune for your operator/robot.

## 8. Security note

* The script's sparse checkout of ARC_ROS2_TIAGO contains only the teleop package directories,
  never the upstream repo-root files (which include machine-specific network/VPN config).
  Do not commit VPN keys, DDS peer lists or passwords to this repository either.
* `ros_tcp_endpoint` has no authentication or TLS: anyone who can reach TCP 10000 can publish
  `/xr_input` and `/cmd_vel` (i.e. move the robot). Bind it to an isolated robot network / VPN
  interface and firewall the port.
* The WebRTC `string_msg_bridge.py` publishes to any topic/type named in the incoming payload;
  whitelist topics before using that path on a real robot.
