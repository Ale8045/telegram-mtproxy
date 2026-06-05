# MTProxy Enterprise Manager

专业级 Telegram MTProto 多节点管理脚本

支持：

- 多节点管理
- 多客户管理
- 节点备注
- 到期时间控制
- 流量限制
- 节点暂停/启用
- 批量创建节点
- 流量排行
- 客户搜索
- 一键导出所有代理链接
- Telegram 广告频道(TAG)
- BBR加速
- Docker自动部署

---

# 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Ale8045/telegram-mtproxy/main/mtproxy.sh)
```

安装完成后可直接使用：

```bash
mtp
```

打开管理面板。

---

# 创建代理流程

## 1. 创建节点

进入菜单：

```text
1. 创建节点
```

按照提示填写：

```text
客户名称
TG账号
节点备注
端口
到期时间
流量限制
```

创建完成后脚本会自动生成：

```text
服务器IP
端口
Secret
代理链接
```

---

## 2. 注册 Telegram 广告频道

打开：

https://t.me/MTProxybot

发送：

```text
/newproxy
```

机器人会要求输入：

```text
IP:端口
```

例如：

```text
47.237.139.28:15236
```

然后输入脚本生成的：

```text
Secret
```

机器人会返回：

```text
TAG
```

例如：

```text
63c6f914ba81d895d324a6c5e8dfc18f
```

---

## 3. 设置 TAG

返回脚本：

```text
22. 设置TAG
```

输入：

```text
节点ID
TAG
```

脚本会自动重建节点并应用广告频道。

用户重新连接代理即可看到频道广告。

---

# 快捷命令

安装完成后：

```bash
mtp
```

直接打开管理面板。

---

# 功能菜单

## 节点管理

```text
1. 创建节点
2. 批量创建
3. 节点列表
4. 节点详情
```

## 客户管理

```text
5. 修改客户信息
6. 修改到期时间
7. 修改流量限制
8. 节点续费
```

## 节点控制

```text
9. 启用节点
10. 停用节点
11. 重启节点
12. 删除节点
```

## 数据中心

```text
13. 搜索客户
14. 即将到期客户
15. 导出全部链接
16. 导出客户清单
17. 流量排行
```

## 系统工具

```text
18. 健康检查
19. Docker状态
20. 安装快捷命令
21. 卸载脚本
22. 设置TAG
```

---

# 到期控制

支持：

```text
按天数到期
自动暂停
手动续费
```

例如：

```text
30天
90天
180天
365天
```

到期后自动暂停节点。

---

# 流量限制

支持：

```text
10GB
50GB
100GB
500GB
```

达到限制后自动暂停节点。

管理员可随时：

```text
修改流量
续费
恢复节点
```

---

# 导出代理链接

菜单：

```text
15. 导出全部链接
```

导出：

```text
tg://proxy
https://t.me/proxy
```

格式链接。

---

# 卸载脚本

菜单：

```text
21. 卸载脚本
```

输入：

```text
DELETE
```

即可删除：

- 所有节点
- 所有配置
- 所有导出文件
- 所有定时任务
- mtp快捷命令

---

# 项目地址

https://github.com/Ale8045/telegram-mtproxy

---

MTProxy Enterprise Manager
