# RobotLogger Recorder

订阅 adapter 发布的 ROS 2 消息，定频写入 rosbag2。

- [消息规范](recordlist.md)
- [数据说明模板](templates/data_description.md)：填写后放在 adapter 目录，随 bag 交付。

## 目录

```text
robotlogger-recorder/
├── README.md
├── recordlist.md
├── interfaces/
│   └── robotlogger_interfaces/   # 状态消息接口
├── templates/
│   └── data_description.md
├── deployment/
│   ├── robotlogger.sh
│   └── topics.regex
└── tools/
    ├── timer_recorder.py
    └── audit_bag.py
```

请保留目录结构，脚本按相对路径读取白名单并调用录制、审计工具。

## 环境要求

- Linux 机器人，安装与系统和 CPU 架构匹配的 ROS 2、rosbag2 和 colcon。
- Python 3 可导入 `rclpy`、`rosbag2_py`、`rosidl_runtime_py`。
- adapter 按 [recordlist.md](recordlist.md) 发布消息，状态接口需在机器人使用的 ROS 2 环境中编译。
- 使用挂载盘时须提前挂载；保存目录没有写权限时，脚本会提示使用 sudo。

## 编译接口

加载对应 ROS 2 环境后，在仓库根目录编译状态接口：

```bash
source /opt/ros/jazzy/setup.bash  # 使用其他 ROS 2 发行版时替换 jazzy
colcon build --base-paths interfaces --packages-select robotlogger_interfaces
source install/setup.bash
```

## 录制

在仓库根目录运行，按提示填写挂载地址和保存目录：

```bash
deployment/robotlogger.sh record
```

保存到本机目录：

```bash
deployment/robotlogger.sh record --data /保存目录
```

脚本会发现 ROS 2 安装和可用的 RMW，并检查保存目录及剩余空间。首次运行按提示确认 ROS_DOMAIN_ID、挂载地址和保存目录，例如 `/mnt/robot-ssd`、`/mnt/robot-ssd/rosbags`。工具本身可放在其他目录。配置保存在 `~/.config/robotlogger/robotlogger.conf`，下次复用，也可编辑配置或通过命令行参数覆盖。

录制器持续每秒发现并订阅白名单话题，包括带设备 ID 的点云和图像。话题暂未发布时继续等待，暂停后恢复发布可继续录制，无需输入话题名称。按 Ctrl-C 结束并等待 bag 收尾。

接口默认加载 `install/setup.bash`，其他工作空间用 `--workspace /路径/install/setup.bash` 指定。参数见 `deployment/robotlogger.sh --help`。

bag 保存到 `<保存目录>/<机器人标识>/<YYYY_MMDD_HH_MM>/`。按规范频率记录最新样本，无新数据时不重复写入；bag 时间为写入时间，消息中的采样时间保持不变。

## 查看与审计

```bash
deployment/robotlogger.sh info /path/to/bag
deployment/robotlogger.sh audit /path/to/bag
```

审计支持 SQLite `.db3`，检查完整性、频率、消息间隔和时间戳；抽样跳过的 sequence 不代表传输丢包。
