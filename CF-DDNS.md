[项目地址](https://github.com/yulewang/cloudflare-api-v4-ddns)

[获取Cloudflare的Global API Key](https://dash.cloudflare.com/profile/api-tokens)

### Cloudflare的域名解析管理界面，添加A记录，解析到任意IP都行，如1.1.1.1

### 执行命令下载DDNS脚本
```
wget -N --no-check-certificate https://raw.githubusercontent.com/yulewang/cloudflare-api-v4-ddns/master/cf-v4-ddns.sh
```

### 编辑脚本文件 ```nano cf-v4-ddns.sh```
```
CFKEY=这里填写Global API Key

# Username, eg: user@example.com
CFUSER=这里填写Cloudflare的登陆邮箱

# Zone name, eg: example.com
CFZONE_NAME=这里填写主域名

# Hostname to update, eg: homeserver.example.com
CFRECORD_NAME=这里填写需要DDNS解析的二级域名
```

### 赋予脚本执行权限，然后执行脚本，成功后cf界面会变为获取的ip
```
chmod +x cf-v4-ddns.sh
```
```
./cf-v4-ddns.sh
```
### 添加定时任务计划，执行```crontab -e```命令，将下方代码(2选1)复制进去，然后保存就可以了
定时执行脚本
```
*/2 * * * * /root/cf-v4-ddns.sh >/dev/null 2>&1
```
定时执行脚本并输出日志
```
*/2 * * * * /root/cf-v4-ddns.sh >> /var/log/cf-ddns.log 2>&1
```
