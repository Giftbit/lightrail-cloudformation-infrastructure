#!/usr/bin/env bash

# Make the commands in this script relative to the script, not relative to where you ran them.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd $SCRIPT_DIR

STACK_NAME="LightrailInfrastructureCI"

# A few bash commands to make development against dev environment easy.
# Set the two properties below to sensible values for your project.

if ! type "aws" &> /dev/null; then
    echo "'aws' was not found in the path.  Install awscli using 'sudo pip install awscli' then try again."
    exit 1
fi

BUILD_ARTIFACT_BUCKET="$(aws s3api list-buckets --query 'Buckets[?starts_with(Name,`cf-template`)].Name' --output text)"

aws cloudformation package --template-file ci.yaml --s3-bucket $BUILD_ARTIFACT_BUCKET --output-template-file /tmp/ci.yaml
if [ $? -ne 0 ]; then
    exit 1
fi

echo "Executing aws cloudformation deploy..."
aws cloudformation deploy --template-file /tmp/ci.yaml --stack-name $STACK_NAME --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM ${@:1}

if [ $? -ne 0 ]; then
    # Print some help on why it failed.
    echo ""
    echo "Printing recent CloudFormation errors..."
    aws cloudformation describe-stack-events --stack-name $STACK_NAME --query 'reverse(StackEvents[?ResourceStatus==`CREATE_FAILED`||ResourceStatus==`UPDATE_FAILED`].[ResourceType,LogicalResourceId,ResourceStatusReason])' --output text
fi
