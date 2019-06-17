This directory contains the Dockerfile for Docker container that we use in CodeBuild.

## Building

`docker build -t node-ssh .`

## Uploading to accounts

Change [ACCOUNT_ID] for the id of the account you want to add the build image to.

1. Insert your Lightrail Dev credentials
2. run: eval $(aws ecr get-login --no-include-email) && docker pull 757264843183.dkr.ecr.us-west-2.amazonaws.com/lightrail-ci-resources-20170717-node-ssh
3. run: docker tag 757264843183.dkr.ecr.us-west-2.amazonaws.com/lightrail-ci-resources-20170717-node-ssh [ACCOUNT_ID].dkr.ecr.us-west-2.amazonaws.com/lightrail-ci-resources-20170717-node-ssh
4. Swap in your credentials for the account you want to add the build image to
5. run: eval $(aws ecr get-login --no-include-email) && docker push [ACCOUNT_ID].dkr.ecr.us-west-2.amazonaws.com/lightrail-ci-resources-20170717-node-ssh
