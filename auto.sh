#!/bin/bash

# The Auto script helps with Packaging and Deploying the account Cloudformation Stacks to make development easy.
#
# Packaging allows you to reference other stacks and resources locally, then upload them to S3 and reference them for
# easy deployment

# Make the commands in this script relative to the script, not relative to where you ran them.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd $SCRIPT_DIR

# A few bash commands to make development against dev environment easy.
# Set the two properties below to sensible values for your project.

if ! type "aws" &> /dev/null; then
    echo "'aws' was not found in the path.  Install awscli using 'sudo pip install awscli' then try again."
    exit 1
fi

COMMAND="$1"

if [ "$COMMAND" = "test" ]; then
    TEMPLATE_FILE_NAMES=$(grep -rl --include=*.yaml --exclude=./build/* AWSTemplateFormatVersion .)
    yamllint $(echo $TEMPLATE_FILE_NAMES)

    if [ $? -ne 0 ]; then
        echo "Project failed linting. See output above"
        exit 1
    fi

    for filename in $TEMPLATE_FILE_NAMES; do
        aws cloudformation validate-template --template-body file://$filename > /dev/null 2>&1

        if [ $? -ne 0 ]; then
            echo "$filename failed CloudFormation Template Validation."
            echo "The error was:"
            aws cloudformation validate-template --template-body file://$filename
            exit 2
        fi
    done

    echo "All Templates passed Linting and CloudFormation Template Validation"

elif [ "$COMMAND" = "deploy" ]; then
    ACCOUNT="$2"

    if [ "$#" -lt 2 ]; then
        echo "Invalid arguments. Deploy expects an account"
        echo "eg: auto.sh deploy <account> [options]"
        exit 1
    fi

    # You can find the default cf-template bucket using
    # "aws s3api list-buckets --query 'Buckets[?starts_with(Name,`cf-template`)].Name' --output text"
    if [ "$ACCOUNT" = "dev" ]; then
        BUILD_ARTIFACT_BUCKET="cf-templates-hpbjab14shbt-us-west-2"
    else
        echo "No artifact bucket has been setup for this account yet."
        exit 2
    fi

    aws cloudformation package --template-file $SCRIPT_DIR/accounts/$ACCOUNT.yaml --s3-bucket $BUILD_ARTIFACT_BUCKET --output-template-file /tmp/$ACCOUNT.yaml
    if [ $? -ne 0 ]; then
        exit 3
    fi

    echo "Executing aws cloudformation deploy..."
    aws cloudformation deploy --template-file /tmp/$ACCOUNT.yaml --stack-name $ACCOUNT --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM ${@:3}

    if [ $? -ne 0 ]; then
        # Print some help on why it failed.
        echo ""
        echo "Printing recent CloudFormation errors..."
        aws cloudformation describe-stack-events --stack-name $ACCOUNT --query 'reverse(StackEvents[?ResourceStatus==`CREATE_FAILED`||ResourceStatus==`UPDATE_FAILED`].[ResourceType,LogicalResourceId,ResourceStatusReason])' --output text
        exit 4
    fi
elif [ "$COMMAND" = "package" ]; then

    # This is the list of accounts to consider when using 'auto.sh package all'
    ALL_ACCOUNTS="dev staging production"

    if [ -z "$BUILD_ARTIFACT_BUCKET" ]; then
        echo "The BUILD_ARTIFACT_BUCKET was not set."
        echo "Set it with 'export BUILD_ARTIFACT_BUCKET=\"<bucket_name>\"'"
        echo ""
        echo "Attempting to find a 'cf-template' bucket..."
        BUILD_ARTIFACT_BUCKET="$(aws s3api list-buckets --query 'Buckets[?starts_with(Name,`cf-template`)].Name' --output text)"
        if [ $? -ne 0 ]; then
            echo "Unable to find 'cf-template' bucket. Failing."
            exit 1
        fi
    fi

    ACCOUNTS="${@:2}"
    if [ "$ACCOUNTS" = "all" ]; then
        ACCOUNTS="$ALL_ACCOUNTS"
    fi

    if [ -z "$ACCOUNTS" ]; then
        echo "Accounts were not specified properly"
        echo "Eg: auto.sh package <account_1> [account_2] [account_3]"
        echo ""
        echo "You can package all of the accounts with"
        echo "auto.sh package all"
        exit 2
    fi

    rm -r $SCRIPT_DIR/build/*
    [ -d "$SCRIPT_DIR/build" ] || mkdir $SCRIPT_DIR/build

    for account in $ACCOUNTS; do
        aws cloudformation package --template-file $SCRIPT_DIR/accounts/$account.yaml --s3-bucket $BUILD_ARTIFACT_BUCKET --output-template-file $SCRIPT_DIR/build/$account.yaml
        if [ $? -ne 0 ]; then
            echo "Failed in packaging $account.yaml"
            exit 3
        fi
    done
else
    echo "usage:"
    echo -e "\t./auto.sh package <account> [<account>]"
    echo -e "\t./auto.sh deploy <account>"
    echo ""
    echo "Common Commands"
    echo -e "\tpackage\t\tPackages the Cloudformation Template associated"
    echo -e "\t\t\t\twith an account or accounts"
    echo -e "\tdeploy\t\tPackages and deploys the Cloudformation Template"
    echo -e "\t\t\t\tassociated with a particular account"
fi