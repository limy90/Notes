### DD12
```
(curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh || wget -O reinstall.sh https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh) && bash reinstall.sh debian12 --ssh-port 22 --password reboot && reboot
```
### kejilion
```
bash <(curl -sL kejilion.sh)
```
### v4/v6切换
```
bash -c '(grep -q "^precedence ::ffff:0:0/96" /etc/gai.conf && sed -i "/^precedence ::ffff:0:0\/96/s/^/#/" /etc/gai.conf && hostname -I | grep -oE "([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}" | head -1) || ((sed -i "/^#precedence ::ffff:0:0\/96  100/s/^#//" /etc/gai.conf || echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf) && hostname -I | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | head -1)'
```
### 修改Hostname
```
hostnamectl set-hostname name
```
### 更改时区/颜色
```
{ cat <<'EOF'
PS1="\[\033]2;\h:\u\w\007\033[33;1m\]\u\[\033[0m\]\[\033[36;1m\]@\h\[\033[0m\]\[\033[35;1m\] \w\[\033[0m\]\[\033[32;1m\] \$([ \$EUID -eq 0 ] && echo '#' || echo '$') \[\033[0m\]"
EOF
} >> ~/.bashrc && source ~/.bashrc && timedatectl set-timezone Asia/Shanghai
```
### 临时关闭ipv6   重启恢复
``` 
sysctl -w net.ipv6.conf.all.disable_ipv6=1 && sysctl -w net.ipv6.conf.default.disable_ipv6=1
```
### 永久禁用ipv6
```
bash -c 'echo -e "net.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.default.disable_ipv6=1\nnet.ipv6.conf.lo.disable_ipv6=1" > /etc/sysctl.d/99-disable-ipv6.conf && sysctl -p /etc/sysctl.d/99-disable-ipv6.conf'
```
