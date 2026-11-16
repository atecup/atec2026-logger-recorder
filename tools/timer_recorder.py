#!/usr/bin/env python3
"""Record latest fresh serialized samples at the recordlist timer cadence."""

import argparse
import re
import signal
import sys
import time

import rclpy
import rosbag2_py
from rclpy.clock import Clock, ClockType
from rclpy.executors import SingleThreadedExecutor
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy
from rosidl_runtime_py.utilities import get_message

from audit_bag import expected_hz, expected_type


class TimerRecorder(Node):
    def __init__(self, args):
        super().__init__('robotlogger_timer_recorder')
        self.writer = rosbag2_py.SequentialWriter()
        options = rosbag2_py.StorageOptions(uri=args.output, storage_id=args.storage)
        for key, value in [('max_bagfile_size', args.split_bytes),
                           ('max_cache_size', args.max_cache_size)]:
            if not hasattr(options, key):
                raise RuntimeError(f'This rosbag2 version does not support {key}')
            setattr(options, key, value)
        self.writer.open(options, rosbag2_py.ConverterOptions('cdr', 'cdr'))
        self.pattern = re.compile(args.regex)
        self.subscriptions_by_topic = {}
        self.latest = {}
        self.pending = set()
        self.warned = set()
        self.clock_wall = Clock(clock_type=ClockType.STEADY_TIME)
        self.sample_timers = [
            self.create_timer(1.0 / rate, lambda rate=rate: self.sample(rate),
                              clock=self.clock_wall)
            for rate in (20.0, 1.0)
        ]
        self.discovery_timer = self.create_timer(1.0, self.discover, clock=self.clock_wall)
        self.discover()

    def discover(self):
        for topic, types in self.get_topic_names_and_types():
            if topic in self.subscriptions_by_topic or not self.pattern.fullmatch(topic):
                continue
            if expected_hz(topic) is None:
                continue
            try:
                if len(types) != 1:
                    raise ValueError(f'ambiguous types: {types}')
                msg_type = types[0]
                required_type = expected_type(topic)
                if msg_type != required_type:
                    raise ValueError(f"expected {required_type}, got {msg_type}")
                cls = get_message(msg_type)
                qos = QoSProfile(history=HistoryPolicy.KEEP_LAST, depth=1,
                                 reliability=ReliabilityPolicy.BEST_EFFORT,
                                 durability=DurabilityPolicy.VOLATILE)
                # Raw subscriptions avoid deserializing large images and point clouds.
                sub = self.create_subscription(
                    cls, topic, lambda data, topic=topic: self.receive(topic, data),
                    qos, raw=True)
                try:
                    metadata = rosbag2_py.TopicMetadata(
                        name=topic, type=msg_type, serialization_format='cdr')
                    self.writer.create_topic(metadata)
                except Exception:
                    self.destroy_subscription(sub)
                    raise
                self.subscriptions_by_topic[topic] = sub
                self.get_logger().info(f'{topic}: timer {expected_hz(topic):g} Hz')
                self.warned.discard(topic)
            except Exception as exc:
                if topic not in self.warned:
                    self.get_logger().warning(f'Cannot subscribe to {topic}: {exc}; retrying')
                    self.warned.add(topic)

    def receive(self, topic, data):
        self.latest[topic] = data
        self.pending.add(topic)

    def sample(self, rate):
        # Single-threaded executor keeps reception and writer access serialized.
        for topic in list(self.pending):
            if expected_hz(topic) == rate:
                self.writer.write(topic, self.latest[topic], time.time_ns())
                self.pending.remove(topic)

    def close(self):
        # Destroy writer explicitly so metadata is finalized before process exit.
        self.writer = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--storage', default='sqlite3')
    parser.add_argument('--split-bytes', type=int, default=1073741824)
    parser.add_argument('--max-cache-size', type=int, default=0)
    parser.add_argument('--regex', required=True)
    args = parser.parse_args()
    rclpy.init(args=[])
    node = None
    executor = SingleThreadedExecutor()
    stopping = False

    def stop(signum, frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        node = TimerRecorder(args)
        executor.add_node(node)
        while not stopping and rclpy.ok():
            executor.spin_once(timeout_sec=0.2)
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        print(f'Timer recorder failed: {exc}', file=sys.stderr)
        return 1
    finally:
        if node is not None:
            node.close()
            node.destroy_node()
        executor.shutdown()
        if rclpy.ok():
            rclpy.shutdown()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
