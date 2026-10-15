# Using PAL's VR teleoperation on TIAGo Pro (simulation first, then the real robot)

> **Read this first.** These notes were compiled without access to the PAL page text (docs.pal-robotics.com was not reachable from the environment used). Every PAL-specific command below comes from search-engine summaries of https://docs.pal-robotics.com/edge/manipulation/vr-teleoperation. None of it was checked against the page text. Before you run anything, **open that page in your own browser (or the docs on your robot or PAL image) and compare each command.**
>
> Labels used:
> - **[VERIFIED]**: read directly in a public PAL repository or in ARC_ROS2_TIAGO.
> - **[PAL page, unverified]**: several search summaries of the PAL page say this, but the page itself was not seen.
> - **[Inference]**: reasoning only; no source states it.

---

## 0. Check that you actually have the VR stack
- [PAL page, unverified] The page reportedly carries the banner "This page documents a **Premium robot feature**. It may or may not be available on your robot."
- [VERIFIED] The VR packages (`vr_teleop_backend`, `vr_teleop_frontend`, `tiago_pro_vr_wbc_cfg`) are **not public**:
  - they are not in ROS rosdistro humble or jazzy;
  - every `github.com/pal-robotics/<name>` probe failed;
  - the public `tiago_pro_simulation` repo has no VR code.
  - So you need PAL's robot-specific developer Docker image and/or the robot itself.
- How to check:
  - **On the dev PC**, inside your PAL developer image: `ros2 pkg list | grep -E "vr_teleop|vr_wbc"`
  - **On the robot**: WebGUI > Modules. Look for `vr_teleop_backend`, `vr_teleop_frontend` and `vr_teleop_controller`. Or SSH in and run `pal module list | grep vr`. (The `pal module` CLI comes from search summaries of https://docs.pal-robotics.com/edge/management/application-management and is unverified.)
- If the packages are missing, ask PAL support for the VR teleop package for your serial number. Pricing and licensing are not public.

## 1. Prepare the headset
- [PAL page, unverified] You need a configured **Meta Quest 3** connected to your network, and you should have done PAL's "Getting started".
- [PAL page, unverified] The interface is a **web page opened in the Quest browser**. One summary says it uses the WebXR API. No APK, Unity app or developer mode is mentioned.
- [Inference] The normal Meta first-time setup should be enough. Update Quest Browser.

## 2. Network
**Simulation**
- The headset and the PC running the frontend must be on the same LAN.
- [PAL page, unverified] Find the PC's IP with `ip a`, and make sure other devices can ping it.
- [VERIFIED] `pal_docker.sh` (pal_docker_utils) starts the container with `--net host` by default. A port opened inside Docker is therefore reachable on the host IP.
- [Inference] If you start the image with plain `docker run`, add `--net host` (or `-p 4443:4443`), and allow TCP 4443 in the host firewall.

**Real robot**
- [PAL page, unverified] The headset joins the **robot's Wi-Fi hotspot**, and the frontend runs **on the robot**.
- One summary says the SSID and password are in WebGUI > Networking.
- [Unverified snippet] The robot's internal network is 10.68.0.0/24. Your building network must not use that range.

## 3. Simulation test (PAL recommends doing this first)
Open each step in a new terminal inside the PAL developer container, and keep every terminal open.

1. **Start Gazebo.** [PAL page, unverified]
   ```bash
   ros2 launch tiago_pro_<your_serial_number>_gazebo tiago_pro_gazebo.launch.py
   ```
   - The generic PAL form, from the Simulation page snippets, is `source /opt/pal/${PAL_DISTRO}/setup.bash` then `ros2 launch tiago_pro_gazebo tiago_pro_gazebo.launch.py`.
   - Check which package your image has: `ros2 pkg list | grep gazebo`.
   - [VERIFIED] The public, source-built `tiago_pro_gazebo` requires `is_public_sim:=True` and contains no VR stack.
2. **Start the backend.** [PAL page, unverified]
   ```bash
   ros2 run vr_teleop_backend both_arms_teleop --base base_footprint
   ```
   The only argument is the base reference link, "in most of the cases, it should be base_footprint".
3. **Start the frontend**, then get the PC's IP. [PAL page, unverified]
   ```bash
   ros2 launch vr_teleop_frontend start_frontend.launch.py
   ip a
   ```
4. **Start the VR Whole Body Controller.** [PAL page, unverified]
   ```bash
   ros2 launch tiago_pro_vr_wbc_cfg tiago_pro_vr_teleop_controller.launch.py
   ```
   It reportedly does whole-body IK (including the torso) while avoiding self-collisions.
5. **Activate the VR controller.** Deactivate the others in the same call. [PAL page, unverified exact string]
   ```bash
   ros2 control switch_controllers --deactivate arm_right_controller arm_left_controller torso_controller head_controller --activate vr_teleop_controller --strict
   ros2 control list_controllers   # check: vr_teleop_controller is active
   ```
   [VERIFIED] These controller names exist on TIAGo Pro (public tiago_pro_robot repo).
6. **Connect the headset.** [PAL page, unverified]
   - In the Quest browser, open `https://<PC_IP>:4443`.
   - Accept the self-signed certificate warning. PAL says it is safe.
   - Read the instructions and press **start**. (One summary says start hides the instructions and shows passthrough; this could not be reproduced.)
   - Start with **one arm** and move slowly.

## 4. Real robot
1. **Start the modules.** [PAL page, unverified] In WebGUI > Modules, start the three modules whose names begin with `vr`: `vr_teleop_backend`, `vr_teleop_frontend` and `vr_teleop_controller`. On the robot you do not run the backend, frontend or WBC commands by hand.
2. **Move to the home position.** [PAL page, unverified] "The teleoperation must always start from the home position." Press Home in the WebGUI, or SSH into the robot and run:
   ```bash
   ros2 run play_motion2 run_motion home
   ```
   - [VERIFIED] This `run_motion` syntax and a `home` motion (torso plus both arms, about 10 s) exist in PAL's public repos.
   - [Inference] Run it **before** step 3, because it needs the normal arm and torso controllers.
3. **Activate the VR controller over SSH**, with the same `switch_controllers` command as in simulation step 5. [PAL page, unverified] After this, "you will not be able to execute predefined motions or move the arms manually."
4. **Connect the headset.** [PAL page, unverified]
   - Join the headset to the robot's Wi-Fi.
   - Open `https://<robot_ip>:4443` in the Quest browser. Some summaries give `https://10.68.0.1:4443/`; others could not confirm it. Check on your robot.
   - Accept the certificate, read the instructions and press start.
   - The robot reportedly does not move until you press start on the web page **and** press a main trigger.

## 5. Controls
All [PAL page, unverified]:
- **Main trigger (index finger), held:** the arm follows your hand. This is a dead man's switch: release it and the robot stops, with the arm holding its last pose.
- **Side trigger (middle finger):** the gripper on that side, proportional to how far you press, fully closed at full press. Only one of three searches reproduced this mapping.
- **Meta button (right controller):** stops teleoperation completely and brings back the instructions screen. Use it as the safe idle state.
- **Thumbsticks and A/B/X/Y:** not documented. There is no evidence that the base or head is driven from VR.
- [VERIFIED hardware detail] The pal-pro-gripper joint `gripper_<side>_finger_joint` goes from 0.0 (closed) to 0.07 (open).

## 6. Stop and return to normal operation
1. Release the triggers and press the Meta button.
2. Switch the controllers back. [Reconstructed; reportedly the page shows the activation command here by mistake]
   ```bash
   ros2 control switch_controllers --deactivate vr_teleop_controller --activate arm_right_controller arm_left_controller torso_controller head_controller --strict
   ros2 control list_controllers
   ```
3. Shut down the VR pieces:
   - **Real robot:** stop the `vr_*` modules in the WebGUI, or with `pal module stop <name>` (unverified CLI).
   - **Simulation:** press Ctrl-C in the backend, frontend and WBC terminals.

## 7. Safety
- [PAL page, unverified] Test in simulation first.
- [PAL page, unverified] Move slowly, and press the emergency button if you see any sudden motion.
- [Unverified snippet] E-stop recovery on TIAGo Pro: release the button, press the computer button, then `sudo systemctl restart pal_startup.service`. See https://docs.pal-robotics.com/edge/general/tiagopro/power-management.
- [Inference] The WBC is described as avoiding *self*-collisions only, so keep the workspace clear.
- [Inference] The base and the gripper controllers are not in the switch command. Joystick, WebGUI, navigation or other gripper commands could still act during VR teleop, so run only one command source at a time.
- **Never run PAL VR and ARC_ROS2_TIAGO at the same time.**
  - [VERIFIED] ARC's `ik_teleop` publishes JointTrajectory commands to the same arm, torso and head controllers that the VR switch deactivates.
  - [Inference] Those commands are ignored while the VR controller is active, and the two stacks would fight once you switch back.

## 8. Notes for the ARC-based stack in this repository
- **Gripper range** [VERIFIED]: ARC's `gripper_traj_passthrough` config sent `0.0 .. 0.95`; the PAL Pro gripper finger joint is prismatic `0.0` (closed) .. `0.07` m (open). Fixed by `patches/0005-gripper_traj_passthrough-pal-pro-gripper-range.patch`.
- **Base command relay** [VERIFIED]: `webrtc_launch/launch/tiago_pro.launch.xml` (WebRTC profile only) relays `/cmd_vel` to `/movo/cmd_vel`, a leftover for another robot. On TIAGo Pro, twist_mux reads `cmd_vel` at navigation priority 10 (`key_vel` 90, `joy_vel`/`tab_vel` 100) and outputs `mobile_base_controller/cmd_vel_unstamped`. The TCP path needs no relay.
- See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for what is still unfixed in the ARC stack.

## Sources
- PAL VR page (not fetched; search summaries only): https://docs.pal-robotics.com/edge/manipulation/vr-teleoperation
- PAL module CLI (snippets): https://docs.pal-robotics.com/edge/management/application-management
- PAL Simulation page (snippets): https://docs.pal-robotics.com/edge/general/getting-started-simulator
- Verified repos:
  - https://github.com/pal-robotics/tiago_pro_robot
  - https://github.com/pal-robotics/tiago_pro_simulation
  - https://github.com/pal-robotics/play_motion2
  - https://github.com/pal-robotics/pal_pro_gripper
  - https://github.com/pal-robotics/pal_docker_utils
  - https://github.com/pal-robotics/tiago_wbc (PAL WBC, proprietary, 100 Hz; TIAGo, not Pro)
- Third-party open-source WBC for TIAGo Pro (not PAL): https://github.com/hucebot/tiago_wbc_ros2
