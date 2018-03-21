# Copyright 2018 Wallaroo Labs Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
#  implied. See the License for the specific language governing
#  permissions and limitations under the License.


import argparse
import struct
import time
import wallaroo


def application_setup(args):
    parse_delay(args)
    in_host, in_port = wallaroo.tcp_parse_input_addrs(args)[0]
    out_host, out_port = wallaroo.tcp_parse_output_addrs(args)[0]

    nonce_source = wallaroo.TCPSourceConfig(in_host, in_port, nonce_decoder)
    ok_sink = wallaroo.TCPSinkConfig(out_host, out_port, ok_encoder)
    partitioner = TuplePartitioner(0)
    ab = wallaroo.ApplicationBuilder("sleepy-python")
    ab.new_pipeline("Counting Sheep", nonce_source)
    ab.to(process_nonce)
    ab.to_state_partition(
            busy_sleep, DreamData, "dream-data",
            partitioner, partitioner.partitions
        )
    ab.to_sink(ok_sink)
    return ab.build()


@wallaroo.decoder(header_length=4, length_fmt=">I")
def nonce_decoder(bytes):
    """
    Ignore most of the data and just read a partition key off of the
    message.
    """
    value = struct.unpack_from(">I", bytes)[0]
    return (value, bytes)


@wallaroo.encoder
def ok_encoder(_):
    """
    This encoder always returns a plain-text "ok" followed but a newline.
    It's useful for checking activity interactively during development.
    """
    return "ok\n"


@wallaroo.computation(name="Forward nonce partition")
def process_nonce(nonce):
    """
    We could probably do something more interesting but for now we pass
    the entire value forward.
    """
    return nonce


@wallaroo.state_computation(name="Count sheep")
def busy_sleep(data, state):
    delay(delay_ms)
    state.sheep += 1
    return (None, True)


class DreamData(object):
    __slots__ = ('sheep')

    def __init__(self):
        self.sheep = 0


class TuplePartitioner(object):
    """
    This partitioner uses a simple modulus operator and expects the partition
    key to be a tuple with an integer in the provided slot.
    """

    __slots__ = ('slot', 'partitions')

    def __init__(self, slot, size = 60):
        """
        Construct a simple partitioner with a given number of partitions.
        Defaults to 60 (a good number of integer factors for fair partition
        assignment).
        """
        self.slot = slot
        self.partitions = list(xrange(0, size))

    def partition(self, tuple):
        return self.partitions[tuple[self.slot] % len(self.partitions)]


# Set by --delay_ms argument
delay_ms = 0

def parse_delay(args):
    parser = argparse.ArgumentParser(prog='')
    parser.add_argument('--delay_ms', type=int, default=0)
    a, _ = parser.parse_known_args(args)
    global delay_ms
    delay_ms = a.delay_ms

def delay(ms):
    """
    This is an intentional busy sleep which blocks execution instead of allowing
    the GIL to be released.
    """
    if ms == 0:
       return
    target_time = time.time() + (ms / 1000.0)
    c = 0
    while target_time > time.time():
        c = c + 1
