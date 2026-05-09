#!/usr/bin/env python3
"""增强版文件分析器"""
import sys, os
from collections import Counter

f = sys.argv[1] if len(sys.argv) > 1 else input("文件路径: ")
if not os.path.exists(f): print("文件不存在"); exit(1)

size = os.path.getsize(f)
t = open(f).read()
l, w = t.splitlines(), t.split()
freq = Counter(w).most_common(3)
longest = max(w, key=len) if w else "N/A"

print(f"📄 {f}")
print(f"大小:{size}B  字符:{len(t)}  单词:{len(w)}  行:{len(l)}")
print(f"最长词:{longest}")
print("Top3:", ", ".join(f"{k}({v})" for k, v in freq))
