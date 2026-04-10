#!/bin/bash
free -m
echo  ---
grep ^MemAvailable: /proc/meminfo
