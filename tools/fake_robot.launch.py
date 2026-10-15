# Minimal fake TIAGo Pro: robot_state_publisher + joint_state_publisher (no controllers).
import os
from launch import LaunchDescription
from launch_ros.actions import Node
from launch.substitutions import Command
from launch_ros.parameter_descriptions import ParameterValue
from ament_index_python.packages import get_package_share_directory

def generate_launch_description():
    xacro_file = os.path.join(get_package_share_directory('tiago_pro_description'), 'robots', 'tiago_pro.urdf.xacro')
    desc = ParameterValue(Command(['xacro ', xacro_file]), value_type=str)
    return LaunchDescription([
        Node(package='robot_state_publisher', executable='robot_state_publisher',
             parameters=[{'robot_description': desc}]),
        Node(package='joint_state_publisher', executable='joint_state_publisher',
             parameters=[{'robot_description': desc, 'rate': 20}]),
    ])
