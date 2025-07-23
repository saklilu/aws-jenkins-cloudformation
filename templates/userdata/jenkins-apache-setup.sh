#!/bin/bash

set -e

LOG_FILE="/var/log/user-data.log"
exec > >(tee -a $LOG_FILE) 2>&1

echo "=== Starting user data script at $(date) ==="

# Get parameters from CloudFormation
PROJECT_NAME="${PROJECT_NAME}"
ENVIRONMENT="${ENVIRONMENT}"
INSTANCE_TYPE="${INSTANCE_TYPE}"

apt-get update -y
apt-get upgrade -y

echo "=== Installing Apache2 ==="
apt-get install -y apache2
systemctl start apache2
systemctl enable apache2

echo "=== Creating custom Apache index page ==="
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Jenkins & Apache Server - CloudFormation</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f4f4f4; }
        .container { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .header { color: #2c3e50; border-bottom: 3px solid #e67e22; padding-bottom: 10px; margin-bottom: 20px; }
        .service { background: #ecf0f1; padding: 15px; margin: 10px 0; border-radius: 5px; border-left: 4px solid #e67e22; }
        .service h3 { color: #2c3e50; margin-top: 0; }
        .status { color: #27ae60; font-weight: bold; }
        a { color: #e67e22; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .cfn-badge { background: #e67e22; color: white; padding: 4px 8px; border-radius: 4px; font-size: 0.8em; }
    </style>
</head>
<body>
    <div class="container">
        <h1 class="header">🚀 Jenkins & Apache Server <span class="cfn-badge">CloudFormation</span></h1>
        <p>Welcome to your Jenkins and Apache2 server deployed with AWS CloudFormation!</p>
        
        <div class="service">
            <h3>🌐 Apache Web Server</h3>
            <p class="status">Status: Running</p>
            <p>This page is served by Apache2 running on Ubuntu 22.04</p>
        </div>
        
        <div class="service">
            <h3>🔧 Jenkins CI/CD</h3>
            <p>Access Jenkins at: <a href="/jenkins" target="_blank">Jenkins Dashboard</a></p>
            <p>Direct access: <a href=":8080" target="_blank">Port 8080</a></p>
        </div>
        
        <div class="service">
            <h3>📊 Server Information</h3>
            <p>Project: $PROJECT_NAME</p>
            <p>Environment: $ENVIRONMENT</p>
            <p>Instance Type: $INSTANCE_TYPE</p>
            <p>Deployed via: AWS CloudFormation</p>
            <p>Deployed: $(date)</p>
        </div>
        
        <div class="service">
            <h3>☁️ AWS CloudFormation Features</h3>
            <p>• Infrastructure as Code</p>
            <p>• Stack-based deployment</p>
            <p>• Nested templates for modularity</p>
            <p>• Built-in rollback capabilities</p>
        </div>
        
        <div class="service">
            <h3>🔗 Useful Links</h3>
            <p><a href="/server-status" target="_blank">Apache Server Status</a></p>
            <p><a href="/jenkins" target="_blank">Jenkins Dashboard</a></p>
        </div>
    </div>
</body>
</html>
EOF

echo "=== Installing Java (OpenJDK 11) ==="
apt-get install -y openjdk-11-jdk

echo "=== Installing Jenkins ==="
wget -q -O - https://pkg.jenkins.io/debian-stable/jenkins.io.key | apt-key add -
sh -c 'echo deb https://pkg.jenkins.io/debian-stable binary/ > /etc/apt/sources.list.d/jenkins.list'
apt-get update -y
apt-get install -y jenkins

systemctl start jenkins
systemctl enable jenkins

echo "=== Configuring Apache proxy for Jenkins ==="
a2enmod proxy
a2enmod proxy_http
a2enmod headers

cat > /etc/apache2/sites-available/jenkins.conf << 'EOF'
<VirtualHost *:80>
    ProxyPreserveHost On
    ProxyRequests Off
    ProxyPass /jenkins http://localhost:8080/jenkins
    ProxyPassReverse /jenkins http://localhost:8080/jenkins
    ProxyPassReverse /jenkins http://127.0.0.1/jenkins
    
    <Location "/jenkins">
        ProxyPassReverse /
        ProxyPassReverseRewrite /
        Order allow,deny
        Allow from all
    </Location>
</VirtualHost>
EOF

a2ensite jenkins
systemctl reload apache2

echo "=== Configuring Jenkins for reverse proxy ==="
mkdir -p /var/lib/jenkins/init.groovy.d
cat > /var/lib/jenkins/init.groovy.d/set-jenkins-url.groovy << 'EOF'
import jenkins.model.JenkinsLocationConfiguration

def jenkinsLocationConfiguration = JenkinsLocationConfiguration.get()
jenkinsLocationConfiguration.setUrl("http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)/jenkins")
jenkinsLocationConfiguration.save()
EOF

echo "=== Installing additional tools ==="
apt-get install -y git curl wget unzip awscli jq

echo "=== Installing Docker ==="
apt-get install -y apt-transport-https ca-certificates gnupg lsb-release
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl start docker
systemctl enable docker

usermod -aG docker jenkins
usermod -aG docker ubuntu

echo "=== Installing Terraform ==="
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | tee /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
apt-get update -y
apt-get install -y terraform

echo "=== Installing Node.js and npm ==="
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs

echo "=== Setting up CloudWatch Agent ==="
wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i -E ./amazon-cloudwatch-agent.deb
rm amazon-cloudwatch-agent.deb

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << EOF
{
    "metrics": {
        "namespace": "$PROJECT_NAME-$ENVIRONMENT",
        "metrics_collected": {
            "cpu": {
                "measurement": [
                    "cpu_usage_idle",
                    "cpu_usage_iowait",
                    "cpu_usage_user",
                    "cpu_usage_system"
                ],
                "metrics_collection_interval": 60
            },
            "disk": {
                "measurement": [
                    "used_percent"
                ],
                "metrics_collection_interval": 60,
                "resources": [
                    "*"
                ]
            },
            "diskio": {
                "measurement": [
                    "io_time"
                ],
                "metrics_collection_interval": 60,
                "resources": [
                    "*"
                ]
            },
            "mem": {
                "measurement": [
                    "mem_used_percent"
                ],
                "metrics_collection_interval": 60
            }
        }
    },
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "/var/log/jenkins/jenkins.log",
                        "log_group_name": "$PROJECT_NAME-$ENVIRONMENT-jenkins",
                        "log_stream_name": "jenkins"
                    },
                    {
                        "file_path": "/var/log/apache2/access.log",
                        "log_group_name": "$PROJECT_NAME-$ENVIRONMENT-apache",
                        "log_stream_name": "access"
                    },
                    {
                        "file_path": "/var/log/apache2/error.log",
                        "log_group_name": "$PROJECT_NAME-$ENVIRONMENT-apache",
                        "log_stream_name": "error"
                    }
                ]
            }
        }
    }
}
EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

echo "=== Setting up Jenkins initial configuration ==="
sleep 30

cat > /var/lib/jenkins/init.groovy.d/basic-security.groovy << 'EOF'
import jenkins.model.*
import hudson.security.*
import jenkins.install.InstallState

def instance = Jenkins.getInstance()

def hudsonRealm = new HudsonPrivateSecurityRealm(false)
hudsonRealm.createAccount("admin", "admin123!")
instance.setSecurityRealm(hudsonRealm)

def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)

if (!instance.getInstallState().isSetupComplete()) {
    instance.setInstallState(InstallState.INITIAL_SETUP_COMPLETED)
}

instance.save()
EOF

echo "=== Installing Jenkins plugins ==="
cat > /var/lib/jenkins/plugins.txt << 'EOF'
git
github
build-timeout
credentials-binding
timestamper
ws-cleanup
ant
gradle
workflow-aggregator
pipeline-stage-view
docker-workflow
blueocean
terraform
aws-credentials
job-dsl
pipeline-utility-steps
htmlpublisher
EOF

# Wait for Jenkins to be fully ready
sleep 60
systemctl restart jenkins
sleep 30

echo "=== Creating status check script ==="
cat > /usr/local/bin/service-status.sh << 'EOF'
#!/bin/bash
echo "=== Service Status Check ==="
echo "Apache2: $(systemctl is-active apache2)"
echo "Jenkins: $(systemctl is-active jenkins)"
echo "Docker: $(systemctl is-active docker)"
echo "CloudWatch Agent: $(systemctl is-active amazon-cloudwatch-agent)"
echo "=== Port Status ==="
netstat -tlnp | grep -E ':80|:8080|:22'
EOF
chmod +x /usr/local/bin/service-status.sh

echo "=== Creating motd with service information ==="
cat > /etc/motd << EOF

🚀 Jenkins & Apache Server (CloudFormation)
==========================================
Project: $PROJECT_NAME
Environment: $ENVIRONMENT

Services Status:
- Apache2: Running on port 80
- Jenkins: Running on port 8080 (/jenkins)
- Docker: Available for CI/CD pipelines

Quick Commands:
- sudo service-status.sh  # Check all services
- sudo systemctl status jenkins apache2
- tail -f /var/log/user-data.log  # View setup logs

Access URLs:
- Web: http://[PUBLIC_IP]
- Jenkins: http://[PUBLIC_IP]:8080 or http://[PUBLIC_IP]/jenkins

Deployed via AWS CloudFormation

EOF

echo "=== Installing AWS CLI v2 ==="
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf awscliv2.zip aws

echo "=== CloudFormation signal success ==="
/opt/aws/bin/cfn-signal -e $? --stack ${AWS::StackName} --resource EC2Instance --region ${AWS::Region}

echo "=== User data script completed successfully at $(date) ==="