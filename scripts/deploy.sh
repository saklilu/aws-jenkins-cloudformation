#!/bin/bash

set -e

PROJECT_NAME="jenkins-apache"
ENVIRONMENT="dev"
AWS_REGION="us-east-1"
STACK_NAME="${PROJECT_NAME}-${ENVIRONMENT}-main"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_banner() {
    echo -e "${BLUE}"
    echo "========================================================"
    echo "🚀 AWS CloudFormation Jenkins & Apache Deployment"
    echo "========================================================"
    echo -e "${NC}"
}

check_prerequisites() {
    log "Checking prerequisites..."
    
    command -v aws >/dev/null 2>&1 || error "AWS CLI is not installed"
    command -v jq >/dev/null 2>&1 || error "jq is not installed (required for JSON parsing)"
    
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        error "AWS credentials are not configured"
    fi
    
    success "Prerequisites check passed"
}

get_parameters() {
    log "Gathering deployment parameters..."
    
    # Check if parameters file exists
    if [ ! -f "parameters.json" ]; then
        warn "parameters.json not found. Creating from template..."
        cat > parameters.json << 'EOF'
{
  "ProjectName": "jenkins-apache",
  "Environment": "dev",
  "InstanceType": "t3.medium",
  "KeyPairName": "your-key-pair-name",
  "VpcCidr": "10.0.0.0/16",
  "PublicSubnet1Cidr": "10.0.1.0/24",
  "PublicSubnet2Cidr": "10.0.2.0/24",
  "PrivateSubnet1Cidr": "10.0.10.0/24",
  "PrivateSubnet2Cidr": "10.0.20.0/24"
}
EOF
        error "Please update parameters.json with your specific values before running deployment"
    fi
    
    # Extract key pair name from parameters
    local key_name=$(jq -r '.KeyPairName' parameters.json)
    
    if [ "$key_name" = "your-key-pair-name" ] || [ -z "$key_name" ]; then
        error "Please update KeyPairName in parameters.json"
    fi
    
    # Validate key pair exists
    if ! aws ec2 describe-key-pairs --key-names "$key_name" --region "$AWS_REGION" >/dev/null 2>&1; then
        error "Key pair '$key_name' does not exist in region $AWS_REGION"
    fi
    
    success "Parameters validated"
}

upload_templates() {
    log "Uploading CloudFormation templates..."
    
    # Create temporary S3 bucket for templates if it doesn't exist
    local bucket_name="${PROJECT_NAME}-${ENVIRONMENT}-cfn-templates-$(aws sts get-caller-identity --query Account --output text)-${AWS_REGION}"
    
    if ! aws s3 ls "s3://$bucket_name" >/dev/null 2>&1; then
        log "Creating S3 bucket for templates: $bucket_name"
        if [ "$AWS_REGION" = "us-east-1" ]; then
            aws s3 mb "s3://$bucket_name" --region "$AWS_REGION"
        else
            aws s3 mb "s3://$bucket_name" --region "$AWS_REGION" --create-bucket-configuration LocationConstraint="$AWS_REGION"
        fi
        
        # Enable versioning
        aws s3api put-bucket-versioning --bucket "$bucket_name" --versioning-configuration Status=Enabled
        
        # Block public access
        aws s3api put-public-access-block --bucket "$bucket_name" --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    fi
    
    # Upload all templates
    log "Uploading nested templates..."
    aws s3 sync templates/ "s3://$bucket_name/templates/" --delete
    
    success "Templates uploaded to S3"
    echo "TEMPLATES_BUCKET=$bucket_name" > .env
}

convert_parameters() {
    log "Converting parameters for CloudFormation..."
    
    # Convert JSON parameters to CloudFormation parameter format
    local cf_params=""
    while IFS="=" read -r key value; do
        if [ ! -z "$key" ] && [ ! -z "$value" ]; then
            cf_params="$cf_params ParameterKey=$key,ParameterValue=$value"
        fi
    done < <(jq -r 'to_entries | .[] | "\(.key)=\(.value)"' parameters.json)
    
    echo "$cf_params" > .cf-parameters
}

validate_template() {
    log "Validating CloudFormation template..."
    
    aws cloudformation validate-template \
        --template-body file://templates/main-stack.yaml \
        --region "$AWS_REGION" >/dev/null 2>&1
    
    success "Template validation passed"
}

check_stack_exists() {
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" >/dev/null 2>&1
}

deploy_stack() {
    local action=""
    local cf_params=$(cat .cf-parameters)
    
    if check_stack_exists; then
        action="update-stack"
        log "Updating existing stack: $STACK_NAME"
    else
        action="create-stack"
        log "Creating new stack: $STACK_NAME"
    fi
    
    log "Deploying CloudFormation stack..."
    local stack_id=$(aws cloudformation $action \
        --stack-name "$STACK_NAME" \
        --template-body file://templates/main-stack.yaml \
        --parameters $cf_params \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$AWS_REGION" \
        --tags Key=Project,Value="$PROJECT_NAME" Key=Environment,Value="$ENVIRONMENT" Key=ManagedBy,Value=CloudFormation \
        --query 'StackId' --output text)
    
    log "Stack deployment initiated. Stack ID: $stack_id"
    
    # Wait for stack deployment to complete
    log "Waiting for stack deployment to complete (this may take 10-15 minutes)..."
    aws cloudformation wait stack-${action%%-*}-complete \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION"
    
    local status=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" \
        --query 'Stacks[0].StackStatus' --output text)
    
    if [[ "$status" == *"COMPLETE"* ]]; then
        success "Stack deployment completed successfully!"
    else
        error "Stack deployment failed with status: $status"
    fi
}

show_outputs() {
    log "Retrieving stack outputs..."
    
    local outputs=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" \
        --query 'Stacks[0].Outputs')
    
    if [ "$outputs" != "null" ]; then
        echo
        log "🎯 Deployment Outputs:"
        echo "$outputs" | jq -r '.[] | "  \(.OutputKey): \(.OutputValue)"'
        
        # Save outputs to file
        echo "$outputs" > stack-outputs.json
        success "Outputs saved to stack-outputs.json"
    else
        warn "No stack outputs available"
    fi
}

wait_for_services() {
    local public_ip=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`PublicIP`].OutputValue' \
        --output text)
    
    if [ -z "$public_ip" ] || [ "$public_ip" = "None" ]; then
        warn "Could not retrieve public IP. Skipping service checks."
        return
    fi
    
    log "Waiting for services to be ready on $public_ip..."
    log "This may take 5-10 minutes for initial setup to complete..."
    
    # Check Apache
    log "Checking Apache..."
    local apache_ready=false
    for i in {1..30}; do
        if curl -s -o /dev/null -w "%{http_code}" "http://$public_ip" | grep -q "200"; then
            apache_ready=true
            break
        fi
        echo -n "."
        sleep 10
    done
    
    if [ "$apache_ready" = true ]; then
        success "Apache is ready! ✅"
    else
        warn "Apache may still be starting up. Check http://$public_ip manually."
    fi
    
    # Check Jenkins
    log "Checking Jenkins..."
    local jenkins_ready=false
    for i in {1..60}; do
        if curl -s -o /dev/null -w "%{http_code}" "http://$public_ip:8080" | grep -q "200\|403"; then
            jenkins_ready=true
            break
        fi
        echo -n "."
        sleep 10
    done
    
    if [ "$jenkins_ready" = true ]; then
        success "Jenkins is ready! ✅"
    else
        warn "Jenkins may still be starting up. Check http://$public_ip:8080 manually."
    fi
}

show_next_steps() {
    local public_ip=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`PublicIP`].OutputValue' \
        --output text)
    
    local jenkins_url=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`JenkinsURL`].OutputValue' \
        --output text)
    
    local apache_url=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`ApacheURL`].OutputValue' \
        --output text)
    
    local ssh_command=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`SSHCommand`].OutputValue' \
        --output text)
    
    echo
    log "🎉 Next Steps:"
    echo
    echo "1. 🌐 Access your services:"
    echo "   - Apache: $apache_url"
    echo "   - Jenkins: $jenkins_url"
    echo
    echo "2. 🔑 SSH into your instance:"
    echo "   $ssh_command"
    echo
    echo "3. 📊 Check service status:"
    echo "   sudo service-status.sh"
    echo
    echo "4. 📋 View logs:"
    echo "   tail -f /var/log/user-data.log"
    echo "   journalctl -u jenkins -f"
    echo "   journalctl -u apache2 -f"
    echo
    echo "5. 🔧 Jenkins Configuration:"
    echo "   - Default admin user: admin / admin123!"
    echo "   - Initial admin password: /var/lib/jenkins/secrets/initialAdminPassword"
    echo "   - Set up GitHub webhooks"
    echo "   - Install additional plugins"
    echo "   - Create CI/CD pipelines"
    echo
    echo "6. 📈 CloudWatch Monitoring:"
    echo "   - Dashboard: AWS Console > CloudWatch > Dashboards"
    echo "   - Logs: AWS Console > CloudWatch > Log groups"
    echo "   - Alarms: AWS Console > CloudWatch > Alarms"
    echo
}

cleanup_temp_files() {
    rm -f .cf-parameters 2>/dev/null || true
}

main() {
    print_banner
    
    log "Starting CloudFormation deployment of Jenkins and Apache infrastructure"
    
    check_prerequisites
    get_parameters
    upload_templates
    convert_parameters
    validate_template
    
    echo
    warn "This will create AWS resources that may incur charges."
    read -p "Do you want to continue with the deployment? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Deployment cancelled by user"
        cleanup_temp_files
        exit 0
    fi
    
    deploy_stack
    show_outputs
    wait_for_services
    show_next_steps
    cleanup_temp_files
    
    echo
    success "🎉 CloudFormation deployment completed successfully!"
    log "Stack Name: $STACK_NAME"
    log "Region: $AWS_REGION"
}

# Handle script interruption
trap cleanup_temp_files EXIT

if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi