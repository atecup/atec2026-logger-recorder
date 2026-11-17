#!/usr/bin/env python3
"""Audit closed rosbag2 SQLite bags for rate, receive gaps, and header lag.

Run after Ctrl-C has finalized the bag. Gap counts indicate intervals longer
than expected; without source sequence numbers they are not an exact packet
loss count and cannot identify where a message went missing.
"""

import argparse
import glob
import math
import sqlite3
import statistics
import subprocess
import sys
from collections import defaultdict
from pathlib import Path


EXPECTED_HZ = {
    "/global_pose": 20.0,
    "/imu/data_raw": 20.0,
    "/cmd_vel": 20.0,
    "/joint_states": 20.0,
    "/robot_state": 20.0,
    "/nav_state": 20.0,
    "/motion_state": 20.0,
    "/manipulation_state": 20.0,
}


EXPECTED_TYPES = {
    "/global_pose": "geometry_msgs/msg/PoseStamped",
    "/imu/data_raw": "sensor_msgs/msg/Imu",
    "/cmd_vel": "geometry_msgs/msg/Twist",
    "/joint_states": "sensor_msgs/msg/JointState",
    "/robot_state": "robotlogger_interfaces/msg/RobotState",
    "/nav_state": "robotlogger_interfaces/msg/NavState",
    "/motion_state": "robotlogger_interfaces/msg/MotionState",
    "/manipulation_state": "robotlogger_interfaces/msg/ManipulationState",
}


def expected_type(topic):
    if topic.startswith("/points_downsampled_"):
        return "sensor_msgs/msg/PointCloud2"
    if topic.startswith("/image_compressed_"):
        return "sensor_msgs/msg/CompressedImage"
    return EXPECTED_TYPES.get(topic)


def expected_hz(topic):
    if topic in EXPECTED_HZ:
        return EXPECTED_HZ[topic]
    if topic.startswith("/points_downsampled_") or topic.startswith("/image_compressed_"):
        return 1.0
    return None


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return float("nan")
    index = max(0, min(len(ordered) - 1, math.ceil(fraction * len(ordered)) - 1))
    return ordered[index]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bag", help="closed rosbag2 directory")
    parser.add_argument("--header-samples", type=int, default=10,
                        help="decode this many first and last messages per topic (default: 10)")
    parser.add_argument("--full-integrity", action="store_true",
                        help="run SQLite integrity_check instead of the faster quick_check")
    args = parser.parse_args()
    bag = Path(args.bag).expanduser().resolve()
    if not bag.is_dir():
        parser.error(f"bag directory does not exist: {bag}")
    try:
        active = subprocess.run(["pgrep", "-af", "[r]os2 bag record"],
                                text=True, capture_output=True, check=False)
    except FileNotFoundError:
        active = None
    if active and any(str(bag) in line for line in active.stdout.splitlines()):
        parser.error("this bag is still being recorded; stop it with Ctrl-C before auditing")
    if not (bag / "metadata.yaml").is_file():
        parser.error("bag is not finalized (metadata.yaml is missing); stop recording first")

    db_files = sorted(glob.glob(str(bag / "*.db3")))
    if not db_files:
        parser.error("no sqlite3 .db3 storage files found")

    # Per-topic receive timestamps are small; message blobs are only fetched
    # for a small edge sample when calculating header-to-recorder delay.
    topics = {}
    recv_times = defaultdict(list)
    blob_samples = defaultdict(list)
    integrity_rows = []
    for db_path in db_files:
        uri = Path(db_path).as_uri() + "?mode=ro&immutable=1"
        conn = sqlite3.connect(uri, uri=True)
        try:
            pragma = "integrity_check" if args.full_integrity else "quick_check"
            integrity = [row[0] for row in conn.execute(f"PRAGMA {pragma}")]
            integrity_rows.append((db_path, integrity))
            for topic_id, name, msg_type in conn.execute("SELECT id,name,type FROM topics"):
                topics[name] = msg_type
                times = [row[0] for row in conn.execute(
                    "SELECT timestamp FROM messages WHERE topic_id=? ORDER BY timestamp", (topic_id,)
                )]
                recv_times[name].extend(times)
                if not times or args.header_samples <= 0:
                    continue
                count = len(times)
                offsets = sorted(set(range(min(args.header_samples, count))) |
                                 set(range(max(0, count - args.header_samples), count)))
                for offset in offsets:
                    row = conn.execute(
                        "SELECT timestamp,data FROM messages WHERE topic_id=? ORDER BY timestamp LIMIT 1 OFFSET ?",
                        (topic_id, offset),
                    ).fetchone()
                    if row:
                        blob_samples[name].append((row[0], row[1]))
        finally:
            conn.close()

    try:
        from rclpy.serialization import deserialize_message
        from rosidl_runtime_py.utilities import get_message
    except ImportError as exc:
        print("Header timestamp analysis needs ROS 2 Python libraries. Source the ROS setup first.", file=sys.stderr)
        return 2

    print(f"Bag: {bag}")
    print(f"Storage files: {len(db_files)}")
    type_mismatches = [
        (name, actual, expected_type(name))
        for name, actual in topics.items()
        if expected_type(name) is not None and actual != expected_type(name)
    ]
    if type_mismatches:
        print("WARNING: topic type does not match recordlist:")
        for name, actual, expected in type_mismatches:
            print(f"  {name}: bag has {actual}; expected {expected}")
    check_name = "integrity_check" if args.full_integrity else "quick_check"
    print(f"SQLite {check_name}:")
    for db_path, results in integrity_rows:
        result = "; ".join(results) if results else "no result"
        print(f"  {Path(db_path).name}: {result}")
        if results != ["ok"]:
            print("SQLite database check failed; do not treat this bag as verified.", file=sys.stderr)
            return 1
    print("Counts and receive gaps (large gaps are not proof of packet loss):")
    for name in sorted(topics):
        times = sorted(recv_times[name])
        if not times:
            print(f"  {name}: count=0")
            continue
        duration = (times[-1] - times[0]) / 1e9 if len(times) > 1 else 0.0
        hz = (len(times) - 1) / duration if duration > 0 else 0.0
        period = 1.0 / expected_hz(name) if expected_hz(name) else None
        gaps = [(b - a) / 1e9 for a, b in zip(times, times[1:])]
        long_gaps = [gap for gap in gaps if period and gap > 1.5 * period]
        skipped_intervals = sum(max(1, round(gap / period) - 1) for gap in long_gaps) if period else 0
        target = expected_hz(name)
        rate_text = f"{hz:.3f} Hz" + (f" (target {target:g})" if target else "")
        gap_text = f", gaps>1.5x={len(long_gaps)}, possible missed intervals~{skipped_intervals}" if period else ""
        print(f"  {name}: count={len(times)}, span={duration:.3f}s, rate={rate_text}{gap_text}")

    print("Sampled recorder receive time minus header.stamp (positive means header was earlier):")
    for name in sorted(blob_samples):
        msg_type = topics[name]
        try:
            cls = get_message(msg_type)
        except (ImportError, ModuleNotFoundError, AttributeError):
            print(f"  {name}: type support unavailable for {msg_type}; source the team's interface workspace")
            continue
        deltas_ms = []
        for recv_ns, blob in blob_samples[name]:
            msg = deserialize_message(bytes(blob), cls)
            header = getattr(msg, "header", None)
            stamp = getattr(header, "stamp", None)
            if stamp is None:
                continue
            header_ns = int(stamp.sec) * 1_000_000_000 + int(stamp.nanosec)
            deltas_ms.append((recv_ns - header_ns) / 1e6)
        if not deltas_ms:
            print(f"  {name}: no header.stamp")
            continue
        print(
            f"  {name}: n={len(deltas_ms)}, receive-header ms "
            f"min/median/p95/max={min(deltas_ms):.3f}/"
            f"{statistics.median(deltas_ms):.3f}/"
            f"{percentile(deltas_ms, 0.95):.3f}/{max(deltas_ms):.3f}"
        )

    print("\nInterpretation: received counts/rates and long gaps show recording cadence. They cannot distinguish source silence, adapter loss, DDS loss, or storage loss. Exact drop rates require monotonically increasing source sequence numbers or source-side sent counters. Header stamps must use a clock synchronized to the recorder; publish-time stamps omit acquisition-to-publish delay.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
