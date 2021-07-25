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
    >&2 echo "'aws' was not found in the path.  Install awscli using 'sudo pip install awscli' then try again."
    exit 1
fi

COMMAND="$1"

function ensure_artifact_bucket() {
    if [ -z "$BUILD_ARTIFACT_BUCKET" ]; then
        REGION=$AWS_DEFAULT_REGION
        if [ -z "$REGION" ]; then
            REGION="$(aws configure get region)"
            if [ -z "$REGION" ]; then
                >&2 echo "We could not determine the region to package the resources into."
                >&2 echo "You can set the region in your config using 'aws configure'"
                >&2 echo "Or by setting the AWS_DEFAULT_REGION"
                exit 1
            fi
        fi

        >&2 echo "Attempting to find a 'cf-template' artifact bucket..."
        export BUILD_ARTIFACT_BUCKET="$(aws s3api list-buckets --query "Buckets[?starts_with(Name,\`cf-template\`) && ends_with(Name, \`$REGION\`)].Name" --output text)"
        if [ $? -ne 0 ]; then
            >&2 echo "Unable to find location to upload artifacts."
            >&2 echo ""
            >&2 echo "The 'cf-template' bucket is created automatically the first time you upload"
            >&2 echo "a CloudFormation template for a region in the console."
            >&2 echo ""
            >&2 echo "You can also explicitly set an artifact bucket with 'export BUILD_ARTIFACT_BUCKET=\"<bucket_name>\"'"
            >&2 echo ""
            >&2 echo "No artifact bucket location was found. Failing."
            exit 2
        fi
        >&2 echo "BUILD_ARTIFACT_BUCKET=$BUILD_ARTIFACT_BUCKET"
    fi
}

ensure_artifact_bucket
if [ "$?" -ne 0 ]; then
    exit 1
fi

function size_dependent_cf_location() {
    filename="$1"

    if [ "$(du -k $filename | cut -f1)" -le 40 ]; then
        echo "--template-body file://$filename"
    else
        uuid=$(uuidgen)
        s3Url="s3://$BUILD_ARTIFACT_BUCKET/templates/$uuid.yaml"

        aws s3 cp $filename s3://$BUILD_ARTIFACT_BUCKET/templates/$uuid.yaml > /dev/null 2>&1

        echo "--template-url http://$BUILD_ARTIFACT_BUCKET.s3.amazonaws.com/templates/$uuid.yaml"
    fi
}

if [ "$COMMAND" = "test" ]; then
    TEMPLATE_FILE_NAMES=$(grep -rl --include=*.yaml --exclude=./build/* AWSTemplateFormatVersion .)
    yamllint -d relaxed $(echo $TEMPLATE_FILE_NAMES)

    if [ $? -ne 0 ]; then
        >&2 echo "Project failed linting. See output above"
        exit 1
    fi

    for filename in $TEMPLATE_FILE_NAMES; do

        cf_location="$(size_dependent_cf_location $filename)"
        aws cloudformation validate-template $cf_location > /dev/null 2>&1

        if [ $? -ne 0 ]; then
            >&2 echo "$filename failed CloudFormation Template Validation."
            >&2 echo "The error was:"
            aws cloudformation validate-template $cf_location
            exit 3
        fi
    done

    echo "All Templates passed Linting and CloudFormation Template Validation"

elif [ "$COMMAND" = "deploy" ]; then
    ACCOUNT="$2"

    if [ "$#" -lt 2 ]; then
        >&2 echo "Invalid arguments. Deploy expects an account"
        >&2 echo "eg: auto.sh deploy <account> [options]"
        exit 1
    fi

    $SCRIPT_DIR/auto.sh package
    if [ $? -ne 0 ]; then
        exit 2
    fi

    cf_location="$(size_dependent_cf_location $SCRIPT_DIR/build/lightrail-stack.yaml)"

    # Gather Parameters
    EXISTING_PARAM_KEYS=$(aws cloudformation describe-stacks --stack-name $ACCOUNT --query Stacks[].Parameters[].ParameterKey --output text)
    PARAMETER_OPTIONS=""
    for param in $EXISTING_PARAM_KEYS; do PARAMETER_OPTIONS="$PARAMETER_OPTIONS ParameterKey=$param,UsePreviousValue=true"; done

    >&2 echo "Waiting for changeset to be created..."
    change_set_name="auto-sh-deploy-$(date +%s)"
    aws cloudformation create-change-set $cf_location --stack-name $ACCOUNT --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND --change-set-name "$change_set_name" --change-set-type UPDATE --parameters $PARAMETER_OPTIONS

    if [ "$?" -ne 0 ]; then
        >&2 echo "Change set failed to create. Exiting."
        exit 3
    fi

    change_set_status="$(aws cloudformation describe-change-set --stack-name $ACCOUNT --change-set-name "$change_set_name" --query Status --output text)"
    while [ "$change_set_status" == "CREATE_IN_PROGRESS" ]
    do
        sleep 5
        change_set_status="$(aws cloudformation describe-change-set --stack-name $ACCOUNT --change-set-name $change_set_name --query Status --output text)"
    done

    >&2 echo "Waiting for stack update to complete"
    aws cloudformation execute-change-set --stack-name $ACCOUNT --change-set-name $change_set_name

    stack_status="$(aws cloudformation describe-stacks --stack-name $ACCOUNT --query Stacks[].StackStatus --output text)"
    while [ "$stack_status" == "UPDATE_IN_PROGRESS" ] || [ "$stack_status" == "UPDATE_COMPLETE_CLEANUP_IN_PROGRESS" ]
    do
        sleep 5
        stack_status="$(aws cloudformation describe-stacks --stack-name $ACCOUNT --query Stacks[].StackStatus --output text)"
    done

    if [ "$stack_status" != "UPDATE_COMPLETE" ]; then
        # Print some help on why it failed.
        >&2 echo ""
        >&2 echo "Printing recent CloudFormation errors..."
        ONE_HOUR_AGO=$(date -v -1H -u +"%Y-%m-%dT%H:%M:%SZ")
        aws cloudformation describe-stack-events --stack-name $ACCOUNT --query "reverse(StackEvents[?Timestamp > \`$ONE_HOUR_AGO\` && (ResourceStatus==\`CREATE_FAILED\`||ResourceStatus==\`UPDATE_FAILED\`)].[Timestamp,ResourceType,LogicalResourceId,ResourceStatusReason])" --output text
        exit 5
    fi

    >&2 echo "Update Complete"
elif [ "$COMMAND" = "package" ]; then

    [ -d "$SCRIPT_DIR/tmp" ] || mkdir $SCRIPT_DIR/tmp
    rm -rf $SCRIPT_DIR/tmp/* > /dev/null 2>&1

    # Copy all of the files to a temporary directory, because we're going to dynamically change some things
    rsync -a --exclude="tmp/" --exclude="build/" $SCRIPT_DIR/* $SCRIPT_DIR/tmp

    # Find all of the references to CloudFormation Templates in GitHub
    # Then download them, replace github references with the local copy
    regex="([^:]+):[[:space:]]+TemplateURL:[[:space:]]+(.*)"
    grep -E -r '^\s+TemplateURL:\s+https://raw.githubusercontent.com/' $SCRIPT_DIR/tmp | while read match; do
        if [ ! -e "$HOME/.github/token" ]; then
            >&2 echo "No GitHub token was found in '$HOME/.github/token'"
            exit 3
        fi

        [[ "$match" =~ $regex ]]
        file=${BASH_REMATCH[1]}
        url=${BASH_REMATCH[2]}

        >&2 echo "Downloading $url locally, and replacing reference with local copy in $file"

        local_file="$SCRIPT_DIR/tmp/$(uuidgen)"
        curl -f -H "Authorization: token $(cat $HOME/.github/token)" $url -o $local_file > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            >&2 echo "Failed to fetch '$url'. Check the url, and ensure your github access token is set in $HOME/.github/token"
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
        >&2 echo "Failed in packaging lightrail-stack.yaml"
        exit 5
    fi
    rm -rf $SCRIPT_DIR/tmp > /dev/null 2>&1
else
    >&2 echo "usage:"
    >&2 echo -e "\t./auto.sh package"
    >&2 echo -e "\t./auto.sh deploy <account>"
    >&2 echo ""
    >&2 echo "Common Commands"
    >&2 echo -e "\tpackage\t\tPackages the Cloudformation Template for the"
    >&2 echo -e "\t\t\t\tLightrail stack"
    >&2 echo -e "\tdeploy\t\tPackages and deploys the Cloudformation Template"
    >&2 echo -e "\t\t\t\tassociated with a particular account"
fi
