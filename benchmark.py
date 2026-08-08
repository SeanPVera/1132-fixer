import time
import random
import string

# Create a large dummy string with 10,000 lines
lines = ["random data: " + ''.join(random.choices(string.ascii_letters, k=20)) for _ in range(9900)]
lines.insert(50, "interface: en0")  # The line we are looking for is near the start
output = "\n".join(lines)

def simulate_split():
    # Simulates output.split(whereSeparator: \.isNewline) which creates a full list
    split_lines = output.split('\n')
    for rawLine in split_lines:
        line = rawLine.strip()
        if line.startswith("interface:"):
            value = line[len("interface:"):].strip()
            return value

def simulate_enumerateLines():
    # Simulates output.enumerateLines which yields lines lazily
    # In Python, we can simulate this lazily using a generator over string indices or using a file-like object
    import io
    for rawLine in io.StringIO(output):
        line = rawLine.strip()
        if line.startswith("interface:"):
            value = line[len("interface:"):].strip()
            return value

# Benchmark
start = time.perf_counter()
for _ in range(100):
    simulate_split()
split_time = time.perf_counter() - start

start = time.perf_counter()
for _ in range(100):
    simulate_enumerateLines()
enum_time = time.perf_counter() - start

print(f"Baseline (split creating array): {split_time:.5f}s")
print(f"Optimized (lazy enumeration):    {enum_time:.5f}s")
print(f"Improvement: {(split_time - enum_time) / split_time * 100:.2f}% faster")
