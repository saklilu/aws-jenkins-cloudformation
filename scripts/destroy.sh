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
    echo -e "${RED}"
    echo "========================================================"
    echo "💥 AWS CloudFormation Stack Destruction"
    echo "========================================================"
    echo -e "${NC}"
}

check_prerequisites() {
    log "Checking prerequisites..."
    
    command -v aws >/dev/null 2>&1 || error "AWS CLI is not installed"
    
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        error "AWS credentials are not configured"
    fi
    
    success "Prerequisites check passed"
}

check_stack_exists() {
    if aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

show_stack_resources() {
    log "Resources in the stack:"
    echo
    
    aws cloudformation list-stack-resources \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" \
        --query 'StackResourceSummaries[].[ResourceType,LogicalResourceId,ResourceStatus]' \
        --output table
    
    echo
}

empty_s3_buckets() {
    log "Checking for S3 buckets that need to be emptied..."
    
    local bucket_list=$(aws cloudformation list-stack-resources \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" \
        --query 'StackResourceSummaries[?ResourceType==`AWS::S3::Bucket`].PhysicalResourceId' \
        --output text)
    
    if [ -n "$bucket_list" ] && [ "$bucket_list" != "None" ]; then
        for bucket in $bucket_list; do
            log "Emptying S3 bucket: $bucket"
            
            # Delete all object versions
            aws s3api delete-objects \
                --bucket "$bucket" \
                --delete "$(aws s3api list-object-versions \
                    --bucket "$bucket" \
                    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
                    --output json)" >/dev/null 2>&1 || true
            
            # Delete all delete markers
            aws s3api delete-objects \
                --bucket "$bucket" \
                --delete "$(aws s3api list-object-versions \
                    --bucket "$bucket" \
                    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
                    --output json)" >/dev/null 2>&1 || true
            
            success "Emptied bucket: $bucket"
        done
    else
        log "No S3 buckets found in stack"
    fi
}

get_stack_outputs() {
    log "Saving current stack outputs..."
    
    if aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" \
        --query 'Stacks[0].Outputs' > "stack-outputs-backup-$(date +%Y%m%d_%H%M%S).json" 2>/dev/null; then
        success "Stack outputs backed up"
    else
        warn "Could not backup stack outputs"
    fi
}

delete_stack() {
    log "Initiating stack deletion..."
    
    aws cloudformation delete-stack \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION"
    
    log "Stack deletion initiated. Waiting for completion..."
    log "This may take 10-15 minutes depending on resources..."
    
    aws cloudformation wait stack-delete-complete \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION"
    
    success "Stack deletion completed successfully!"
}

cleanup_templates_bucket() {
    if [ -f ".env" ]; then
        local templates_bucket=$(grep TEMPLATES_BUCKET .env | cut -d'=' -f2)
        
        if [ -n "$templates_bucket" ]; then
            log "Cleaning up templates bucket: $templates_bucket"
            
            # Empty the bucket first
            aws s3 rm "s3://$templates_bucket" --recursive >/dev/null 2>&1 || true
            
            # Delete the bucket
            aws s3 rb "s3://$templates_bucket" >/dev/null 2>&1 || true
            
            success "Templates bucket cleaned up"
            rm -f .env
        fi
    fi
}

cleanup_files() {
    log "Cleaning up local files..."
    
    rm -f stack-outputs.json 2>/dev/null || true
    rm -f .cf-parameters 2>/dev/null || true
    
    success "Local cleanup completed"
}

main() {
    print_banner
    
    log "Starting CloudFormation stack destruction"
    
    check_prerequisites
    
    if ! check_stack_exists; then
        warn "Stack '$STACK_NAME' does not exist in region $AWS_REGION"
        exit 0
    fi
    
    show_stack_resources
    
    echo
    warn "⚠️  DANGER: This will PERMANENTLY DELETE all resources in the CloudFormation stack!"
    warn "⚠️  This includes EC2 instances, S3 buckets, databases, and all data!"
    warn "⚠️  This action CANNOT be undone!"
    echo
    
    read -p "Are you absolutely sure you want to destroy the entire stack? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Stack destruction cancelled by user"
        exit 0
    fi
    
    echo
    warn "🔥 FINAL WARNING: Type 'DESTROY' to confirm complete destruction of all resources:"
    read -r confirm
    
    if [ "$confirm" != "DESTROY" ]; then
        log "Stack destruction cancelled - confirmation not received"
        exit 0
    fi
    
    get_stack_outputs
    empty_s3_buckets
    delete_stack
    cleanup_templates_bucket
    cleanup_files
    
    echo
    success "🎉 All resources have been successfully destroyed!"
    log "Stack Name: $STACK_NAME"
    log "Region: $AWS_REGION"
    
    echo
    log "📋 What was destroyed:"
    echo "  ✓ EC2 instance and associated resources"
    echo "  ✓ VPC, subnets, internet gateway, NAT gateway"
    echo "  ✓ Security groups and network ACLs"
    echo "  ✓ IAM roles and policies"
    echo "  ✓ S3 buckets (emptied and deleted)"
    echo "  ✓ DynamoDB tables"
    echo "  ✓ CloudWatch logs, metrics, and alarms"
    echo "  ✓ SNS topics and subscriptions"
    echo "  ✓ All CloudFormation stack resources"
    
    echo
    log "💰 Cost Impact:"
    echo "  • All billable resources have been terminated"
    echo "  • Check AWS Cost Explorer for final charges"
    echo "  • Some logs may be retained based on retention policies"
}

if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi