# RobotLogger Recorder（选手发布包）
本包只包含官方侧的ROS2 topic检查、rosbag2录制和录后审计工具。选手负责实现并运行 adapter，按 "recordlist.md" 发布约定的ROS2 topics

## 目录
robotlogger-recorder/
├── README.md
├── recordlist.md
├── deployment/
│   ├── robotlogger.sh
│   └── topics.regex
└── tools/
    └── audit_bag.py
请保留目录结构：录制脚本按相对路径读取 topic 白名单，录后审计也会调用 "tools/audit_bag.py"。

## 环境要求
- x86_64 Linux机器人，已安装并能运行ROS2和rosbag2。
- 机器人adapter已启动，并按recordlist.md发布topic。
- 如使用自定义ROS消息，消息接口包需为机器人正在使用的ROS2发行版构建并安装；首次检查时按提示提供它的install/setup.bash路径。
- SSD已挂载。若录制目录没有写权限，脚本会提示使用sudo。

## 检查与录制
将整个robotlogger-recorder目录复制到机器人任意可访问的位置，然后运行：
cd /path/to/robotlogger-recorder
deployment/robotlogger.sh check
deployment/robotlogger.sh

脚本会发现ROS2安装和可用的RMW，并检查SSD、空间和合同topic。首次运行时会提示确认ROS_DOMAIN_ID、SSD挂载目录和rosbag写入目录；例如可将挂载目录设为 `/mnt/robot-ssd`，写入目录设为 `/mnt/robot-ssd/rosbags`。robotlogger-recorder本身可以放在SSD以外的任意目录。提示项保存在当前用户的 `~/.config/robotlogger/robotlogger.conf`，下次运行会复用；需要改变时可编辑该文件或通过命令行参数覆盖。

固定名称的合同 topic（如 `/cmd_vel`、`/global_pose`）即使尚未启动，也不会让 `check` 失败；rosbag2 会每秒等待并订阅它们。topic 暂停时 bag 保持运行，同名、同类型且 QoS 兼容的 publisher 恢复后会继续收到消息。带设备 ID 的点云/图像 topic 若还未发布，脚本会提示输入完整名称并保存；也可用重复的 `--topic` 参数指定，例如 `deployment/robotlogger.sh record --topic /points_downsampled_mid360 --topic /image_compressed_front`。如果迟启动的状态 topic 使用自定义消息类型，首次提示时提供 adapter 的 `install/setup.bash`。

bag目录为：
<用户指定的SSD写入目录>/<机器人主机名>/<本地时间>

时间目录格式为 `YYYY_MMDD_HH_MM`，例如 `2026_1114_15_54`。同一分钟内重复启动时会自动追加 `_02`、`_03` 等编号，避免覆盖已有bag。
开始录制后按 "Ctrl-C" 正常结束并等待 rosbag2 完成收尾。
