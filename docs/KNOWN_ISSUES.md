# Known issues in the ARC teleop stack (not fixed by the patches)

The patches in `patches/` make the ARC_ROS2_TIAGO teleop packages build and run correctly
(see [BUILD_NOTES.md](BUILD_NOTES.md), section 4). The items below are design gaps that remain.
They matter on a **real** TIAGo Pro. Work through the blockers before the first hardware test,
and keep a second person on the emergency stop.

File references are to the upstream ARC_ROS2_TIAGO / Unity_Bridge_VR sources. Once you have run
the script, they are in `~/teleop_ws/src/ARC_ROS2_TIAGO/...`.

## Blocker

### 1. No software stop, pause or deadman
* Unity (`ToggleTrackingController.cs`) calls the `toggle_tracking` and `stop_robot` services
  (`custom_teleop_messages/srv/BoolTrigger`). Patch 0001 lets them register, but **no ROS node
  serves them**, so pressing those buttons does nothing. The endpoint logs
  `service is not ready`.
* `SendControllerData.cs` streams `/xr_input` and `/cmd_vel` every frame while connected.
  Tracking is always on, and the hardware e-stop is the only real stop.
* Suggested fix:
  * Implement both services in `control_node`. `toggle_tracking` should gate goal acceptance
    and default to OFF. `stop_robot` should send a hold trajectory at the measured
    `/joint_states` and one zero `Twist`.
  * Add a deadman in Unity (for example, the grip must be held).
  * Add a ROS-side watchdog that drops `/xr_input` older than about 200 ms.

## Major

### 2. Absolute, open-loop pose mapping
* `teleop_msg_bridge` maps Quest tracking-space poses straight into `base_link`, plus a fixed
  +0.5 m x offset and a 90° pitch (`ik_teleop/config/tiago_bridge.yaml`). There is no clutch,
  so enabling teleop makes the arms jump to wherever your hands are.
* bio_ik returns approximate solutions, so unreachable targets stretch the arm to its limits.
* `control_node` reads `/joint_states` only at startup (`allowable_lag` defaults to -1). After a
  protective stop, e-stop or controller switch its internal state diverges from the robot, and
  resuming can cause large corrective motions.
* Suggested fix: add a clutch (capture `T_robot_ee * inv(T_xr_ctrl)` on enable, then apply relative
  motion), clamp targets to a workspace box, and re-seed from `/joint_states` on enable and after
  every stop.

### 3. Lost tracking and dropped links are not handled
Unity never reads the controller tracking state. The bridge drops a message only if a position is
almost exactly (0,0,0), and nothing checks message age, so frozen or drifting controller poses are
executed. Send the tracking state (and a timestamp) with `XRMod`, and freeze goals when it is lost.

### 4. Trajectory format vs PAL's controllers
`control_node` sends single-point trajectories, 50 ms ahead at 20 Hz, that end with **non-zero
velocity**. On the robot, check:
```bash
ros2 param get /arm_left_controller allow_nonzero_velocity_at_trajectory_end
```
If it is `false`, the commands may be rejected. In that case send zero velocity at the last point,
or send 2-3 points spanning 1/hz to 3/hz. Even when accepted, a late command produces stop-and-go
motion.

### 5. Speed limits
Joint speeds are capped at `joint_limits.yaml` `max_velocity` (arms 0.60 and 0.75 rad/s, close to the
board limits). Accelerations are a constant 0.05, there is no jerk or Cartesian cap, and the head
falls back to `default_max_speed` (1.0). For first tests, add per-group multipliers under
`IK_control_node.ros__parameters` in `ik_teleop/config/tiago_bio_ik_teleop.yaml`:
```yaml
    arm_left:
      speed_mult: 0.2
    arm_right:
      speed_mult: 0.2
```

### 6. Thumbsticks drive the base, continuously
Unity publishes `geometry_msgs/Twist` on `/cmd_vel` every frame: up to 0.25 m/s linear and 0.5 rad/s
angular, with no deadzone, and zeros when idle. On TIAGo Pro, `cmd_vel` is twist_mux's lowest-priority
`navigation` input (priority 10, 0.5 s timeout), so it moves the omni base and shares the topic with
Nav2. Suggested fix: use a dedicated twist_mux input with a deadzone and a deadman.

## Minor

* **Controller ownership.** `control_node` needs `arm_left_controller`, `arm_right_controller`,
  `torso_controller` and `head_controller` (JointTrajectoryControllers) to be active. Stop PAL VR
  teleop, WBC and TSID controllers first (`ros2 control list_controllers`), and never run two
  command sources at once.
* **Gripper.** Commands are sent with `time_from_start` 0 at about 100 Hz. Patch 0005 sets the
  range for the current prismatic PAL Pro gripper. Check your gripper type as described in
  BUILD_NOTES section 5.2.
* **Octomap is always on.** `launch_tiago_ik.py` evaluates `if use_sensor_manager:` on the launch
  argument *string*. `'False'` is truthy, so `sensors_3d.yaml` is always loaded.
* **rviz2 is always started** by `launch_tiago_ik.py`. On a headless machine it exits, which is
  harmless.
* **SRDF copy.** `ik_teleop/config/tiago_pro.srdf.xacro` is an older, modified copy of PAL's
  SRDF: it lacks the `has_teleop_arms` and `wrist_model_*` args, and it adds the `head` and
  `full_body` groups. If your robot's configuration differs from the defaults, pass the matching
  launch args.
* **Camera.** Unity subscribes to `/head_front_camera/color/image_raw/compressed`. That topic
  exists only if the image_transport compressed plugin is active. PAL's Gazebo bridge publishes only
  the raw image, so republish it (image_transport `republish`) and throttle it for Wi-Fi.
* **Unity project.**
  * The ROS IP is hard-coded in `Assets/Resources/ROSConnectionPrefab.prefab`.
  * The `ROS2` scripting define is set only for Android, so add it for Standalone/Editor use.
  * ROS-TCP-Connector is pulled from git without a pinned revision.
* **bio_ik is stochastic.** Occasionally a speed-limited step crosses a self-collision. The
  planner logs `Motion is in collision` (unthrottled) and recovers.
* **Networking/security.** `ros_tcp_endpoint` has no authentication. DDS uses the default
  domain unless you set `ROS_DOMAIN_ID`. Keep the robot, the endpoint and the headset on an
  isolated network.
