### DD12
```
(curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh || wget -O reinstall.sh https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh) && bash reinstall.sh debian12 --ssh-port 22 --password reboot && reboot
```
### kejilion
```
bash <(curl -sL kejilion.sh)
```
### 临时关闭ipv6   重启恢复
``` 
sysctl -w net.ipv6.conf.all.disable_ipv6=1
```
### 永久禁用ipv6
```
sudo vim /etc/sysctl.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
sudo sysctl -p
```
### 修改Hostname
```
hostnamectl set-hostname name
```
### 时区改为上海
```
rm /etc/localtime && ln -s /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
```
### 更改用户名颜色
```
{ cat <<'EOF'
if [ "$EUID" -eq 0 ]; then
    PS1="\[\033]2;\h:\u\w\007\033[33;1m\]\u\[\033[0m\]\[\033[36;1m\]@\h\[\033[0m\]\[\033[35;1m\] \w\[\033[0m\]\[\033[32;1m\] # \[\033[0m\]"
else
    PS1="\[\033]2;\h:\u\w\007\033[33;1m\]\u\[\033[0m\]\[\033[36;1m\]@\h\[\033[0m\]\[\033[35;1m\] \w\[\033[0m\]\[\033[32;1m\] \$ \[\033[0m\]"
fi
EOF
} >> ~/.bashrc && source ~/.bashrc
```
