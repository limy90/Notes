```
#box
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 262144 33554432
net.ipv4.tcp_wmem = 4096 131072 33554432
net.ipv4.tcp_mem = 262144 524288 1048576
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
```
```
sysctl -p
```
