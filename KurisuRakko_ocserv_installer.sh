#!/bin/bash
set -e

#==== 变量 ====
CONFIG_PATH="./ocserv.conf"
CERT_PATH="/opt/fullchain.pem"
KEY_PATH="/opt/privkey.pem"
PASSWD_FILE="/etc/ocserv/ocpasswd"
IFACE="$(ip -4 route ls | grep default | awk '{print $5}' | head -n1)"  # 自动抓网卡
VPN_NET="$(grep -m1 '^ipv4-network' "$CONFIG_PATH" 2>/dev/null | awk '{print $3}')"
VPN_NET="${VPN_NET:-192.168.128.0}"   # 兜底

#==== 彩色输出 ====
cEcho(){ echo -e "\033[1;32m$*\033[0m"; }
cWarn(){ echo -e "\033[1;33m$*\033[0m"; }
cErr (){ echo -e "\033[1;31m$*\033[0m"; }

pause(){ read -n1 -s -r -p "按任意键返回主菜单..." ; echo; main_menu; }

#==== 主菜单 ====
main_menu(){
  clear
  cEcho "=========== KurisuRakko ocserv 安装器 ==========="
  echo " 1. 全自动安装 (依赖+ocserv+证书)"
  echo " 2. 仅配置证书"
  echo " 3. 仅配置 ocserv"
  echo " 4. 添加单个用户"
  echo " 5. 批量添加用户"
  echo " 0. 退出"
  echo "-----------------------------------------------"
  read -rp "请选择操作 [1-5/0]: " sel
  case $sel in
    1) auto_install   ;;
    2) only_cert      ;;
    3) only_ocserv    ;;
    4) add_one_user   ;;
    5) batch_users    ;;
    0) exit 0         ;;
    *) cErr "无效选项！" ; sleep 1 ; main_menu ;;
  esac
}

#==== 安装依赖（幂等）====
install_deps(){
  cEcho "安装必要软件..."
  apt update
  apt install -y ocserv certbot iptables-persistent
}

#==== 证书函数 ====
only_cert(){
  install_deps
  read -rp "请输入邮箱 (Let's Encrypt): " EMAIL
  read -rp "请输入域名 (已解析至本机): " DOMAIN
  systemctl stop ocserv || true

  # 放行 80 端口
  iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || \
      iptables -A INPUT -p tcp --dport 80 -j ACCEPT

  if [[ -n $DOMAIN ]]; then
    cEcho "签发 Let's Encrypt..."
    certbot certonly --standalone --agree-tos --email "$EMAIL" -d "$DOMAIN"
    ln -sf "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$CERT_PATH"
    ln -sf "/etc/letsencrypt/live/$DOMAIN/privkey.pem"  "$KEY_PATH"
  else
    cEcho "生成自签证书..."
    mkdir -p /opt
    certtool --generate-privkey --outfile "$KEY_PATH"
    certtool --generate-self-signed --load-privkey "$KEY_PATH" --outfile "$CERT_PATH" \
      --template <(cat <<-EOF
        cn = "VPN Server"
        organization = "KurisuRakko"
        serial = 1
        expiration_days = 3650
        signing_key
        encryption_key
        tls_www_server
EOF
)
  fi
  cEcho "证书就绪 -> $CERT_PATH"
  [[ $1 != "no_return" ]] && pause
}

#==== ocserv 函数 ====
only_ocserv(){
  install_deps
  [[ -f $CONFIG_PATH ]] || { cErr "缺少 $CONFIG_PATH，请上传！"; pause; }

  cp "$CONFIG_PATH" /etc/ocserv/ocserv.conf
  cEcho "配置文件已部署。"

  # IP 转发
  cEcho "开启 IP 转发..."
  sysctl -w net.ipv4.ip_forward=1
  grep -q net.ipv4.ip_forward /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

  # 防火墙
  cEcho "设置 iptables..."
  iptables -t nat -C POSTROUTING -s "$VPN_NET/24" -o "$IFACE" -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -s "$VPN_NET/24" -o "$IFACE" -j MASQUERADE

  for PORT in 443/tcp 443/udp; do
    proto=${PORT##*/}; port=${PORT%/*}
    iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT
  done

  iptables -C FORWARD -s "$VPN_NET/24" -j ACCEPT 2>/dev/null || \
      iptables -A FORWARD -s "$VPN_NET/24" -j ACCEPT
  iptables -C FORWARD -d "$VPN_NET/24" -j ACCEPT 2>/dev/null || \
      iptables -A FORWARD -d "$VPN_NET/24" -j ACCEPT
  netfilter-persistent save

  # 启动服务
  systemctl enable ocserv
  systemctl restart ocserv
  cEcho "ocserv 已启动并自启动。"
  [[ $1 != "no_return" ]] && pause
}

#==== 添加单个用户 ====
add_one_user(){
  [[ -f $PASSWD_FILE ]] || touch "$PASSWD_FILE"
  read -rp "输入用户名: " USER
  if [[ -z $USER ]]; then cWarn "用户名为空"; pause; fi
  FLAGS="-c" ; [[ -s $PASSWD_FILE ]] && FLAGS=""
  ocpasswd $FLAGS "$PASSWD_FILE" "$USER"
  cEcho "用户 $USER 添加完成！"
  pause
}

#==== 批量用户 ====
batch_users(){
  [[ -f $PASSWD_FILE ]] || touch "$PASSWD_FILE"
  read -rp "输入多个用户名 (空格分隔): " USERS
  [[ -z $USERS ]] && { cWarn "未输入"; pause; }
  for U in $USERS; do
    FLAGS="-c" ; [[ -s $PASSWD_FILE ]] && FLAGS=""
    cEcho "添加 $U ..."
    ocpasswd $FLAGS "$PASSWD_FILE" "$U"
  done
  cEcho "全部完成!"
  pause
}

#==== 全自动 ====
auto_install(){
  install_deps
  only_cert no_return
  only_ocserv no_return
  cEcho "🎉  全流程完毕！请用 AnyConnect 连接您的域名/IP。"
  pause
}

#==== 启动 ====
main_menu
