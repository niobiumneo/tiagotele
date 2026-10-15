#!/usr/bin/env bash
# =============================================================================
# build_teleop_ws.sh - build ONLY the VR-teleoperation parts of ARC_ROS2_TIAGO
#                      for a PAL TIAGo Pro on ROS 2 Humble.
#
# Target machine: Ubuntu 22.04 + ROS 2 Humble (apt), or PAL's TIAGo Pro docker /
# PAL OS (Humble based; PAL packages under /opt/pal/<distro>).
#
# What gets built (TRANSPORT=tcp, the default - matches Unity_Bridge_VR 'main'):
#   ARC_ROS2_TIAGO (sparse checkout, no submodules):
#     custom_teleop_messages, bio_ik, ik_teleop, gripper_traj_passthrough
#   tylerjw/fp                       (header lib needed by bio_ik)
#   Unity-Technologies/ROS-TCP-Endpoint (main-ros2 = tag ROS2v0.7.0) -> ros_tcp_endpoint
# TRANSPORT=webrtc|both additionally builds webrtc_launch + opentera-webrtc-ros +
#   audio_utils + odas_ros (old WebRTC path, heavy; see docs/BUILD_NOTES.md).
#
# Robot-model deps used at *launch* time by ik_teleop (launch_pal,
# tiago_pro_description, tiago_pro_moveit_config, pal_sea_arm_moveit_config):
#   PAL_DEPS=auto   (default) use what is installed (PAL docker / robot / apt);
#                   otherwise let rosdep apt-install ros-humble-* binaries;
#                   only if that still fails, clone PAL sources at release tags.
#   PAL_DEPS=apt    installed/rosdep only, never clone PAL sources
#   PAL_DEPS=source always clone PAL sources into src/pal_deps
#   PAL_DEPS=skip   do nothing about them (build works, launch file will not)
#
# Usage:
#   ./build_teleop_ws.sh [--ws DIR] [--transport tcp|webrtc|both]
#                        [--pal-deps auto|apt|source|skip] [--no-rosdep]
#                        [--jobs N] [--arc-ref SHA|branch] [--clean]
# Every option also has an env var: WS, TRANSPORT, PAL_DEPS, SKIP_ROSDEP=1,
#   COLCON_JOBS, ARC_REF, ARC_REPO_URL, BUILD_TYPE, ROS_DISTRO, UNDERLAY.
#
# Idempotent: re-running updates/keeps clones, skips already-applied patches
# and does an incremental colcon build.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${PATCH_DIR:-$SCRIPT_DIR/patches}"

WS="${WS:-$HOME/teleop_ws}"
TRANSPORT="${TRANSPORT:-tcp}"
PAL_DEPS="${PAL_DEPS:-auto}"
SKIP_ROSDEP="${SKIP_ROSDEP:-0}"
COLCON_JOBS="${COLCON_JOBS:-}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
CLEAN=0
ARC_REPO_URL="${ARC_REPO_URL:-https://github.com/AdamSanderson93/ARC_ROS2_TIAGO.git}"
# Commit the patches were made against (HEAD of ARC_ROS2_TIAGO main, 2026-08-13).
ARC_REF="${ARC_REF:-32e37a484324bd0be29bf43ad7aed1e344594680}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ws) WS="$2"; shift 2 ;;
    --transport) TRANSPORT="$2"; shift 2 ;;
    --pal-deps) PAL_DEPS="$2"; shift 2 ;;
    --no-rosdep) SKIP_ROSDEP=1; shift ;;
    --jobs) COLCON_JOBS="$2"; shift 2 ;;
    --arc-ref) ARC_REF="$2"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

case "$TRANSPORT" in tcp|webrtc|both) ;; *) echo "TRANSPORT must be tcp|webrtc|both" >&2; exit 2 ;; esac
case "$PAL_DEPS" in auto|apt|source|skip) ;; *) echo "PAL_DEPS must be auto|apt|source|skip" >&2; exit 2 ;; esac

log()  { printf '\n\033[1;34m[teleop_ws]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[teleop_ws] WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[teleop_ws] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

SUDO=""
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
fi

# ---------------------------------------------------------------- environment
ROS_DISTRO="${ROS_DISTRO:-humble}"
[[ -f "/opt/ros/$ROS_DISTRO/setup.bash" ]] || die "/opt/ros/$ROS_DISTRO/setup.bash not found. Install ROS 2 Humble (Ubuntu 22.04) or run inside PAL's TIAGo Pro docker."
[[ "$ROS_DISTRO" == "humble" ]] || warn "ROS_DISTRO=$ROS_DISTRO - this workspace was verified on Humble only (TIAGo Pro / PAL OS is Humble)."

# setup.bash files reference unset variables; don't let 'set -u' kill us.
set +u
# shellcheck disable=SC1090
source "/opt/ros/$ROS_DISTRO/setup.bash"
# PAL OS / PAL docker keep PAL packages in /opt/pal/<distro>. Source it as an underlay if present.
if [[ -z "${UNDERLAY:-}" ]]; then
  for f in /opt/pal/*/setup.bash; do [[ -f "$f" ]] && UNDERLAY="$f"; done
fi
if [[ -n "${UNDERLAY:-}" && -f "$UNDERLAY" ]]; then
  log "Sourcing underlay $UNDERLAY"
  # shellcheck disable=SC1090
  source "$UNDERLAY"
fi
set -u

need_tools=()
command -v git    >/dev/null || need_tools+=(git)
command -v colcon >/dev/null || need_tools+=(python3-colcon-common-extensions)
command -v rosdep >/dev/null || need_tools+=(python3-rosdep)
if (( ${#need_tools[@]} )); then
  log "Installing build tools: ${need_tools[*]}"
  $SUDO apt-get update && $SUDO apt-get install -y "${need_tools[@]}" || die "could not install ${need_tools[*]}"
  APT_UPDATED=1
fi

# ------------------------------------------------------------------- helpers
# clone_pinned <dir> <url> <ref> [recursive]
#   Shallow fetch of exactly <ref> (commit SHA, tag or branch). Re-runs only
#   re-fetch when the checked-out commit differs from the requested one.
clone_pinned() {
  local dir="$1" url="$2" ref="$3" recursive="${4:-}"
  if [[ ! -d "$dir/.git" ]]; then
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$url"
  fi
  local want have
  have="$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null || true)"
  if [[ "$ref" =~ ^[0-9a-f]{40}$ && "$have" == "$ref" ]]; then
    echo "  = $(basename "$dir") @ ${ref:0:10} (already checked out)"
  else
    if ! git -C "$dir" fetch -q --depth 1 origin "$ref"; then
      [[ -n "$have" ]] || die "git fetch $url $ref failed"
      warn "fetch of $url $ref failed (offline?) - keeping existing checkout ${have:0:10}"
      return 0
    fi
    want="$(git -C "$dir" rev-parse FETCH_HEAD)"
    if [[ "$have" != "$want" ]]; then
      git -C "$dir" -c advice.detachedHead=false checkout -q --force "$want"
    fi
    echo "  + $(basename "$dir") @ ${want:0:10} ($ref)"
  fi
  if [[ "$recursive" == "recursive" ]]; then
    git -C "$dir" submodule update -q --init --recursive --depth 1 || \
      git -C "$dir" submodule update -q --init --recursive || die "submodules of $url failed"
  fi
}

# apply_patch_idempotent <repo_dir> <patch>
#   NOTE: each patch is checked on its own ('git apply --reverse --check'), so patches must not
#   change lines inside another patch's hunk context - otherwise re-runs die after the first one.
apply_patch_idempotent() {
  local repo="$1" patch="$2" name; name="$(basename "$patch")"
  if git -C "$repo" apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "  = $name (already applied)"
  elif git -C "$repo" apply --check "$patch" >/dev/null 2>&1; then
    git -C "$repo" apply "$patch"; echo "  + $name"
  else
    die "patch $name does not apply to $repo (ARC_REF=$ARC_REF). Upstream changed? Use the default ARC_REF or refresh the patch."
  fi
}

pkg_available() {  # is a ROS package findable in the sourced environment (not the workspace)?
  ros2 pkg prefix "$1" >/dev/null 2>&1
}

ws_has_pkg() {  # is a package present (not ignored) in the workspace sources?
  colcon list --base-paths "$WS/src" --names-only 2>/dev/null | grep -qx "$1"
}

# ----------------------------------------------------------------- workspace
if (( CLEAN )); then
  log "--clean: removing $WS/build $WS/install $WS/log"
  rm -rf "$WS/build" "$WS/install" "$WS/log"
fi
mkdir -p "$WS/src"
cd "$WS"

# 1) ARC_ROS2_TIAGO - sparse, no submodules, no repo-root files.
ARC_DIR="$WS/src/ARC_ROS2_TIAGO"
ARC_PKGS=(custom_teleop_messages bio_ik ik_teleop gripper_traj_passthrough)
[[ "$TRANSPORT" != "tcp" ]] && ARC_PKGS+=(webrtc_launch)
log "ARC_ROS2_TIAGO ($ARC_REF) - sparse checkout of: ${ARC_PKGS[*]}"
if [[ ! -d "$ARC_DIR/.git" ]]; then
  git clone -q --filter=blob:none --no-checkout "$ARC_REPO_URL" "$ARC_DIR" || \
    git clone -q --no-checkout "$ARC_REPO_URL" "$ARC_DIR"
fi
sparse=(); for p in "${ARC_PKGS[@]}"; do sparse+=("/$p/"); done
git -C "$ARC_DIR" sparse-checkout set --no-cone "${sparse[@]}"
if ! git -C "$ARC_DIR" cat-file -e "${ARC_REF}^{commit}" 2>/dev/null; then
  git -C "$ARC_DIR" fetch -q origin "$ARC_REF" || git -C "$ARC_DIR" fetch -q origin
fi
cur="$(git -C "$ARC_DIR" rev-parse -q --verify HEAD 2>/dev/null || true)"
tgt="$(git -C "$ARC_DIR" rev-parse "${ARC_REF}^{commit}" 2>/dev/null || git -C "$ARC_DIR" rev-parse "origin/${ARC_REF}")"
if [[ "$cur" != "$tgt" || -z "$(git -C "$ARC_DIR" ls-files | head -n1)" ]]; then
  # fresh --no-checkout clone (empty index) or a different ARC_REF: (re)populate the sparse tree.
  # --force drops previously applied patches; they are re-applied right below.
  git -C "$ARC_DIR" -c advice.detachedHead=false checkout -q --force "$tgt"
fi
echo "  ARC_ROS2_TIAGO @ ${tgt:0:10}; checked out: $(cd "$ARC_DIR" && ls -d */ | tr -d / | tr '\n' ' ')"

log "Applying patches from $PATCH_DIR"
for p in "$PATCH_DIR"/0*.patch; do apply_patch_idempotent "$ARC_DIR" "$p"; done
if [[ "$TRANSPORT" != "tcp" ]]; then
  apply_patch_idempotent "$ARC_DIR" "$PATCH_DIR/w001-webrtc_launch-declare-launch-runtime-deps.patch"
fi

# 2) third-party sources (pinned to the commits ARC_ROS2_TIAGO references as submodules)
log "Third-party sources"
clone_pinned "$WS/src/fp" https://github.com/tylerjw/fp.git 32301582d41c5741ff6453db9791d7d594afd75f
if [[ "$TRANSPORT" == "tcp" || "$TRANSPORT" == "both" ]]; then
  # gitlink in ARC_ROS2_TIAGO (no .gitmodules entry) = main-ros2 = tag ROS2v0.7.0 (v0.7.0 is ROS 1)
  clone_pinned "$WS/src/ROS-TCP-Endpoint" https://github.com/Unity-Technologies/ROS-TCP-Endpoint.git 54c1a64b6d5ef6ffa0a0431570bb74329b79b15b
fi
if [[ "$TRANSPORT" == "webrtc" || "$TRANSPORT" == "both" ]]; then
  clone_pinned "$WS/src/webrtc/opentera-webrtc-ros" https://github.com/introlab/opentera-webrtc-ros.git cd3705b1c23a08d357617605e9162920453d2882 recursive
  clone_pinned "$WS/src/webrtc/audio_utils" https://github.com/introlab/audio_utils.git cfa851d947aee69a5dc590a35ec6b6ab25398a64 recursive
  clone_pinned "$WS/src/webrtc/odas_ros" https://github.com/introlab/odas_ros.git 0d26e657fd129a5398469ed3d320d07a04462a4e recursive
  # opentera packages webrtc_launch does not need (they pull rviz plugins, nav2, Qt GUIs, npm builds)
  for p in opentera_client_ros opentera_webrtc_demos opentera_webrtc_robot_gui face_cropping turtlebot3_beam_description; do
    [[ -d "$WS/src/webrtc/opentera-webrtc-ros/$p" ]] && touch "$WS/src/webrtc/opentera-webrtc-ros/$p/COLCON_IGNORE"
  done
  # audio_utils -> MusicBeatDetector (nested submodule) bundles OpenBLAS 0.3.20 whose CPU
  # auto-detection fails on newer CPUs; let OPENBLAS_TARGET force a target.
  apply_patch_idempotent "$WS/src/webrtc/audio_utils/audio_utils/src/MusicBeatDetector" \
      "$PATCH_DIR/w002-audio_utils-MusicBeatDetector-openblas-target.patch"
  if [[ -z "${OPENBLAS_TARGET+x}" && "$(uname -m)" == "x86_64" ]]; then export OPENBLAS_TARGET=HASWELL; fi
  echo "  OPENBLAS_TARGET=${OPENBLAS_TARGET:-<auto-detect>}"
fi

TARGETS=(custom_teleop_messages bio_ik ik_teleop gripper_traj_passthrough)
[[ "$TRANSPORT" != "webrtc" ]] && TARGETS+=(ros_tcp_endpoint)
[[ "$TRANSPORT" != "tcp" ]] && TARGETS+=(webrtc_launch)

# 3) PAL robot-model packages needed by ik_teleop/launch/launch_tiago_ik.py
PAL_PKGS=(launch_pal tiago_pro_description tiago_pro_moveit_config pal_sea_arm_moveit_config)
missing_pal() {
  local m=()
  for p in "${PAL_PKGS[@]}"; do pkg_available "$p" || ws_has_pkg "$p" || m+=("$p"); done
  echo "${m[*]:-}"
}

clone_pal_sources() {
  log "Cloning PAL TIAGo Pro description/config sources (release tags matching ros-humble binaries) into src/pal_deps"
  local d="$WS/src/pal_deps"
  clone_pinned "$d/launch_pal"                https://github.com/pal-robotics/launch_pal.git 0.22.1
  clone_pinned "$d/tiago_pro_robot"           https://github.com/pal-robotics/tiago_pro_robot.git 2.5.1
  clone_pinned "$d/tiago_pro_moveit_config"   https://github.com/pal-robotics/tiago_pro_moveit_config.git 1.5.2
  clone_pinned "$d/pal_sea_arm_moveit_config" https://github.com/pal-robotics/pal_sea_arm_moveit_config.git 1.0.7
  clone_pinned "$d/pal_sea_arm"               https://github.com/pal-robotics/pal_sea_arm.git 2.8.4
  clone_pinned "$d/pal_pro_gripper"           https://github.com/pal-robotics/pal_pro_gripper.git 1.12.6
  clone_pinned "$d/tiago_pro_head_robot"      https://github.com/pal-robotics/tiago_pro_head_robot.git 1.12.0
  clone_pinned "$d/omni_base_robot"           https://github.com/pal-robotics/omni_base_robot.git 2.18.0
  clone_pinned "$d/pal_urdf_utils"            https://github.com/pal-robotics/pal_urdf_utils.git 2.11.1
  if ! pkg_available realsense2_description; then
    clone_pinned "$d/realsense-ros"           https://github.com/IntelRealSense/realsense-ros.git 4.59.1
  fi
  # Only keep what the URDF/SRDF xacro + launch file need; ignore bringup/sim/driver packages.
  local keep=" launch_pal tiago_pro_description tiago_pro_moveit_config pal_sea_arm_moveit_config pal_sea_arm_description pal_pro_gripper_description tiago_pro_head_description omni_base_description pal_urdf_utils realsense2_description realsense2_camera_msgs "
  local px dir name
  while IFS= read -r px; do
    dir="$(dirname "$px")"
    name="$(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' "$px" | head -1)"
    if [[ "$keep" == *" $name "* ]]; then rm -f "$dir/COLCON_IGNORE"; else touch "$dir/COLCON_IGNORE"; fi
  done < <(find "$d" -name package.xml -not -path '*/.git/*')
  # Already installed (e.g. realsense2_description from apt) -> don't shadow it.
  for name in realsense2_description realsense2_camera_msgs; do
    if pkg_available "$name"; then
      px="$(grep -rl "<name>$name</name>" "$d" --include=package.xml 2>/dev/null | head -1 || true)"
      # (an 'if', not '[[ ]] && touch': a false test as the function's last status
      #  made the caller exit silently under 'set -e' when realsense was apt-installed)
      if [[ -n "$px" ]]; then touch "$(dirname "$px")/COLCON_IGNORE"; fi
    fi
  done
  return 0
}

log "Checking robot-model packages: ${PAL_PKGS[*]}"
MISSING="$(missing_pal)"
if [[ -z "$MISSING" ]]; then
  echo "  all present (installed or in workspace) - nothing to clone"
else
  echo "  not installed: $MISSING"
  [[ "$PAL_DEPS" == "source" ]] && clone_pal_sources
fi

# 4) rosdep (only for the packages we actually build)
pkg_paths() {
  colcon list --base-paths "$WS/src" --packages-up-to "${TARGETS[@]}" --paths-only 2>/dev/null
}
run_rosdep() {
  (( SKIP_ROSDEP )) && { warn "SKIP_ROSDEP=1 - not installing system dependencies"; return 0; }
  if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
    log "rosdep init"; $SUDO rosdep init || true
  fi
  if [[ ! -d "$HOME/.ros/rosdep/sources.cache" ]] || [[ -n "${ROSDEP_FORCE_UPDATE:-}" ]]; then
    log "rosdep update"; rosdep update --rosdistro "$ROS_DISTRO" || warn "rosdep update failed"
  fi
  mapfile -t paths < <(pkg_paths)
  (( ${#paths[@]} )) || die "colcon found none of: ${TARGETS[*]} under $WS/src"
  # rosdep never refreshes apt indexes itself. ROS / PAL docker images ship with empty
  # /var/lib/apt/lists, so without this e.g. librange-v3-dev is "Unable to locate" and fp/bio_ik fail.
  if [[ -z "${APT_UPDATED:-}" ]] && command -v apt-get >/dev/null; then
    log "apt-get update"; $SUDO apt-get update || warn "apt-get update failed (continuing)"
    APT_UPDATED=1
  fi
  log "rosdep install for ${#paths[@]} packages"
  # -r: keep going if a key cannot be installed; colcon will tell us if it matters.
  # Skipped keys: fp is built from source here; cv_camera (exec-only, not in rosdep) and
  # 'framework' (bogus key in opentera's map_image_generator) only matter for TRANSPORT=webrtc.
  rosdep install --from-paths "${paths[@]}" --ignore-src -y -r --rosdistro "$ROS_DISTRO" \
      --skip-keys "fp cv_camera framework" || warn "rosdep reported problems (see above); continuing"
}
run_rosdep

# System packages the WebRTC stack needs but no package.xml declares (from ARC's install_deps.sh,
# reduced to what opentera_webrtc_ros / audio_utils / odas_ros_msgs actually use).
if [[ "$TRANSPORT" != "tcp" ]] && (( ! SKIP_ROSDEP )); then
  log "WebRTC profile: apt + pip build dependencies"
  $SUDO apt-get install -y --no-install-recommends rsync unzip python3-pip python3-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgstreamer-plugins-bad1.0-dev \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav \
    libssl-dev libglib2.0-dev libopencv-dev libpulse-dev libasound2-dev portaudio19-dev \
    gfortran texinfo libfftw3-dev libconfig-dev libunwind-dev \
    || warn "some WebRTC apt packages failed to install"
  pip_user=(); [[ $EUID -ne 0 ]] && pip_user=(--user)
  python3 -m pip install "${pip_user[@]}" -r "$WS/src/webrtc/opentera-webrtc-ros/opentera_webrtc_ros/opentera-webrtc/requirements.txt" \
    || warn "pip install of opentera-webrtc requirements failed"
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
fi

if [[ "$PAL_DEPS" == "auto" ]]; then
  MISSING="$(missing_pal)"
  if [[ -n "$MISSING" ]]; then
    warn "still missing after rosdep: $MISSING -> falling back to PAL sources"
    clone_pal_sources
    run_rosdep
  fi
elif [[ "$PAL_DEPS" == "apt" ]]; then
  MISSING="$(missing_pal)"
  [[ -z "$MISSING" ]] || warn "PAL_DEPS=apt and still missing: $MISSING (ik_teleop builds, but its launch file will fail)"
fi

# 5) build
log "colcon build --packages-up-to ${TARGETS[*]}"
colcon_args=(build --symlink-install --base-paths "$WS/src" --packages-up-to "${TARGETS[@]}"
             --cmake-args "-DCMAKE_BUILD_TYPE=$BUILD_TYPE" -DBUILD_TESTING=OFF)
[[ -n "$COLCON_JOBS" ]] && colcon_args+=(--parallel-workers "$COLCON_JOBS")
colcon "${colcon_args[@]}"

# 6) post-check
set +u
# shellcheck disable=SC1091
source "$WS/install/setup.bash"
set -u
log "Post-build check"
rc=0
for p in "${TARGETS[@]}"; do
  if pkg_available "$p"; then printf '  ok   %-28s %s\n' "$p" "$(ros2 pkg prefix "$p")"
  else printf '  MISSING %-25s\n' "$p"; rc=1; fi
done
for p in "${PAL_PKGS[@]}"; do
  if pkg_available "$p"; then printf '  ok   %-28s %s\n' "$p" "$(ros2 pkg prefix "$p")"
  else printf '  MISSING %-25s (needed by launch_tiago_ik.py at runtime)\n' "$p"
       warn "$p not available - the build is fine but 'ros2 launch ik_teleop launch_tiago_ik.py' will fail"; fi
done
python3 -c "from custom_teleop_messages.srv import BoolTrigger; from custom_teleop_messages.msg import XRMod" \
  && echo "  ok   custom_teleop_messages/XRMod + srv/BoolTrigger importable" || rc=1

cat <<EOF

Done. In every new terminal:
  source /opt/ros/$ROS_DISTRO/setup.bash${UNDERLAY:+ && source $UNDERLAY} && source $WS/install/setup.bash

Run (see docs/BUILD_NOTES.md for sim / real robot / DDS details):
  ros2 launch ik_teleop launch_tiago_ik.py use_sim_time:=True        # False on the real robot
  ros2 run ros_tcp_endpoint default_server_endpoint --ros-args -p ROS_IP:=0.0.0.0 -p ROS_TCP_PORT:=10000
EOF
exit $rc
