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

    $SCRIPT_DIR/auto.sh package
    if [ $? -ne 0 ]; then
        exit 3
    fi

    echo "Executing aws cloudformation deploy..."
    aws cloudformation deploy --template-file $SCRIPT_DIR/build/lightrail-stack.yaml --stack-name $ACCOUNT --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM ${@:3}

    if [ $? -ne 0 ]; then
        # Print some help on why it failed.
        echo ""
        echo "Printing recent CloudFormation errors..."
        ONE_HOUR_AGO=$(date -v -1H -u +"%Y-%m-%dT%H:%M:%SZ")
        aws cloudformation describe-stack-events --stack-name $ACCOUNT --query "reverse(StackEvents[?Timestamp > \`$ONE_HOUR_AGO\` && (ResourceStatus==\`CREATE_FAILED\`||ResourceStatus==\`UPDATE_FAILED\`)].[Timestamp,ResourceType,LogicalResourceId,ResourceStatusReason])" --output text
        exit 4
    fi
elif [ "$COMMAND" = "package" ]; then

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
        echo "BUILD_ARTIFACT_BUCKET=$BUILD_ARTIFACT_BUCKET"
    fi

    [ -d "$SCRIPT_DIR/tmp" ] || mkdir $SCRIPT_DIR/tmp
    rm -rf $SCRIPT_DIR/tmp/* > /dev/null 2>&1

    # Copy all of the files to a temporary directory, because we're going to dynamically change some things
    rsync -a --exclude="tmp/" --exclude="build/" $SCRIPT_DIR/* $SCRIPT_DIR/tmp

    # Find all of the references to CloudFormation Templates in GitHub
    # Then download them, replace github references with the local copy
    regex="([^:]+):[[:space:]]+TemplateURL:[[:space:]]+(.*)"
    grep -E -r '^\s+TemplateURL:\s+https://raw.githubusercontent.com/' $SCRIPT_DIR/tmp | while read match; do
        if [ ! -e "$HOME/.github/token" ]; then
            echo "No GitHub token was found in '$HOME/.github/token'"
            exit 2
        fi

        [[ "$match" =~ $regex ]]
        file=${BASH_REMATCH[1]}
        url=${BASH_REMATCH[2]}

        echo "Downloading $url locally, and replacing reference with local copy in $file"

        local_file="$SCRIPT_DIR/tmp/$(uuidgen)"
        curl -f -H "Authorization: token $(cat $HOME/.github/token)" $url -o $local_file
        if [ $? -ne 0 ]; then
            echo "Failed to fetch '$url'. Check the url, and ensure your github access token is set in $HOME/.github/token"
            exit 3
        fi

        sed -i.bak "s,$url,$local_file,g" $file
    done
    if [ $? -ne 0 ]; then
        # If we exit the loop with any non zero exit code, then we had a failure inside it, so pass the exit up
        exit $?
    fi

    [ -d "$SCRIPT_DIR/build" ] || mkdir $SCRIPT_DIR/build
    rm -r $SCRIPT_DIR/build/* > /dev/null 2>&1

    aws cloudformation package --template-file $SCRIPT_DIR/tmp/lightrail-stack.yaml --s3-bucket $BUILD_ARTIFACT_BUCKET --output-template-file $SCRIPT_DIR/build/lightrail-stack.yaml
    if [ $? -ne 0 ]; then
        echo "Failed in packaging lightrail-stack.yaml"
        exit 4
    fi
#    rm -rf $SCRIPT_DIR/tmp > /dev/null 2>&1
else
    echo "usage:"
    echo -e "\t./auto.sh package"
    echo -e "\t./auto.sh deploy <account>"
    echo ""
    echo "Common Commands"
    echo -e "\tpackage\t\tPackages the Cloudformation Template for the"
    echo -e "\t\t\t\tLightrail stack"
    echo -e "\tdeploy\t\tPackages and deploys the Cloudformation Template"
    echo -e "\t\t\t\tassociated with a particular account"
fi
