#!/usr/bin/env python3
"""N uniform random 64-bit patterns (little-endian), deterministic seed. usage: rand_f64.py N SEED"""
import random, sys
random.seed(int(sys.argv[2]))
sys.stdout.buffer.write(random.randbytes(8 * int(sys.argv[1])))
