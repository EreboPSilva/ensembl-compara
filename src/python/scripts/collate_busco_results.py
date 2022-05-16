#!/usr/bin/env python3

# See the NOTICE file distributed with this work for additional information
# regarding copyright ownership.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""
Script for collating per-genome BUSCO cDNA results.
"""

import argparse
import pandas as pd

# Parse command line arguments:
parser = argparse.ArgumentParser(
    description='Filter for longest BUSCO isoform.')
parser.add_argument(
    '-i', metavar='input', type=str, help="Input fofn.")
parser.add_argument(
    '-l', metavar='genes', type=str, help="List of busco genes.")
parser.add_argument(
    '-o', metavar='output', type=str, help="Output directory.", default="per_gene")


if __name__ == '__main__':
    args = parser.parse_args()

    genes = pd.read_csv(args.l, sep="\t")
    with open(args.i) as x:
        seq_files = [y.strip() for y in x.readlines()]

    for seq_file in seq_files:
        print(seq_file)
