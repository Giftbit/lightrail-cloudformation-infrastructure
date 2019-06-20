This directory contains the Dockerfile for Docker container that we use in CodeBuild.

## Build the Docker image

```bash
docker build -t node-ssh
```

## Upload to an AWS account

Change [ACCOUNT_ID] for the id of the account you want to add the build image to.  This assumed `node-ssh` is the tag for the Docker image to upload.

```bash
docker tag node-ssh [ACCOUNT_ID].dkr.ecr.us-west-2.amazonaws.com/lightrail-ci-resources-20170717-node-ssh
eval $(aws ecr get-login --no-include-email) && docker push [ACCOUNT_ID].dkr.ecr.us-west-2.amazonaws.com/lightrail-ci-resources-20170717-node-ssh

```

## Download from an AWS ACCOUNT

You might do this to download from one account and upload to another.

```bash
eval $(aws ecr get-login --no-include-email) && docker pull [ACCOUNT_ID].dkr.ecr.us-west-2.amazonaws.com/lightrail-ci-resources-20170717-node-ssh
docker tag [ACCOUNT_ID].dkr.ecr.us-west-2.amazonaws.com/lightrail-ci-resources-20170717-node-ssh node-ssh
```
