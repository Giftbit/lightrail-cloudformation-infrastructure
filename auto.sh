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

function ensure_artifact_bucket() {
    if [ -z "$BUILD_ARTIFACT_BUCKET" ]; then
        REGION=$AWS_DEFAULT_REGION
        if [ -z "$REGION" ]; then
            REGION="$(aws configure get region)"
            if [ -z "$REGION" ]; then
                echo "We could not determine the region to package the resources into."
                echo "You can set the region in your config using 'aws configure'"
                echo "Or by setting the AWS_DEFAULT_REGION"
                exit 1
            fi
        fi

        echo "The BUILD_ARTIFACT_BUCKET was not set."
        echo "Set it with 'export BUILD_ARTIFACT_BUCKET=\"<bucket_name>\"'"
        echo ""
        echo "Attempting to find a 'cf-template' bucket..."
        BUILD_ARTIFACT_BUCKET="$(aws s3api list-buckets --query "Buckets[?starts_with(Name,\`cf-template\`) && ends_with(Name, \`$REGION\`)].Name" --output text)"
        if [ $? -ne 0 ]; then
            echo "Unable to find 'cf-template' bucket. Failing."
            exit 2
        fi
        echo "BUILD_ARTIFACT_BUCKET=$BUILD_ARTIFACT_BUCKET"
    fi
}

function size_dependent_cf_location() {
    filename="$1"

    if [ "$(du -k $filename | cut -f1)" -le 40 ]; then
        echo "--template-body file://$filename"
    else
        ensure_artifact_bucket > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "Unable to find 'cf-template' bucket. Failing."
            exit 1
        fi

        uuid=$(uuidgen)
        s3Url="s3://$BUILD_ARTIFACT_BUCKET/templates/$uuid.yaml"

        aws s3 cp $filename s3://$BUILD_ARTIFACT_BUCKET/templates/$uuid.yaml > /dev/null 2>&1

        echo "--template-url http://$BUILD_ARTIFACT_BUCKET.s3.amazonaws.com/templates/$uuid.yaml"
    fi
}

if [ "$COMMAND" = "test" ]; then
    TEMPLATE_FILE_NAMES=$(grep -rl --include=*.yaml --exclude=./build/* AWSTemplateFormatVersion .)
    yamllint $(echo $TEMPLATE_FILE_NAMES)

    if [ $? -ne 0 ]; then
        echo "Project failed linting. See output above"
        exit 1
    fi

    for filename in $TEMPLATE_FILE_NAMES; do

        cf_location="$(size_dependent_cf_location $filename)"
        if [ $? -ne 0 ]; then
            echo "The BUILD_ARTIFACT_BUCKET was not set."
            echo "Set it with 'export BUILD_ARTIFACT_BUCKET=\"<bucket_name>\"'"
            exit 2
        fi

        aws cloudformation validate-template $cf_location > /dev/null 2>&1

        if [ $? -ne 0 ]; then
            echo "$filename failed CloudFormation Template Validation."
            echo "The error was:"
            aws cloudformation validate-template $cf_location
            exit 3
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

    $SCRIPT_DIR/auto.sh package
    if [ $? -ne 0 ]; then
        exit 2
    fi

    cf_location="$(size_dependent_cf_location $SCRIPT_DIR/build/lightrail-stack.yaml)"
    if [ $? -ne 0 ]; then
        echo "The BUILD_ARTIFACT_BUCKET was not set."
        echo "Set it with 'export BUILD_ARTIFACT_BUCKET=\"<bucket_name>\"'"
        exit 3
    fi

    # Gather Parameters
    EXISTING_PARAM_KEYS=$(aws cloudformation describe-stacks --stack-name $ACCOUNT --query Stacks[].Parameters[].ParameterKey --output text)
    PARAMETER_OPTIONS=""
    for param in $EXISTING_PARAM_KEYS; do PARAMETER_OPTIONS="$PARAMETER_OPTIONS ParameterKey=$param,UsePreviousValue=true"; done

    echo "Waiting for changeset to be created..."
    change_set_name="auto-sh-deploy-$(date +%s)"
    aws cloudformation create-change-set $cf_location --stack-name $ACCOUNT --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM --change-set-name "$change_set_name" --change-set-type UPDATE --parameters $PARAMETER_OPTIONS

    if [ "$?" -ne 0 ]; then
        echo "Change set failed to create. Exiting."
        exit 4
    fi

    change_set_status="$(aws cloudformation describe-change-set --stack-name $ACCOUNT --change-set-name "$change_set_name" --query Status --output text)"
    while [ "$change_set_status" == "CREATE_IN_PROGRESS" ]
    do
        sleep 5
        change_set_status="$(aws cloudformation describe-change-set --stack-name $ACCOUNT --change-set-name $change_set_name --query Status --output text)"
    done

    echo "Waiting for stack update to complete"
    aws cloudformation execute-change-set --stack-name $ACCOUNT --change-set-name $change_set_name

    stack_status="$(aws cloudformation describe-stacks --stack-name $ACCOUNT --query Stacks[].StackStatus --output text)"
    while [ "$stack_status" == "UPDATE_IN_PROGRESS" ] || [ "$stack_status" == "UPDATE_COMPLETE_CLEANUP_IN_PROGRESS" ]
    do
        sleep 5
        stack_status="$(aws cloudformation describe-stacks --stack-name $ACCOUNT --query Stacks[].StackStatus --output text)"
    done

    if [ "$stack_status" != "UPDATE_COMPLETE" ]; then
        # Print some help on why it failed.
        echo ""
        echo "Printing recent CloudFormation errors..."
        ONE_HOUR_AGO=$(date -v -1H -u +"%Y-%m-%dT%H:%M:%SZ")
        aws cloudformation describe-stack-events --stack-name $ACCOUNT --query "reverse(StackEvents[?Timestamp > \`$ONE_HOUR_AGO\` && (ResourceStatus==\`CREATE_FAILED\`||ResourceStatus==\`UPDATE_FAILED\`)].[Timestamp,ResourceType,LogicalResourceId,ResourceStatusReason])" --output text
        exit 5
    fi

    echo "Update Complete"
elif [ "$COMMAND" = "package" ]; then

    ensure_artifact_bucket

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
            exit 3
        fi

        [[ "$match" =~ $regex ]]
        file=${BASH_REMATCH[1]}
        url=${BASH_REMATCH[2]}

        echo "Downloading $url locally, and replacing reference with local copy in $file"

        local_file="$SCRIPT_DIR/tmp/$(uuidgen)"
        curl -f -H "Authorization: token $(cat $HOME/.github/token)" $url -o $local_file
        if [ $? -ne 0 ]; then
            echo "Failed to fetch '$url'. Check the url, and ensure your github access token is set in $HOME/.github/token"
            exit 4
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
        exit 5
    fi
    rm -rf $SCRIPT_DIR/tmp > /dev/null 2>&1
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
