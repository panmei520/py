#!/bin/bash

# 确保脚本以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
   echo "请使用 root 或 sudo 权限运行此脚本。" >&2
   exit 1
fi

# --- 配置项 ---
# 提示用户输入必要信息
read -p "请输入你的域名 (例如: example.com): " domain_name
if [ -z "$domain_name" ]; then
    echo "域名不能为空。"
    exit 1
fi

read -p "请输入用于 Let's Encrypt 证书的邮箱地址: " email_address
if [ -z "$email_address" ]; then
    echo "邮箱地址不能为空。"
    exit 1
fi

# 自动生成数据库信息
db_name="wp_${domain_name//./_}" # 将域名中的点替换为下划线作为数据库名
db_user="wp_user_${domain_name//./_}"
db_password=$(openssl rand -base64 16) # 生成随机密码
web_root="/var/www/${domain_name}"

# --- 开始执行 ---

echo "------ 开始部署 WordPress 网站: ${domain_name} (禁止搜索引擎索引模式) ------"

# 1. 更新系统并安装必要软件包
echo ">>> 1/8: 更新系统并安装 Nginx, MariaDB, PHP, Certbot..."
apt update
apt upgrade -y
# 安装 Nginx, MariaDB, PHP (包括常用扩展), Certbot 及其 Nginx 插件
# 注意：PHP 版本可能需要根据 Ubuntu 版本调整 (如 php8.1-fpm, php7.4-fpm)
apt install -y nginx mariadb-server php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-xmlrpc php-soap php-intl php-zip wget unzip python3-certbot-nginx expect
echo "软件包安装完成。"

# 2. 配置数据库
echo ">>> 2/8: 配置 MariaDB 数据库..."
# 创建数据库和用户，授予权限（使用 expect 自动处理 MySQL/MariaDB 密码提示）
# 注意：在非交互式脚本中直接使用 root 访问数据库通常不需密码（如果是新装的MariaDB）
# 如果你的 MariaDB root 用户已设置密码且阻止了 socket 认证，这里可能需要调整
mysql -u root <<MYSQL_SCRIPT
CREATE DATABASE ${db_name} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
EXIT
MYSQL_SCRIPT
if [ $? -ne 0 ]; then
    echo "数据库配置失败。请检查 MariaDB 服务状态以及 root 用户访问权限。"
    exit 1
fi
# 提示：为了安全，建议脚本执行完毕后手动运行 'sudo mysql_secure_installation'
echo "数据库 '${db_name}' 和用户 '${db_user}' 创建完成。"
echo "数据库密码 (请妥善保管): ${db_password}"

# 3. 配置 Nginx
echo ">>> 3/8: 配置 Nginx..."
# 创建网站根目录
mkdir -p ${web_root}
chown www-data:www-data ${web_root}

# 创建 Nginx 配置文件
nginx_config="/etc/nginx/sites-available/${domain_name}"
cat > ${nginx_config} <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${domain_name} www.${domain_name};
    root ${web_root};

    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    # 增加 robots.txt 的直接处理，确保它总是可访问（即使PHP出问题）
    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        # 根据你的 PHP-FPM 版本修改 socket 路径
        # 例如：fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
        fastcgi_pass unix:/run/php/php-fpm.sock; # Ubuntu 20.04/22.04 默认路径
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    # 可选：增加一些安全和性能相关的 Header
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    # add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always; # CSP 策略需要根据实际情况调整

    # 访问和错误日志
    access_log /var/log/nginx/${domain_name}.access.log;
    error_log /var/log/nginx/${domain_name}.error.log;
}
EOF

# 启用站点配置
ln -sf ${nginx_config} /etc/nginx/sites-enabled/ # 使用 -f 强制覆盖可能存在的同名链接
# 删除默认配置冲突（如果存在且不是指向我们刚创建的配置）
if [ -L /etc/nginx/sites-enabled/default ] && [ "$(readlink -f /etc/nginx/sites-enabled/default)" != "${nginx_config}" ]; then
    rm -f /etc/nginx/sites-enabled/default
fi

# 测试 Nginx 配置并重新加载
nginx -t
if [ $? -ne 0 ]; then
    echo "Nginx 配置错误，请检查 ${nginx_config}"
    exit 1
fi
systemctl reload nginx
echo "Nginx 配置完成。"

# 4. 下载并安装 WordPress
echo ">>> 4/8: 下载并安装 WordPress..."
cd /tmp
wget https://wordpress.org/latest.tar.gz
if [ $? -ne 0 ]; then
    echo "下载 WordPress 失败。"
    exit 1
fi
tar -xzvf latest.tar.gz
# 将解压后的 wordpress 目录内容移动到 web_root，而不是 wordpress 目录本身
mv wordpress/* ${web_root}/
rm latest.tar.gz
rm -rf wordpress
echo "WordPress 文件下载解压完成。"

# 5. 配置 WordPress
echo ">>> 5/8: 配置 WordPress (wp-config.php)..."
# 从示例文件创建配置文件
if [ -f "${web_root}/wp-config-sample.php" ]; then
    cp ${web_root}/wp-config-sample.php ${web_root}/wp-config.php
else
    echo "错误：找不到 ${web_root}/wp-config-sample.php 文件。WordPress 文件可能未正确解压或放置。"
    exit 1
fi

# 替换数据库信息
sed -i "s/database_name_here/${db_name}/" ${web_root}/wp-config.php
sed -i "s/username_here/${db_user}/" ${web_root}/wp-config.php
sed -i "s/password_here/${db_password}/" ${web_root}/wp-config.php
sed -i "s/localhost/localhost/" ${web_root}/wp-config.php # 确认数据库主机

# 获取并替换安全密钥
SALT=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
if [ -z "$SALT" ]; then
    echo "警告：无法从 api.wordpress.org 获取安全密钥。请稍后手动更新 wp-config.php 中的密钥。"
else
    STRING='put your unique phrase here'
    printf '%s\n' "g/${STRING}/d" a "$SALT" . w | ed -s ${web_root}/wp-config.php
fi

# 设置文件权限 (先设置一遍，后面 robots.txt 和 wp-config.php 单独设置)
chown -R www-data:www-data ${web_root}
find ${web_root} -type d -exec chmod 755 {} \;
find ${web_root} -type f -exec chmod 644 {} \;
# 特别设置 wp-config.php 权限，建议更严格些（例如 600），但要确保 Nginx/PHP 能读取
chmod 640 ${web_root}/wp-config.php

echo "WordPress 配置完成。"

# 6. 使用 Certbot 申请 SSL 证书并配置 HTTPS
echo ">>> 6/8: 申请 Let's Encrypt SSL 证书并配置 HTTPS..."
# --nginx: 使用 Nginx 插件
# --agree-tos: 自动同意服务条款
# --redirect: 自动将 HTTP 重定向到 HTTPS
# --hsts: 添加 HSTS 头 (可选，增强安全)
# --staple-ocsp: 启用 OCSP Stapling (可选，提升性能)
# -d: 指定域名，可以多次使用以包含 www 子域
# --email: 注册邮箱
# --non-interactive: 尝试非交互式运行 (结合 --agree-tos 和 --email)
# --no-eff-email: 可选，不订阅 EFF 邮件列表
certbot --nginx --agree-tos --redirect --hsts --staple-ocsp -d ${domain_name} -d www.${domain_name} --email ${email_address} --non-interactive --no-eff-email

if [ $? -ne 0 ]; then
    echo "Certbot 证书申请失败。请检查："
    echo "1. 域名 ${domain_name} 和 www.${domain_name} 是否已正确解析到本服务器 IP。"
    echo "2. 防火墙是否允许 80 端口访问 (用于 Let's Encrypt 的 HTTP-01 验证)。"
    echo "3. Nginx 是否正常运行且配置正确（尝试访问 http://${domain_name} 看是否通）。"
    # 提示用户可以尝试手动运行 certbot 命令进行调试
    echo "你可以尝试手动运行获取更多信息: sudo certbot --nginx -d ${domain_name} -d www.${domain_name} --email ${email_address}"
    # 脚本继续执行，但会提示 HTTPS 可能无法工作
    https_status="失败"
else
    echo "SSL 证书申请和 HTTPS 配置成功。"
    # Certbot 包通常会自动设置 systemd timer 或 cron job 来处理续期
    echo "Certbot 已设置自动续期任务。"
    https_status="成功"
fi

# 7. 创建 robots.txt 文件以阻止爬虫 (新步骤)
echo ">>> 7/8: 创建 robots.txt 文件以阻止搜索引擎爬虫..."
cat > ${web_root}/robots.txt <<EOF
User-agent: *
Disallow: /
EOF
# 设置 robots.txt 的权限
chown www-data:www-data ${web_root}/robots.txt
chmod 644 ${web_root}/robots.txt
echo "robots.txt 创建完成，已禁止所有爬虫抓取全站内容。"

# 8. 完成
echo ">>> 8/8: 清理临时文件..."
# 清理工作已在下载步骤后完成

echo "------ WordPress 网站部署完成! ------"
if [ "$https_status" == "成功" ]; then
    echo "你的网站地址: https://${domain_name}"
    access_url="https://${domain_name}"
else
    echo "你的网站地址 (HTTPS 可能无效，请检查证书步骤): http://${domain_name}"
    access_url="http://${domain_name}"
fi
echo "数据库名: ${db_name}"
echo "数据库用户名: ${db_user}"
echo "数据库密码: ${db_password} (请务必保存好!)"
echo "网站根目录: ${web_root}"
echo ""
echo "--- 重要：阻止搜索引擎索引设置 ---"
echo "1. 本脚本已在网站根目录创建了 'robots.txt' 文件，尝试阻止搜索引擎爬虫。"
echo "2. 为了更有效地阻止索引，请在首次登录 WordPress 后台后，执行以下操作："
echo "   - 进入 '设置 (Settings)' -> '阅读 (Reading)'"
echo "   - 找到 '对搜索引擎的可见性 (Search engine visibility)'"
echo "   - 勾选 '建议搜索引擎不索引本站点 (Discourage search engines from indexing this site)'"
echo "   - 点击 '保存更改 (Save Changes)'"
echo "   这将添加 'noindex, nofollow' meta 标签到你的网站页面，是更强的阻止信号。"
echo "----------------------------------------"
echo "安全提示: 建议立即运行 'sudo mysql_secure_installation' 来加固数据库安全设置 (设置 root 密码等)。"
echo "请在浏览器中访问 ${access_url} 完成 WordPress 的初始设置 (站点标题、管理员用户名和密码等)。"

exit 0