#!/usr/bin/env bash

# Make the commands in this script relative to the script, not relative to where you ran them.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd $SCRIPT_DIR

set -x

if ! type "aws" &> /dev/null; then
    echo "'aws' was not found in the path.  Install awscli using 'sudo pip install awscli' then try again."
    exit 1
fi

BUILD_ARTIFACT_BUCKET="$(aws s3api list-buckets --query 'Buckets[?starts_with(Name,`cf-template`) && ends_with(Name,`us-west-2`)].Name' --output text)"

uuid=$(uuidgen)
while [ -n "$(aws s3 ls s3://$BUILD_ARTIFACT_BUCKET/$uuid.yaml)" ]; do
    uuid=$(uuidgen)
done

temp_file=$(mktemp)
aws cloudformation package --template-file ci.yaml --s3-bucket $BUILD_ARTIFACT_BUCKET --output-template-file $temp_file
if [ $? -ne 0 ]; then
    rm $temp_file
    echo "Failed to package the CloudFormation template"
    exit 1
fi

aws s3 cp $temp_file s3://$BUILD_ARTIFACT_BUCKET/$uuid.yaml
if [ $? -ne 0 ]; then
    # Print some help on why it failed.
    echo "Failed uplaoding the packaged template to s3"
    rm $temp_file
    exit 2
fi
rm $temp_file

echo "The packaged template was uploaded to https://$BUILD_ARTIFACT_BUCKET.s3.amazonaws.com/$uuid.yaml"



