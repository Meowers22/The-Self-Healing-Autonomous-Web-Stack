#!/bin/bash
set -euxo pipefail

dnf update -y
dnf install -y httpd

systemctl enable httpd
systemctl start httpd

cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>Self-Healing Autonomous Web Stack</title>
  </head>
  <body>
    <h1>Self-Healing Stack Running</h1>
    <p>ALB + ASG + Event-Driven Auto-Remediation Active</p>
  </body>
</html>
EOF
